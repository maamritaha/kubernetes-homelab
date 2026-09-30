# Kubernetes Homelab

A Kubernetes homelab built with Ansible and designed to provide a reproducible Kubernetes environment across multiple environments.

The project currently automates the bootstrap of a Kubernetes cluster including:

- Ubuntu Server node configuration
- containerd
- Kubernetes (`kubeadm`, `kubelet`, `kubectl`)
- Control plane initialization
- Worker node joining
- Helm
- Cilium CNI

## Architecture

The project supports three environments:

```text
environments/
├── dev/
├── test/
└── prod/
```

Each environment contains:

- `cluster.yaml`: cluster topology, node names, IP addresses and roles
- `vars.yaml`: software versions and Kubernetes configuration

The current DEV topology is:

```text
dev-control-plane   192.168.56.10   control_plane
dev-worker-1        192.168.56.11   worker
dev-worker-2        192.168.56.12   worker
```

The DEV environment currently consists of one Kubernetes control plane node and two worker nodes.

## Repository Structure

```text
kubernetes-homelab/
├── ansible/
│   ├── inventory/
│   │   ├── dev
│   │   ├── dev.yaml
│   │   ├── inventory.py
│   │   ├── test
│   │   ├── test.yaml
│   │   ├── prod
│   │   └── prod.yaml
│   ├── playbooks/
│   │   └── configure-nodes.yaml
│   ├── roles/
│   │   ├── common/
│   │   ├── container_runtime/
│   │   ├── kubernetes/
│   │   ├── control_plane/
│   │   ├── helm/
│   │   ├── cni/
│   │   └── worker/
│   └── requirements.yaml
├── environments/
│   ├── dev/
│   │   ├── cluster.yaml
│   │   └── vars.yaml
│   ├── test/
│   │   ├── cluster.yaml
│   │   └── vars.yaml
│   └── prod/
│       ├── cluster.yaml
│       └── vars.yaml
├── terraform/
├── ansible.cfg
└── .gitignore
```

## Prerequisites

### Ansible Controller

Ansible is executed from a Linux workstation.

The workstation must have:

- Ansible
- Python 3
- SSH client
- Network access to all Kubernetes nodes

Install the required Ansible collections:

```bash
ansible-galaxy collection install -r ansible/requirements.yaml
```

### Kubernetes Nodes

The target servers must run **Ubuntu Server**.

The current homelab has been developed and tested using Ubuntu Server virtual machines.

Each node must provide:

- Ubuntu Server
- Network connectivity between nodes
- Network connectivity with the Ansible controller
- SSH access
- A dedicated automation user
- Python 3
- `sudo`
- Correct system time synchronization

The current project uses the following remote user:

```text
kube
```

This user is configured in:

```text
ansible.cfg
```

## SSH Configuration

The Ansible controller must be able to connect to every Kubernetes node using SSH public-key authentication.

Generate an SSH key on the Ansible controller if one does not already exist:

```bash
ssh-keygen -t ed25519
```

Copy the public key to every Kubernetes server:

```bash
ssh-copy-id kube@192.168.56.10
ssh-copy-id kube@192.168.56.11
ssh-copy-id kube@192.168.56.12
```

Verify SSH connectivity:

```bash
ssh kube@192.168.56.10
```

The connection should succeed without requiring the remote user's password.

Ansible connectivity can then be tested with:

```bash
ansible all \
    -i ansible/inventory/dev \
    -m ping
```

All nodes should return:

```text
SUCCESS
```

## Passwordless sudo

The Ansible playbooks use privilege escalation through:

```yaml
become: true
```

Ansible initially connects to the servers using the `kube` user and then uses `sudo` to execute operations requiring root privileges.

For unattended automation, the `kube` user must therefore be able to execute `sudo` commands without an interactive password.

On each Ubuntu Server node, create a dedicated sudoers configuration:

```bash
sudo visudo -f /etc/sudoers.d/kube
```

Add:

```sudoers
kube ALL=(ALL) NOPASSWD: ALL
```

Set the appropriate permissions:

```bash
sudo chmod 0440 /etc/sudoers.d/kube
```

Validate the sudoers configuration:

```bash
sudo visudo -cf /etc/sudoers.d/kube
```

Then verify passwordless sudo:

```bash
sudo -n true
```

