# Azure DevOps Ephemeral Agent

## Purpose

This multi-architecture Linux image runs a temporary Azure DevOps self-hosted agent in an Azure Container Apps Job. It supports `linux/amd64` and `linux/arm64`; GHCR publishes both platforms in one image manifest, and Docker selects the matching architecture automatically. The startup flow follows Microsoft's documented [Docker agent pattern](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/docker?view=azure-devops).

## Included tools

- Ubuntu 24.04
- Azure Pipelines agent 5.279.0, installed at image build time
- PowerShell 7.6.6, installed with architecture-specific SHA256 verification (amd64 `.deb`; arm64 release tarball with Ubuntu 24.04 `libicu74`)
- Azure CLI with the `azure-devops` and `containerapp` extensions
- Terraform 1.16.5 and Packer 1.16.1
- Git, curl, jq, unzip, zip, OpenSSH client, rsync, and CA certificates
- PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Compute`, `Az.Network`, `Az.ManagedServiceIdentity`, and `Az.DesktopVirtualization`

PowerShell, Terraform, Packer, and Azure Pipelines agent versions are pinned in the Dockerfile and build workflow. The agent is installed during image build at version **5.279.0**, using Microsoft's architecture-specific packages. This makes startup faster and deterministic because the agent is no longer downloaded at container startup. Updating the agent requires changing the explicit `AZP_AGENT_VERSION` pin and rebuilding/publishing the image. Monthly rebuilds refresh the OS and upstream packages without silently changing this pin. Azure CLI comes from Microsoft's Ubuntu repository; the `azure-devops` and `containerapp` extensions are installed explicitly, including preview support for `containerapp`. Tool verification runs during image build on both architectures.

## Image location and tags

GitHub Actions publishes a single multi-platform image index at `ghcr.io/<owner>/azure-devops-agent`. Main branch builds publish `latest`, a date/run-number tag, and a commit-based `sha-<commit>` convenience tag. Each tag resolves to both `linux/amd64` and `linux/arm64`, and Docker chooses the matching platform. The SHA tag can be republished by the monthly rebuild, so it does not guarantee an immutable image. Pull requests build both architectures without pushing. A monthly scheduled build refreshes Ubuntu security updates and upstream packages.

For Azure Container Apps deployments, pin the image by digest for true immutability. The `sha-<commit>` tag is useful for identifying source but can move when that commit is rebuilt. Use `latest` for convenience in development only.

Pull the published image and inspect its platform manifests:

```bash
docker pull ghcr.io/breento/azure-devops-agent:latest
docker buildx imagetools inspect ghcr.io/breento/azure-devops-agent:latest
```

## Authentication

There are two separate authentication concerns.

### Azure DevOps agent registration and runtime

Select registration authentication with `AZP_AUTH`. It defaults to `pat`.

For PAT mode, set `AZP_AUTH=pat` and `AZP_TOKEN=<PAT>`. The PAT is used only for registration and removal. The token is passed to the agent configuration script through its supported `VSTS_AGENT_INPUT_TOKEN` environment input.

For Managed Identity mode, set `AZP_AUTH=managedidentity` and `AZP_MANAGED_IDENTITY_CLIENT_ID=<CLIENT_ID>`. The Container Apps identity endpoint variables `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` must also be present. The image requests an Azure DevOps resource token directly from that endpoint at registration and obtains a fresh token again before removal. It does not use Azure CLI, a PAT, client secret, or certificate for this mode. Azure DevOps documents OAuth 2.0 tokens as valid values for the agent's `--token` input; the `pat` auth label is the agent's configuration interface, not a claim that the token is a PAT. See Microsoft's [agent configuration documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/v2-windows), [Entra token guidance](https://learn.microsoft.com/en-us/azure/devops/cli/entra-tokens?view=azure-devops), and [Container Apps managed identity endpoint reference](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity).

The former service-principal environment variables (`AZP_CLIENTID`, `AZP_CLIENTSECRET`, `AZP_TENANTID`) remain supported when `AZP_AUTH` is omitted, for compatibility with existing deployments. Explicit `AZP_AUTH=pat` selects PAT mode.

### Azure resource access from pipeline jobs

Use Azure DevOps service connections with workload identity federation for Azure deployments where supported. The registration service principal exists to register and clean up the ephemeral agent; do not reuse it as a general Azure deployment identity unless that is an explicit requirement and its permissions have been deliberately scoped.

## Azure Container Apps Jobs runtime

Configure these environment variables for each job execution:

| Variable | Required | Description |
| --- | --- | --- |
| `AZP_URL` | Yes | Azure DevOps organization URL, such as `https://dev.azure.com/example` |
| `AZP_POOL` | Yes | Target agent pool name |
| `AZP_AUTH` | No | `pat` (default) or `managedidentity` |
| `AZP_TOKEN` | PAT mode | Azure DevOps PAT with Agent Pools read/manage scope |
| `AZP_MANAGED_IDENTITY_CLIENT_ID` | Managed Identity mode | User-Assigned Managed Identity client ID |
| `IDENTITY_ENDPOINT` | Managed Identity mode | Supplied by Azure Container Apps |
| `IDENTITY_HEADER` | Managed Identity mode | Supplied by Azure Container Apps; treated as a secret |
| `AZP_CLIENTID` | Legacy service-principal mode | Existing service principal client ID |
| `AZP_CLIENTSECRET` | Legacy service-principal mode | Existing service principal secret |
| `AZP_TENANTID` | Legacy service-principal mode | Existing service principal tenant ID |
| `AZP_AGENT_NAME` | No | Agent name; defaults to a unique name for each container execution |
| `AZP_WORK` | No | Agent work directory; defaults to `/azp/_work` |

