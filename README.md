# Azure DevOps Ephemeral Agent

## Purpose

This image runs a temporary self-hosted Azure DevOps agent in an Azure Container Apps Job. At startup, it downloads and registers the current Linux x64 Azure DevOps agent, runs exactly one pipeline job, removes its registration, and exits.

## Included tools

- PowerShell 7
- Azure CLI with the `azure-devops` and `containerapp` extensions
- Terraform and Packer
- Git, curl, jq, unzip, zip, OpenSSH client, rsync, and CA certificates
- PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Compute`, `Az.Network`, `Az.ManagedServiceIdentity`, and `Az.DesktopVirtualization`

## Image location

Published images are expected at `ghcr.io/<owner>/azure-devops-agent`.

## Runtime environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `AZP_URL` | Yes | Azure DevOps organization URL |
| `AZP_POOL` | Yes | Azure DevOps agent pool name |
| `AZP_TOKEN` | Yes | PAT used for agent registration and pool polling |
| `AZP_AGENT_NAME` | No | Agent name |
| `AZP_WORK` | No | Agent work directory |

The PAT needs at least the Azure DevOps scope `Agent Pools: Read & manage`.

## Security

Never store secrets in the image or repository. Supply `AZP_TOKEN` only at runtime through a secret mechanism. The image may be public when it contains no internal files or secrets. Prefer an immutable SHA tag or digest over `latest` for deployments.

For Azure access in pipeline jobs, use Azure DevOps service connections with workload identity federation where possible.

## Local build

```bash
docker build \
  --build-arg TERRAFORM_VERSION=<version> \
  --build-arg PACKER_VERSION=<version> \
  -t azure-devops-agent:local .
```

## Local verification

Run tool validation without registering an Azure DevOps agent:

```bash
docker run --rm \
  --entrypoint pwsh \
  azure-devops-agent:local \
  -NoLogo \
  -NoProfile \
  -File /azp/verify-tools.ps1
```

## Runtime example

```bash
docker run --rm \
  -e AZP_URL="https://dev.azure.com/example" \
  -e AZP_POOL="example-pool" \
  -e AZP_TOKEN="<secret>" \
  ghcr.io/example/azure-devops-agent:latest
```

Shell command history can retain secrets. Prefer a container-platform secret mechanism instead of putting a PAT directly on a command line.

## One-job lifecycle

1. The container starts.
2. The current agent is downloaded.
3. The agent is registered.
4. One pipeline job runs.
5. The registration is removed.
6. The container stops.

## Limitations

- Linux only and AMD64 only.
- No Docker daemon is included.
- Docker-in-Docker is not supported.
- Pipelines that need local Docker require another agent solution.
- Only the preinstalled tools and modules are guaranteed to be available.

## Publishing

GitHub Actions builds pull requests without pushing. Builds from `main` push to GHCR, publish SHA tags, an SBOM, and provenance. A monthly scheduled build refreshes OS patches and upstream packages.

## Making the package public

After the first push, make the package public from its GitHub Package Settings page.