The command should complete successfully without prompting for a password.

Privilege escalation can also be tested directly from the Ansible controller:

```bash
ansible all \
    -i ansible/inventory/dev \
    -b \
    -a 'whoami'
```

Every node should return:

```text
root
```

> `NOPASSWD: ALL` gives the automation user unrestricted sudo privileges. This configuration is convenient for this homelab and allows fully unattended Ansible execution. Production environments should follow the organization's privilege-management and security policies.

## Environment Configuration

Each environment is defined under:

```text
environments/<environment>/
```

For example:

```text
environments/dev/
├── cluster.yaml
└── vars.yaml
```

### Cluster Topology

`cluster.yaml` defines the servers belonging to the environment, their IP addresses and their Kubernetes roles.

Example:

```yaml
environment: dev

servers:
  - name: dev-control-plane
    ip_address: 192.168.56.10
    role: control_plane

  - name: dev-worker-1
    ip_address: 192.168.56.11
    role: worker

  - name: dev-worker-2
    ip_address: 192.168.56.12
    role: worker
```

This file acts as the source of truth for the infrastructure topology of the environment.

### Environment Variables

`vars.yaml` contains environment-specific software versions and Kubernetes configuration.

It currently defines configuration for components such as:

- containerd
- Kubernetes
- Kubernetes Pod CIDR
- Kubernetes Service CIDR
- Helm
- Cilium
- Cilium IPAM

Software versions are therefore kept outside the Ansible roles instead of being hardcoded directly into the automation logic.

## Ansible Inventory

The Ansible inventory is generated from the corresponding environment configuration.

The inventory entry points are located under:

```text
ansible/inventory/
```

For example, the DEV inventory can be inspected with:

```bash
ansible-inventory \
    -i ansible/inventory/dev \
    --graph
```

This should display the control plane and worker groups generated from:

```text
environments/dev/cluster.yaml
```

## Deploy the DEV Cluster

Before deployment, verify SSH connectivity:

```bash
ansible all \
    -i ansible/inventory/dev \
    -m ping
```

Then run the Kubernetes bootstrap playbook:

```bash
ansible-playbook \
    -i ansible/inventory/dev \
    ansible/playbooks/configure-nodes.yaml
```

The playbook performs the Kubernetes bootstrap process, including:

- Operating system preparation
- containerd installation and configuration
- Kubernetes repository configuration
- Kubernetes package installation
- Control plane initialization with `kubeadm`
- Helm installation
- Cilium installation
- Worker node joining

## Verify the Kubernetes Cluster

The cluster can be inspected from the control plane using:

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
```

The expected DEV topology is:

```text
dev-control-plane
dev-worker-1
dev-worker-2
```

All nodes should eventually report:

```text
STATUS   Ready
```

## Idempotence

The Ansible automation is designed to be safely executed multiple times.

After the initial cluster deployment, running the same playbook again should preserve the existing cluster state.

In particular, subsequent executions should not:

- initialize an already initialized control plane
- unnecessarily generate a new Kubernetes bootstrap token
- join workers that are already members of the cluster
- reinstall Helm when the requested version is already installed

Idempotence can be tested by executing the same playbook again:

```bash
ansible-playbook \
    -i ansible/inventory/dev \
    ansible/playbooks/configure-nodes.yaml
```

## Security

Secrets and credentials must not be committed to the repository.

The `.gitignore` excludes common sensitive files such as:

```text
*.tfstate
*.tfvars
*.kubeconfig
*.pem
*.key
.env
.vault_pass
```

Environment configuration files are intended to contain declarative infrastructure configuration such as:

- Node names
- Private IP addresses
- Kubernetes roles
- Software versions
- Cluster network configuration

They must not contain:

- Passwords
- Private SSH keys
- API tokens
- Access keys
- Secret keys
- Kubernetes credentials

## Project Status

The current implementation provides an automated Kubernetes bootstrap for the DEV environment using Ansible.

The project is being developed incrementally. Additional infrastructure and Kubernetes components will be introduced as the homelab evolves.

## AI Assistance

This project was built with the assistance of ChatGPT through interactive chat sessions.

ChatGPT was used during the implementation process to assist with technical explanations, troubleshooting, review, and documentation.

AI assistant used:

- ChatGPT
- Model: GPT-5.6 Sol
- Mode: Instant
