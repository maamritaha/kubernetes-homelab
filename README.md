# Kubernetes Homelab

A reproducible Kubernetes homelab configured with Ansible and designed for future infrastructure provisioning with Terraform.

The project emphasizes declarative configuration, environment isolation, idempotent automation, persistent storage, and separation of infrastructure from Kubernetes configuration.

## Architecture

The project supports three independent environments: `dev`, `test`, and `prod`. Each has its own cluster topology and configuration. Only DEV is currently deployed and validated.

| DEV node | IP address | Roles |
| --- | --- | --- |
| `dev-control-plane` | `192.168.56.10` | Control plane |
| `dev-worker-1` | `192.168.56.11` | Worker |
| `dev-worker-2` | `192.168.56.12` | Worker |
| `dev-storage-1` | `192.168.56.13` | Worker, Longhorn storage |
| `dev-storage-2` | `192.168.56.14` | Worker, Longhorn storage |

Storage nodes are Kubernetes workers dedicated to persistent storage. Labels and taints restrict regular application workloads while allowing required system components.

The platform networking stack is:

```text
Cilium (pod networking)
    ↓
MetalLB (LoadBalancer IPs, Layer 2)
    ↓
Traefik (Ingress)
    ↓
cert-manager (TLS certificates)
    ↓
HTTPS applications (including Longhorn UI)
```

## Project Structure

```text
kubernetes-homelab/
├── ansible/
│   ├── inventory/
│   │   └── ...
│   ├── playbooks/
│   │   └── configure-nodes.yaml
│   ├── roles/
│   │   └── ...
│   └── requirements.yaml
├── environments/
│   ├── dev/
│   │   ├── cluster.yaml
│   │   └── vars.yaml
│   ├── test/
│   │   └── ...
│   └── prod/
│       └── ...
├── terraform/                 # Planned infrastructure provisioning
├── certificates/              # Local private CA material (Git-ignored)
├── ansible.cfg
├── .gitignore
└── README.md
```

## Configuration Model

Each environment separates **cluster topology** (`cluster.yaml`) from **software and deployment settings** (`vars.yaml`). The topology is intended to be shared by Terraform and Ansible, avoiding duplicated server definitions.

Example from `environments/dev/cluster.yaml`:

```yaml
environment: dev

servers:
  - name: dev-control-plane
    ip_address: 192.168.56.10
    roles:
      - control_plane

  - name: dev-storage-1
    ip_address: 192.168.56.13
    roles:
      - worker
      - longhorn_storage
    longhorn_storage:
      path: /var/lib/longhorn
      exclusive: true

  # ...
```

## Dynamic Ansible Inventory

The Ansible inventory is generated from each environment's `cluster.yaml`:

```bash
ansible-inventory -i ansible/inventory/dev --graph
```

Groups such as `control_plane`, `workers`, and `longhorn_storage` are derived from server roles. Server IP addresses and roles are not duplicated in the inventory.

## Prerequisites

Target machines must run Ubuntu Server, be reachable over SSH, support Ansible privilege escalation (`become: true`), communicate with other cluster nodes, and access required package and container registries.

The Ansible control host requires Ansible and the project's collections:

```bash
ansible-galaxy collection install -r ansible/requirements.yaml
```

The project uses `community.general`, `kubernetes.core`, and `community.crypto`.

VM creation, host-only/NAT networking, SSH access, time synchronization, and storage-device preparation are infrastructure prerequisites. Terraform provisioning is planned but not yet implemented.

For the private certificate authority, the local Ansible Vault password file and encrypted CA material must be available. These secrets are not committed to Git.

## Deployment

Deploy the DEV cluster with:

```bash
ansible-playbook \
  -i ansible/inventory/dev \
  ansible/playbooks/configure-nodes.yaml
```

The playbook configures the cluster in stages:

```text
Local preflight validation
        ↓
Linux node configuration and containerd
        ↓
Kubernetes packages
        ↓
Control plane initialization and Helm
        ↓
Cilium CNI
        ↓
Worker and storage-node joins
        ↓
Cluster readiness checks (configurable retries and warning)
        ↓
Longhorn storage-node prerequisites
        ↓
MetalLB → Traefik → cert-manager
        ↓
Private CA and ClusterIssuer
        ↓
Longhorn installation and HTTPS ingress
```

The automation is designed to bootstrap prepared machines in one execution. Cluster readiness is checked globally, allowing temporary delays such as slow image downloads. Package installation tasks can wait for temporary APT lock contention.

## Kubernetes

Kubernetes is installed with `kubeadm`. Ansible configures the required Linux kernel settings, swap, containerd, Kubernetes packages, node IPs, control plane, and worker joins. Existing control planes and joined workers are not initialized or joined again on subsequent runs.

## Networking and HTTPS

