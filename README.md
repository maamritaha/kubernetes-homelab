# Kubernetes Homelab

A reproducible Kubernetes homelab built with Ansible and designed to be provisioned with Terraform.

The project focuses on declarative configuration, environment isolation, idempotent automation, persistent storage, and a clear separation between infrastructure and Kubernetes configuration.

## Architecture

The homelab supports multiple isolated environments:

- `dev`
- `test`
- `prod`

Each environment has its own cluster definition and software configuration.

The current DEV cluster contains:

| Node | IP address | Roles |
| --- | --- | --- |
| `dev-control-plane` | `192.168.56.10` | Control plane |
| `dev-worker-1` | `192.168.56.11` | Worker |
| `dev-worker-2` | `192.168.56.12` | Worker |
| `dev-storage-1` | `192.168.56.13` | Worker, Longhorn storage |
| `dev-storage-2` | `192.168.56.14` | Worker, Longhorn storage |

The storage nodes are Kubernetes workers dedicated to persistent storage. They can run Kubernetes system workloads but are protected from regular application workloads using labels and taints.

## Project Structure

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
│   │   ├── worker/
│   │   ├── helm/
│   │   ├── cni/
│   │   ├── longhorn_storage/
│   │   └── longhorn/
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
├── .gitignore
└── README.md
```

## Configuration Model

Each environment is defined by two files with separate responsibilities.

### `cluster.yaml`

Defines the infrastructure topology:

- server names
- IP addresses
- Kubernetes roles
- storage roles
- node-specific storage configuration

Example:

```yaml
environment: dev

servers:
  - name: dev-control-plane
    ip_address: 192.168.56.10
    roles:
      - control_plane

  - name: dev-worker-1
    ip_address: 192.168.56.11
    roles:
      - worker

  - name: dev-worker-2
    ip_address: 192.168.56.12
    roles:
      - worker

  - name: dev-storage-1
    ip_address: 192.168.56.13
    roles:
      - worker
      - longhorn_storage
    longhorn_storage:
      path: /var/lib/longhorn
      exclusive: true

  - name: dev-storage-2
    ip_address: 192.168.56.14
    roles:
      - worker
      - longhorn_storage
    longhorn_storage:
      path: /var/lib/longhorn
      exclusive: true
```

The same topology definition is intended to be consumed by both Terraform and Ansible, avoiding duplicated infrastructure information.

### `vars.yaml`

Defines environment-specific software versions and Kubernetes configuration.

Example:

```yaml
container_runtime:
  name: containerd
  version: "2.2.2"
  package_version: "2.2.2-0ubuntu1.1"

kubernetes:
  version: "1.36.4"
  package_version: "1.36.4-1.1"
  repository_url: "https://pkgs.k8s.io/core:/stable"

  cluster:
    pod_network_cidr: "10.244.0.0/16"
    service_cidr: "10.96.0.0/12"

helm:
  version: "4.3.0"
  repository_url: "https://get.helm.sh"

cni:
  name: cilium
  version: "1.20.2"
  repository_url: "https://helm.cilium.io/"
  kube_proxy_replacement: false

  ipam:
    mode: cluster-pool

longhorn:
  version: "1.13.0"
  repository_url: "https://charts.longhorn.io"
```

## Dynamic Ansible Inventory

The Ansible inventory is generated dynamically from the environment's `cluster.yaml`.

For example:

```bash
ansible-inventory -i ansible/inventory/dev --graph
```

produces groups based on the roles assigned to each server:

```text
@all:
  |--@control_plane:
  |  |--dev-control-plane
  |--@workers:
  |  |--dev-worker-1
  |  |--dev-worker-2
  |  |--dev-storage-1
  |  |--dev-storage-2
  |--@longhorn_storage:
  |  |--dev-storage-1
  |  |--dev-storage-2
