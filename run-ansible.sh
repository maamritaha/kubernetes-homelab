
#!/usr/bin/env bash
set -euo pipefail

# Resolve the project root independently of the current directory.
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$PROJECT_ROOT"

IMAGE_NAME="localhost/kubernetes-homelab-ansible"
CONTAINERFILE="ansible/Containerfile"
GALAXY_REQUIREMENTS="ansible/requirements.yaml"
PYTHON_REQUIREMENTS="ansible/python-requirements.txt"
PLAYBOOK="ansible/playbooks/configure-nodes.yaml"
ANSIBLE_CONFIG_FILE="${PROJECT_ROOT}/ansible.cfg"

VAULT_PASSWORD_PATH=""
VAULT_BACKUP_ROOT="${PROJECT_ROOT}/.local-backups/ansible-vault"

usage() {
  cat <<'EOF'
Usage:
  ./run-ansible.sh <environment> [options]

Environments:
  dev
  test
  prod

Runner options:
  --inventory       Display the dynamic inventory graph
  --ping            Test SSH connectivity using Ansible
  --rebuild         Force image rebuild
  --help            Show this help

Other options are passed directly to ansible-playbook.

Examples:
  ./run-ansible.sh dev
  ./run-ansible.sh dev --inventory
  ./run-ansible.sh dev --ping
  ./run-ansible.sh dev --syntax-check
  ./run-ansible.sh dev --check --diff
  ./run-ansible.sh dev --tags vault
  ./run-ansible.sh dev --rebuild
EOF
}

error() {
  echo "Error: $*" >&2
  exit 1
}

# Ask for explicit confirmation.
# An empty answer is treated as yes.
confirm() {
  local prompt="$1"
  local answer=""

  [[ -t 0 ]] ||
    error "Interactive confirmation is required."

  read -r -p "$prompt [Y/n] " answer || return 1

  case "$answer" in
    ""|y|Y|yes|YES|Yes)
      return 0
      ;;
    n|N|no|NO|No)
      return 1
      ;;
    *)
      echo "Invalid answer." >&2
      return 1
      ;;
  esac
}

