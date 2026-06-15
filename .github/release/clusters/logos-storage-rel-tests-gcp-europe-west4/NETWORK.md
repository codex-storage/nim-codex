# VPC Architecture

## Purpose

The original purpose of creating a VPC was to allow increasing the number of pods, and therefore number of nodes given the anti-affinity constraint that enforces one pod per node, beyond 8, which is the default quota for external IPs given by Google. Adding a VPC means the number of nodes can be scaled to the limits of the VPC, not to the  limits of the external IP quota, since each node no longer needs its own external IP. The VPC allows for the nodes to communicate with the wider internet, outbound only, for functions like pulling docker images, and dependency management.

## Architecture design
```ascii
                                    Internet
                                        │
                                        │ (public endpoint, no
                                        │  master_authorized_networks)
                                        ▼
                          ┌──────────────────────────┐
                          │   GKE Control Plane      │
                          │  (Google-managed, peered)│
                          │  172.16.0.0/28           │
                          └────────────┬─────────────┘
                                       │ private peering
┌───────────────────────────────────── │ ──────────────────────────────────┐
│  VPC: logos-storage-rel-tests-vpc    │                                   │
│  (custom, auto_create_subnetworks=false)                                 │
│                                      ▼                                   │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │ Subnet: logos-storage-rel-tests-subnet  (europe-west4)            │   │
│  │ primary range:        10.10.0.0/20   ← node internal IPs          │   │
│  │ secondary "pods":     10.20.0.0/14   ← pod IPs (VPC-native)       │   │
│  │ secondary "services": 10.30.0.0/20   ← ClusterIP services         │   │
│  │                                                                   │   │
│  │   ┌─────────────┐  ┌─────────────┐       ┌─────────────┐          │   │
│  │   │ GKE node 1  │  │ GKE node 2  │  ...  │ GKE node N  │          │   │
│  │   │ 10.10.0.x   │  │ 10.10.0.x   │       │ 10.10.0.x   │          │   │
│  │   │ no ext IP   │  │ no ext IP   │       │ no ext IP   │          │   │
│  │   │ pods:10.20.x│  │ pods:10.20.x│       │ pods:10.20.x│          │   │
│  │   └─────┬───────┘  └─────┬───────┘       └─────┬───────┘          │   │
│  └─────────┼────────────────┼─────────────────────┼──────────────────┘   │
│            └────────────────┴───────────┬─────────┘                      │
│                    node-to-node / pod-to-pod traffic, all internal       │
│                                         │                                │
│                                         ▼                                │
│                          ┌──────────────────────────────┐                │
│                          │ Cloud Router + Cloud NAT     │                │
│                          │ (logos-storage-rel-tests-*)  │                │
│                          └──────────────┬───────────────┘                │
└─────────────────────────────────────────│────────────────────────────────┘
                                          ▼
                                       Internet
                              (image pulls, package mirrors,
                               outbound only — no inbound)
```
- Custom VPC + subnet replace the project's default network, giving us a dedicated address space with the secondary ranges GKE's VPC-native (alias-IP) mode requires.
- Three non-overlapping ranges on one subnet: node IPs (/20), pod IPs (/14), service IPs (/20) — ip_allocation_policy points the cluster at the pods/services secondary ranges.
- Nodes have no external IPs (enable_private_nodes = true) — node-to-node and pod-to-pod traffic stays entirely inside the VPC, satisfying the test framework's "real network" requirement without touching the constrained IN_USE_ADDRESSES quota.
- Cloud Router + Cloud NAT give the otherwise IP-less nodes outbound-only internet access (pulling container images, etc.), with no inbound exposure.
- Control plane keeps its public endpoint (enable_private_endpoint = false) — only the nodes are private, so the GitHub-hosted CI runner can still kubectl/terraform apply against the cluster's API server over the internet.