```

This keeps server topology in a single source of truth instead of duplicating IP addresses and roles in the Ansible inventory.

## Prerequisites

Target machines must:

- run Ubuntu Server;
- be reachable from the Ansible control host over SSH;
- use an Ansible user able to execute privileged tasks with `become: true`;
- have network connectivity between cluster nodes;
- have access to the required package repositories.

The Ansible control host requires Ansible and the project collections.

Install the required collections with:

```bash
ansible-galaxy collection install -r ansible/requirements.yaml
```

The current project uses:

- `community.general`
- `kubernetes.core`

Infrastructure-level requirements such as VM creation, networking, SSH access, clock synchronization, and storage device preparation are expected to be handled before running the Kubernetes automation.

## Deployment

Deploy the DEV cluster with:

```bash
ansible-playbook \
  -i ansible/inventory/dev \
  ansible/playbooks/configure-nodes.yaml
```

The playbook configures the cluster in stages:

```text
Linux node configuration
        ↓
containerd
        ↓
Kubernetes packages
        ↓
Control plane initialization
        ↓
Helm
        ↓
Cilium
        ↓
Worker node join
        ↓
Longhorn storage node preparation
        ↓
Longhorn
```

A clean cluster can be bootstrapped from prepared machines with a single Ansible execution.

## Kubernetes

The Kubernetes deployment is based on `kubeadm`.

Ansible handles:

- required Linux kernel configuration;
- swap configuration;
- containerd installation and configuration;
- Kubernetes repository configuration;
- `kubelet`, `kubeadm`, and `kubectl` installation;
- control plane initialization;
- worker join token generation;
- automatic worker node joining;
- node IP configuration.

Worker joins are idempotent and are skipped when a node is already part of the cluster.

## Networking

Cilium is used as the Kubernetes CNI.

It is installed through Helm after control plane initialization.

The current configuration uses:

```yaml
cni:
  name: cilium
  kube_proxy_replacement: false

  ipam:
    mode: cluster-pool
```

Cilium runs on regular workers as well as dedicated storage workers so that all Kubernetes nodes retain cluster networking.

## Persistent Storage

Longhorn provides distributed persistent block storage for Kubernetes workloads.

Storage-capable nodes are declared directly in `cluster.yaml`:

```yaml
roles:
  - worker
  - longhorn_storage

longhorn_storage:
  path: /var/lib/longhorn
  exclusive: true
```

### Storage path

Longhorn does not require a dedicated physical disk.

For the current homelab, the storage path is:

```text
/var/lib/longhorn
```

If a separate storage device is used, its filesystem and mount point are considered an infrastructure responsibility. Ansible does not partition or format storage devices.

### Dedicated storage nodes

When:

```yaml
exclusive: true
```

the node receives a Kubernetes label and taint:

```text
node-role.longhorn.io/storage=true
dedicated=longhorn-storage:NoSchedule
```

This prevents regular application workloads from being scheduled on dedicated storage nodes while allowing required system components to run through appropriate tolerations.

### Longhorn node preparation

The `longhorn_storage` role prepares storage nodes by:

- creating the configured storage directory;
- installing `open-iscsi`;
- installing NFS client support;
- enabling and starting `iscsid`.

### Longhorn deployment

Longhorn is installed through Helm.

Node annotations, labels, and taints are managed declaratively through the `kubernetes.core` Ansible collection.

Only nodes explicitly configured with the `longhorn_storage` role receive Longhorn storage disks.

The default replica count is calculated from the number of available Longhorn storage nodes and capped at three replicas.

For example:

```text
2 storage nodes → 2 replicas
3 storage nodes → 3 replicas
4 storage nodes → 3 replicas
```

## Persistent Volume Validation

The storage configuration has been validated with Kubernetes dynamic provisioning.

The tested lifecycle includes:

```text
PVC
 ↓
Longhorn StorageClass
 ↓
Dynamic PV
 ↓
Longhorn volume
 ↓
Replicas on storage nodes
 ↓
Pod volume mount
```

Persistence was verified by deleting and recreating a Pod while keeping its PVC. The recreated Pod successfully recovered the existing data.

Storage node failure was also tested by abruptly stopping one Longhorn storage VM.

The volume transitioned from:

```text
healthy
  ↓