**Cilium** provides pod networking using cluster-pool IPAM. `kubeProxyReplacement` is disabled, so Kubernetes Service routing remains the responsibility of `kube-proxy`.

**MetalLB** allocates LoadBalancer IPs from the DEV pool `192.168.56.200–192.168.56.220` and advertises them using Layer 2 on the host-only network interface `enp0s8`. FRR is disabled.

**Traefik** provides HTTP/HTTPS ingress. **cert-manager** issues certificates through a private homelab certificate authority and a Kubernetes `ClusterIssuer`.

The Longhorn UI is exposed at:

```text
https://longhorn.dev.homelab
```

On the host machine, local name resolution must point the hostname to the Traefik LoadBalancer IP, and the homelab root CA must be trusted. For example:

```text
192.168.56.200 longhorn.dev.homelab
```

Local DNS and host trust-store management are outside the current Ansible cluster deployment scope. The Longhorn UI does not include authentication by default; restrict access to trusted networks or add authentication before exposing it more broadly.

## Persistent Storage

**Longhorn** provides distributed persistent block storage. Storage nodes are declared with the `longhorn_storage` role in `cluster.yaml`, and their storage path defaults to `/var/lib/longhorn` in DEV.

When `exclusive: true`, a storage node receives a label and the taint `dedicated=longhorn-storage:NoSchedule`, keeping ordinary application workloads off dedicated storage nodes.

The `longhorn_storage` role creates the configured directory, installs `open-iscsi` and NFS client support, and enables `iscsid`. Longhorn is deployed through Helm, with node configuration managed declaratively through Ansible Kubernetes modules.

The default replica count is the smaller of the number of storage nodes and three. DEV has two storage nodes and therefore uses two replicas by default. Preparing, partitioning, and mounting a dedicated physical disk remain infrastructure responsibilities.

## Persistent Volume Validation

Dynamic PVC/PV provisioning, data persistence across Pod recreation, and the default `Delete` reclaim policy have been tested successfully.

Storage resilience was also validated by shutting down one storage VM: application data remained accessible through the remaining replica. After the VM restarted, Longhorn detected the returning node and recovered the volume's healthy state.

## Idempotence

The Ansible automation is designed for repeated execution without reinitializing the control plane, rejoining workers, or recreating resources already in their desired state. Clean-snapshot bootstraps and subsequent convergence have been exercised during development; transient registry connectivity and APT locks are handled through configurable waits where applicable.

## Environment Isolation

DEV, TEST, and PROD are modeled as separate Kubernetes clusters rather than namespaces in a shared cluster.

| Environment | Planned network |
| --- | --- |
| DEV | `192.168.56.0/24` |
| TEST | `192.168.57.0/24` |
| PROD | `192.168.58.0/24` |

Only DEV is currently deployed and validated.

## Security

Private keys, Ansible Vault passwords, kubeconfig files, Terraform state, and other sensitive local files must remain outside version control. The local root CA certificate and its encrypted private key are stored in environment-specific paths and excluded by `.gitignore`.

The CA is intended for trusted homelab use. Privileged machine access is a provisioning prerequisite, not configured by this repository. Production credentials require an appropriate secret-management solution.

## Current Status

Implemented in DEV:

- Declarative multi-environment project structure and dynamic Ansible inventory
- Automated Linux, containerd, Kubernetes, Helm, and Cilium configuration
- Automatic worker joins and configurable cluster readiness checks
- MetalLB Layer 2 LoadBalancer networking and Traefik ingress
- cert-manager with a private CA and HTTPS certificates
- Longhorn installation, dedicated storage nodes, and HTTPS UI
- Dynamic volume provisioning, replica persistence, failure/recovery, and reclaim validation
- Idempotent configuration and clean-snapshot bootstrap testing
- S3-compatible object storage
- Application workload deployment and CI/CD integration
- 
## Roadmap

Planned work includes:

- Terraform VM and networking provisioning
- External Longhorn backup target
- Automated cleanup before infrastructure destruction
- TEST and PROD cluster validation

## Design Principles

**Single source of truth:** Infrastructure topology is declared once in `cluster.yaml`.

**Separation of concerns:** Infrastructure, OS configuration, Kubernetes services, and workloads remain separate responsibilities.

**Declarative configuration:** Prefer Ansible modules and Kubernetes APIs over imperative shell commands.

**Idempotence:** Repeated executions converge toward the intended state.

**Replaceable infrastructure:** Clusters should be reproducible without depending on manually maintained VM state.

**Environment isolation:** DEV, TEST, and PROD are independent environments.

## AI Assistance

This is a personal Kubernetes homelab and learning project. ChatGPT has been used to assist with Kubernetes concepts, troubleshooting, code review, and documentation. Architecture decisions, implementation, and validation remain part of the project's development process.