Managed Identity prerequisites: create a User-Assigned Managed Identity, attach it to the Azure Container Apps Job, add the identity to the Azure DevOps organization, and grant Agent Pool Administrator permissions on the target pool for registration and removal. No PAT is required in this mode. `AZP_URL`, `AZP_POOL`, and optional `AZP_AGENT_NAME` are shared settings. The image itself creates no Azure resources.

KEDA scaler authentication is separate from agent registration authentication. This change does not alter the scaler's existing identity configuration.

For local-only PAT testing, set `AZP_AUTH=pat` and provide `AZP_TOKEN`.

## Local build

```bash
docker build \
  --build-arg POWERSHELL_VERSION=7.6.6 \
  --build-arg TERRAFORM_VERSION=1.16.5 \
  --build-arg PACKER_VERSION=1.16.1 \
  --build-arg AZP_AGENT_VERSION=5.279.0 \
  -t azure-devops-agent:local .
```

PowerShell package SHA256 values are pinned separately for amd64 and arm64 in the Dockerfile: amd64 uses the official `.deb` checksum, and arm64 uses the official Linux ARM64 release tarball checksum. The arm64 tarball is installed under `/opt/microsoft/powershell/7` with `libicu74` from Ubuntu 24.04. Build both variants with Buildx using `--platform linux/amd64,linux/arm64`.

Run tool validation without registering an agent:

```bash
docker run --rm \
  --entrypoint pwsh \
  azure-devops-agent:local \
  -NoLogo -NoProfile -File /azp/verify-tools.ps1
```

## One-job lifecycle

1. The container starts and gets an Azure DevOps registration token. The pinned agent package is already installed in the image, so startup does not download it.
2. The preinstalled agent is registered under a unique name.
3. `run.sh --once` accepts exactly one pipeline job, then exits.
4. The registration is removed, including when the container receives `SIGTERM` or `SIGINT`.
5. The container exits with the agent process status; startup and job failures return non-zero.

## Limitations

- Linux amd64 and arm64 are supported. PowerShell, Terraform, and Packer are installed for both architectures.
- No Docker daemon is included. Pipelines that need local Docker require another agent setup.
- Only the preinstalled tools and modules are guaranteed to be available.

## Making the package public

After the first push, make the package public from its GitHub Package Settings page if public access is desired.