degraded
  ↓
healthy
```

while the application remained able to access its data through the remaining replica.

After the failed storage node returned, Longhorn automatically restored the volume to a healthy state.

PVC deletion was also validated with the default `Delete` reclaim policy, removing the associated PV and Longhorn volume.

## Idempotence

The Ansible automation is designed to be idempotent.

Running the same playbook multiple times does not:

- reinitialize an existing control plane;
- rejoin existing workers;
- reinstall existing Helm releases unnecessarily;
- recreate existing Longhorn configuration;
- duplicate Kubernetes labels, annotations, or taints.

The complete Kubernetes, Cilium, and Longhorn bootstrap has also been validated from clean VM snapshots using a single Ansible execution.

A subsequent execution converges without modifying Kubernetes or Longhorn resources that are already in the desired state.

## Environment Isolation

DEV, TEST, and PROD are represented as separate environments:

```text
environments/
├── dev/
├── test/
└── prod/
```

Each environment has its own topology and software configuration.

The intended architecture uses separate Kubernetes clusters for each environment rather than namespaces as the primary isolation mechanism.

Example network plan:

| Environment | Network |
| --- | --- |
| DEV | `192.168.56.0/24` |
| TEST | `192.168.57.0/24` |
| PROD | `192.168.58.0/24` |

Only the DEV cluster is currently deployed and validated.

## Security

Secrets, private SSH keys, kubeconfig files, Terraform state, and other sensitive local files are excluded from version control.

Privileged access required by Ansible is considered part of the machine provisioning contract and is not configured by this repository.

Production credentials and secrets should be managed using an appropriate secret-management solution rather than committed to the repository.

## Current Status

Implemented:

- Multi-environment project structure (`dev`, `test`, `prod`)
- Shared declarative cluster topology
- Dynamic Ansible inventory
- Common Linux node configuration
- containerd installation and configuration
- Kubernetes installation with `kubeadm`
- Control plane initialization
- Automatic worker joining
- Helm installation
- Cilium CNI deployment
- Longhorn storage node preparation
- Longhorn deployment through Helm
- Declarative Longhorn node configuration with `kubernetes.core`
- Dedicated storage nodes using labels and taints
- Dynamic Longhorn replica count
- Dynamic Kubernetes persistent volume provisioning
- Persistent data validation
- Longhorn storage-node failure and recovery validation
- PVC/PV reclaim lifecycle validation
- Idempotent Kubernetes and Longhorn configuration
- Single-run bootstrap validated from clean VM snapshots

## Roadmap

Planned work includes:

- Terraform infrastructure provisioning
- Traefik ingress configuration
- cert-manager
- Automatic HTTPS certificates
- Longhorn UI exposure through HTTPS
- S3-compatible object storage
- External Longhorn backup target
- Application workload deployment
- Automated Kubernetes and Longhorn cleanup before infrastructure destruction
- Additional TEST and PROD cluster validation

## Design Principles

The project follows a few core principles:

**Single source of truth**

Infrastructure topology is declared once in `cluster.yaml` and consumed by automation.

**Separation of concerns**

Infrastructure provisioning, operating system configuration, Kubernetes configuration, and application deployment remain separate responsibilities.

**Declarative configuration**

Kubernetes resources are managed through declarative Ansible modules whenever possible instead of imperative shell commands.

**Idempotence**

Automation can be executed repeatedly and converges toward the desired state.

**Replaceable infrastructure**

The cluster should be reproducible from configuration rather than depending on manually maintained VM state.

**Environment isolation**

DEV, TEST, and PROD are modeled as independent environments.

## AI Assistance

This project is designed and implemented as a personal Kubernetes homelab and learning project.

ChatGPT was used as an assistant for Kubernetes concepts, troubleshooting, code review, and documentation.

The infrastructure architecture, implementation decisions, configuration, testing, and validation remain part of the project development process rather than being generated as an autonomous AI-designed system.
