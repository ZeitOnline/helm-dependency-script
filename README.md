# helm-dependency-script
Tools for identifying Bitnami dependencies in Kubernetes environments through both Helm charts and container images.

## Motivation

This project was created in response to Bitnami's policy changes announced in [this GitHub issue](https://github.com/bitnami/charts/issues/35164). Bitnami has made significant changes to their availability and support model, including:

- Moving charts from traditional Helm repositories to VMware-owned container registries
- Changing licensing terms for their charts and container images
- Implementing authentication requirements for accessing resources

These changes affect organizations in two critical ways:
1. **Helm chart dependencies** - Charts that depend on Bitnami charts may need reconfiguration
2. **Container images** - Pods running Bitnami images may need migration to alternative images

To properly assess the impact of these changes on your infrastructure, you need visibility into both aspects. This project provides two complementary tools that help you:

1. Identify Helm releases with Bitnami chart dependencies (direct or indirect)
2. Locate all pods running Bitnami container images
3. Plan comprehensive migration strategies for affected components

## Features

### Helm Dependency Analyzer (`get_helm_deps.sh`)
- Lists Helm releases across namespaces or in a specific namespace
- Displays complete dependency trees for each release
- Supports recursive dependency lookup to find nested dependencies
- Works with both OCI and HTTP-based Helm repositories
- Identifies chart repositories in the dependency chain

### Container Image Analyzer (`get_container_images.sh`)
- Locates all pods running images matching specified patterns (e.g., "bitnami")
- Groups results by namespace for better organization
- Shows which pods are using each matching image
- Supports namespace filtering for targeted analysis
- Works with both regular containers and init containers

## Prerequisites

- `helm` - Helm CLI tool (required for chart dependency analysis)
- `jq` - JSON processor for parsing output
- `kubectl` - Kubernetes CLI with access to your cluster

## Usage

### Analyzing Helm Dependencies

```bash
# List all Helm releases and their immediate dependencies
./get_helm_deps.sh

# List releases in a specific namespace
./get_helm_deps.sh -n <namespace>

# Enable recursive dependency lookup (shows nested dependencies)
./get_helm_deps.sh -r
```

### Finding Bitnami Container Images

```bash
# List all pods using Bitnami images across all namespaces
./get_container_images.sh bitnami

# Search for images in a specific namespace
./get_container_images.sh bitnami -n <namespace>

# Look for other image types
./get_container_images.sh redis
```

For GitHub Container Registry authentication:
```bash
gh auth token | helm registry login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

## Output Examples

### Helm Dependency Analyzer

When running with recursive dependency lookup (`-r`), you'll see nested dependencies:

```
================================================================================
Release:       my-release
Namespace:     default
Status:        deployed
Chart:         app-1.0.0
App Version:   1.0.0
--------------------------------------------------------------------------------
Dependency Tree:
  app-1.0.0
    NAME                           VERSION              REPOSITORY
    └── application                  2.3.4                https://example.com/charts/
        ├── redis:20.13.4 (oci://registry-1.docker.io/bitnamicharts)
            └── common:2.30.0 (oci://registry-1.docker.io/bitnamicharts)
        └── common:2.31.3 (oci://registry-1.docker.io/bitnamicharts)
```

### Container Image Analyzer

When searching for container images matching "bitnami":

```
================================================================================
Namespace: default
--------------------------------------------------------------------------------
IMAGE                                                                     PODS
-----                                                                     ----
docker.io/bitnami/redis:7.2.4-debian-12-r3                               redis-master, redis-replicas-0
docker.io/bitnami/redis-exporter:1.55.0-debian-12-r3                     redis-metrics-exporter

================================================================================
Namespace: monitoring
--------------------------------------------------------------------------------
IMAGE                                                                     PODS
-----                                                                     ----
registry-1.docker.io/bitnami/postgres-exporter:0.15.0-debian-12-r8       postgres-exporter-0

================================================================================
Done.
```

This format makes it easy to see which namespaces contain matching images and which pods are using them.

## License

MIT License - See [`LICENSE`](LICENSE) file for details.