# Read the Vault password path from ansible.cfg.
# The configuration file remains the single source of truth.
resolve_vault_password_path() {
  local configured_path=""
  local config_dir=""

  config_dir="$(dirname "$ANSIBLE_CONFIG_FILE")"

  configured_path="$(
    awk '
      /^[[:space:]]*[#;]/ { next }

      /^[[:space:]]*\[/ {
        section = $0
        sub(/^[[:space:]]*\[/, "", section)
        sub(/\].*$/, "", section)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
        next
      }

      section == "defaults" &&
      /^[[:space:]]*vault_password_file[[:space:]]*=/ {
        line = $0
        sub(/^[^=]*=/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        print line
        exit
      }
    ' "$ANSIBLE_CONFIG_FILE"
  )"

  [[ -n "$configured_path" ]] ||
    error "vault_password_file is missing from [defaults] in ansible.cfg."

  case "$configured_path" in
    /*)
      VAULT_PASSWORD_PATH="$configured_path"
      ;;
    "~/"*)
      [[ -n "${HOME:-}" ]] ||
        error "HOME is not defined."

      VAULT_PASSWORD_PATH="${HOME}/${configured_path#\~/}"
      ;;
    *)
      VAULT_PASSWORD_PATH="${config_dir}/${configured_path}"
      ;;
  esac

  local password_dir=""
  password_dir="$(dirname "$VAULT_PASSWORD_PATH")"

  [[ -d "$password_dir" ]] ||
    error "Vault password parent directory does not exist: $password_dir"

  password_dir="$(cd "$password_dir" && pwd -P)"

  VAULT_PASSWORD_PATH="${password_dir}/$(basename "$VAULT_PASSWORD_PATH")"

  case "$VAULT_PASSWORD_PATH" in
    "${PROJECT_ROOT}/"*) ;;
    *)
      error "Vault password must be inside the mounted project directory."
      ;;
  esac

  [[ ! -L "$VAULT_PASSWORD_PATH" ]] ||
    error "Vault password path must not be a symbolic link."
}

# Identify generated secret and certificate directories.
# Include all environments because the Ansible Vault password
# may be shared across dev, test and prod.
discover_generated_assets() {
  GENERATED_ASSETS=()

  local environment=""
  local directory=""

  for environment in dev test prod; do
    for directory in \
      "environments/${environment}/secrets" \
      "certificates/${environment}"
    do
      if [[ -L "$directory" ]]; then
        error "Generated asset directory must not be a symlink: $directory"
      fi

      if [[ -d "$directory" ]] &&
         [[ -n "$(find "$directory" -type f -print -quit)" ]]; then
        GENERATED_ASSETS+=("$directory")
      fi
    done
  done

  # Preserve the previous password if it exists.
  if [[ -e "$VAULT_PASSWORD_PATH" ]]; then
    [[ -f "$VAULT_PASSWORD_PATH" ]] ||
      error "Vault password path is not a regular file."

    GENERATED_ASSETS+=(
      "${VAULT_PASSWORD_PATH#${PROJECT_ROOT}/}"
    )
  fi
}

# Archive existing credentials and certificates before resetting.
# Never delete them permanently.
archive_generated_assets() {
  local timestamp=""
  local backup_directory=""
  local asset=""
  local destination=""
  local destination_dir=""

  timestamp="$(date -u +%Y%m%dT%H%M%S%N)"
  backup_directory="${VAULT_BACKUP_ROOT}/${timestamp}"

  (umask 077; mkdir -p -- "$backup_directory") ||
    error "Unable to create backup directory."

  chmod 700 "$backup_directory"

  echo
  echo "Archiving generated assets..."

  for asset in "${GENERATED_ASSETS[@]}"; do
    destination="${backup_directory}/${asset}"
    destination_dir="$(dirname "$destination")"

    mkdir -p -- "$destination_dir" ||
      error "Unable to prepare archive directory for: $asset"

    if ! mv -- "${PROJECT_ROOT}/${asset}" "$destination"; then
      error "Archive failed. Restore moved files from: $backup_directory"
    fi

    echo "Archived: $asset"
  done

  echo
  echo "Archive completed: $backup_directory"
  echo "The original files are preserved in the archive."
}

# Generate a secure password without printing it.
generate_vault_password() {
  local password_dir=""
  local temporary_file=""

  password_dir="$(dirname "$VAULT_PASSWORD_PATH")"

  [[ -d "$password_dir" ]] ||
    error "Vault password directory does not exist."

  [[ ! -e "$VAULT_PASSWORD_PATH" ]] ||
    error "Refusing to overwrite an existing Vault password."

  temporary_file="$(
    umask 077
    mktemp "${password_dir}/.ansible-vault-password.XXXXXXXX"
  )" || error "Unable to create temporary password file."

  chmod 600 "$temporary_file"

  if ! (
    set -o pipefail
    od -An -tx1 -N48 /dev/urandom |
      tr -d ' \n'
    printf '\n'
  ) > "$temporary_file"; then
    rm -f -- "$temporary_file"
    error "Secure password generation failed."
  fi

  [[ -s "$temporary_file" ]] || {
    rm -f -- "$temporary_file"
    error "Generated password is empty."
  }

  # Never replace a file that appeared during generation.
  if ! ln -- "$temporary_file" "$VAULT_PASSWORD_PATH"; then
    rm -f -- "$temporary_file"
    error "Vault password path already exists or could not be created."
  fi

  rm -f -- "$temporary_file"

  chmod 600 "$VAULT_PASSWORD_PATH"

  echo
  echo "Ansible Vault password generated successfully."
  echo "Path: $VAULT_PASSWORD_PATH"
  echo "Permissions: 600"
}

# Validate the configured password or request a controlled reset.
ensure_vault_password() {
  resolve_vault_password_path

  if [[ -f "$VAULT_PASSWORD_PATH" &&
        -r "$VAULT_PASSWORD_PATH" &&
        -s "$VAULT_PASSWORD_PATH" ]]; then
    echo "Ansible Vault password file: OK"
    return 0
  fi

  echo >&2
  echo "ERROR: Ansible Vault password is missing, empty or unreadable." >&2
  echo "Configured path: $VAULT_PASSWORD_PATH" >&2
  echo >&2
  echo "The project requires this password to decrypt generated" >&2
  echo "credentials, certificates and Vault bootstrap secrets." >&2

  discover_generated_assets

  if [[ ${#GENERATED_ASSETS[@]} -gt 0 ]]; then
    echo
    echo "Existing generated assets were detected:"
    echo

    printf '  - %s\n' "${GENERATED_ASSETS[@]}"

    echo
    echo "WARNING:"
    echo "These files may have been encrypted with a previous"
    echo "Ansible Vault password."
    echo
    echo "A newly generated password cannot decrypt them."
    echo
    echo "You can archive the existing assets using a UTC timestamp"
    echo "and regenerate a fresh Ansible Vault password."
    echo
    echo "This affects local files only."
    echo "It does not revoke credentials or certificates already"
    echo "deployed in Kubernetes, Vault or Forgejo."
    echo
    echo "Restore the original password if you need to preserve"
    echo "access to existing encrypted data."
    echo

    if ! confirm "Archive existing assets and generate a new Vault password?"; then
      error "Vault password reset cancelled. No files were modified."
    fi

    archive_generated_assets

  else
    echo
    echo "No generated credentials or certificates were detected."
    echo

    if ! confirm "Generate a new Ansible Vault password?"; then
      error "Vault password generation declined."
    fi
  fi

  generate_vault_password
}

# Discover the host SSH directory using OpenSSH configuration first.
# Fall back to the standard Linux user SSH directory.
detect_host_ssh_dir() {
  local ssh_config=""
  local ssh_path=""
  local candidate=""
  local ssh_dir=""
  local option=""

  if command -v ssh >/dev/null 2>&1; then
    ssh_config="$(ssh -G localhost 2>/dev/null)" || ssh_config=""

    if [[ -n "$ssh_config" ]]; then
      while read -r option ssh_path; do
        [[ -n "$ssh_path" ]] || continue

        case "$ssh_path" in
          "~/"*)
            [[ -n "${HOME:-}" ]] || continue
            candidate="${HOME}/${ssh_path#\~/}"
            ;;
          /*)
            candidate="$ssh_path"
            ;;
          *)
            continue
            ;;
        esac

        if [[ -f "$candidate" && -r "$candidate" ]]; then
          ssh_dir="$(dirname "$candidate")"

          if [[ -d "$ssh_dir" && -r "$ssh_dir" ]]; then
            (
              cd "$ssh_dir"
              pwd -P
            )
            return 0
          fi
        fi
      done < <(
        printf '%s\n' "$ssh_config" |
          grep -E '^(userknownhostsfile|identityfile) ' || true
      )
    fi
  fi

  if [[ -n "${HOME:-}" ]]; then
    ssh_dir="${HOME}/.ssh"

    if [[ -d "$ssh_dir" && -r "$ssh_dir" ]]; then
      (
        cd "$ssh_dir"
        pwd -P
      )
      return 0
    fi
  fi

  echo "Error: Unable to locate a readable SSH directory." >&2
  return 1
}

# Parse arguments.
if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

ENVIRONMENT="$1"
shift

case "$ENVIRONMENT" in
  dev|test|prod) ;;
  *)
    error "Unsupported environment: $ENVIRONMENT"
    ;;
esac

INVENTORY="ansible/inventory/${ENVIRONMENT}"

[[ -f "$INVENTORY" ]] ||
  error "Inventory not found: $INVENTORY"

[[ -x "$INVENTORY" ]] ||
  error "Inventory is not executable: $INVENTORY"

command -v podman >/dev/null 2>&1 ||
  error "Podman is not installed."

for file in \
  "$CONTAINERFILE" \
  "$GALAXY_REQUIREMENTS" \
  "$PYTHON_REQUIREMENTS" \
  "$PLAYBOOK" \
  "$ANSIBLE_CONFIG_FILE"
do
  [[ -f "$file" ]] ||
    error "Required file not found: $file"
done

SHOW_INVENTORY=false
PING_HOSTS=false
FORCE_REBUILD=false
ANSIBLE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory)
      SHOW_INVENTORY=true
      ;;
    --ping)
      PING_HOSTS=true
      ;;
    --rebuild)
      FORCE_REBUILD=true
      ;;
    *)
      ANSIBLE_ARGS+=("$1")
      ;;
  esac
  shift
done

if [[ "$SHOW_INVENTORY" == true &&
      "$PING_HOSTS" == true ]]; then
  error "--inventory and --ping cannot be combined."
fi

# Validate or initialize the Ansible Vault password before execution.
ensure_vault_password

# Discover SSH configuration on the host.
HOST_SSH_DIR="$(detect_host_ssh_dir)"
echo "Host SSH directory: $HOST_SSH_DIR"

# Build an image tag from dependency file contents.
IMAGE_HASH="$(
  sha256sum \
    "$CONTAINERFILE" \
    "$GALAXY_REQUIREMENTS" \
    "$PYTHON_REQUIREMENTS" |
    sha256sum |
    cut -c1-16
)"

IMAGE="${IMAGE_NAME}:${IMAGE_HASH}"

if [[ "$FORCE_REBUILD" == true ]] ||
   ! podman image exists "$IMAGE"; then

  echo "Building Ansible execution image: $IMAGE"

  podman build \
    --file "$CONTAINERFILE" \
    --tag "$IMAGE" \
    ansible
fi

# Preserve interactive input and display logs directly.
TTY_ARGS=(-i)

if [[ -t 0 && -t 1 ]]; then
  TTY_ARGS=(-it)
fi

# Select the command executed inside Podman.
if [[ "$SHOW_INVENTORY" == true ]]; then
  COMMAND=(
    ansible-inventory
    -i "$INVENTORY"
    --graph
  )
elif [[ "$PING_HOSTS" == true ]]; then
  COMMAND=(
    ansible
    all
    -i "$INVENTORY"
    -m ping
  )
else
  COMMAND=(
    ansible-playbook
    -i "$INVENTORY"
    "$PLAYBOOK"
    "${ANSIBLE_ARGS[@]}"
  )
fi

echo "Environment: $ENVIRONMENT"
echo "Image: $IMAGE"
echo "Project: $PROJECT_ROOT"
echo "Starting Ansible execution..."

# Mount the project read-write so generated secrets persist.
# Mount the host SSH directory read-only.
exec podman run \
  --rm \
  "${TTY_ARGS[@]}" \
  --userns=keep-id \
  --user "$(id -u):$(id -g)" \
  --network=host \
  --env HOME=/home/ansible \
  --env ANSIBLE_CONFIG=/workspace/ansible.cfg \
  --env "ANSIBLE_SSH_COMMON_ARGS=-o UserKnownHostsFile=/host-ssh/known_hosts -o IdentityFile=/host-ssh/id_ed25519" \
  --mount "type=bind,src=${PROJECT_ROOT},dst=/workspace,rw" \
  --mount "type=bind,src=${HOST_SSH_DIR},dst=/host-ssh,ro" \
  --workdir /workspace \
  "$IMAGE" \
  "${COMMAND[@]}"
