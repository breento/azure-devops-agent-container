# Azure DevOps Ephemeral Agent

## Purpose

This multi-architecture Linux image runs a temporary Azure DevOps self-hosted agent in an Azure Container Apps Job. It supports `linux/amd64` and `linux/arm64`; GHCR publishes both platforms in one image manifest, and Docker selects the matching architecture automatically. The startup flow follows Microsoft's documented [Docker agent pattern](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/docker?view=azure-devops).

## Included tools

- Ubuntu 24.04
- Azure Pipelines agent 5.279.0, installed at image build time
- PowerShell 7.6.6, installed with architecture-specific SHA256 verification (amd64 `.deb`; arm64 release tarball with Ubuntu 24.04 `libicu74`)
- Azure CLI 2.92.0 with the `azure-devops` and `containerapp` extensions
- Terraform 1.17.1 and Packer 1.16.2
- Git, curl, jq, unzip, zip, OpenSSH client, rsync, and CA certificates
- PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Compute`, `Az.Network`, `Az.ManagedServiceIdentity`, and `Az.DesktopVirtualization`

PowerShell, Azure CLI, Terraform, Packer, and Azure Pipelines agent versions are pinned in the Dockerfile and build workflow. The agent is installed during image build at version **5.279.0**, using Microsoft's architecture-specific packages. This makes startup faster and deterministic because the agent is no longer downloaded at container startup. Updating the agent requires changing the explicit `AZP_AGENT_VERSION` pin and rebuilding/publishing the image. Azure CLI is installed from Microsoft's Ubuntu repository at the pinned version; the `azure-devops` and `containerapp` extensions are installed explicitly, including preview support for `containerapp`. Tool verification runs during image build on both architectures.

## Container user and writable paths

The image runs as fixed UID `1001`, GID `1003` (`azp`) with `HOME=/home/azp`; it does not enable `AGENT_ALLOW_RUNASROOT`. The agent installation and `_diag` directory, default `/azp/_work`, and home-based runtime state directories are prepared and owned by this user at build time. A build-time smoke check, itself run as UID 1001:GID 1003, creates, modifies, and removes workspace files and checks agent, diagnostics, home, Azure CLI, Terraform, and configuration paths. The Azure CLI extensions are installed in a read-only system extension directory so they remain available after the process changes from build-time root to the runtime user. No runtime `chown`, Linux capability, host volume, privileged mode, or Docker socket is needed.

`AZP_WORK` may still override `/azp/_work`; a custom path must already be writable by UID 1001:GID 1003. Azure CLI login caches, PowerShell user state, Terraform plugin state, and Packer user configuration are stored under the ephemeral container home. They disappear with the container.

## Image location and tags

GitHub Actions runs the regression tests and syntax checks for pushes to `main`, pull requests targeting `main`, and manual dispatches. Pull requests also build and validate both architectures without publishing. After successful tests, pushes to `main` and manual runs on `main` publish a multi-platform image index at `ghcr.io/breento/azure-devops-agent`. The tags are `sha-<7-character-commit-sha>` and `latest`. Concurrent runs for the same branch are serialized. Each tag resolves to both `linux/amd64` and `linux/arm64`, and Docker chooses the matching platform. A SHA tag identifies source but is not an immutable image reference; pin deployments by OCI index digest.

For Azure Container Apps deployments, pin the image by digest for true immutability. The `sha-<commit>` tag is useful for identifying source but can move when that commit is rebuilt. Use `latest` for convenience in development only.

Pull the published image and inspect its platform manifests:

```bash
docker pull ghcr.io/breento/azure-devops-agent:latest
docker buildx imagetools inspect ghcr.io/breento/azure-devops-agent:latest
```

The `Digest` printed by `imagetools inspect` is the OCI index digest. For an exact reference use `ghcr.io/breento/azure-devops-agent@sha256:<digest>`. The workflow also checks the published index contains both required Linux architectures and records the digest in its run summary.

To roll a new image into `DockerInfrastructure`, first wait for the `main` workflow to pass and publish both architectures. Copy the reported OCI index digest into the existing image reference there, review that infrastructure diff, then deploy through the normal infrastructure release process. Keep the existing Oracle image running until that image has been built and validated successfully.

## Authentication

There are separate authentication concerns for registering an agent and for pipeline tasks.

### Azure DevOps agent registration and runtime

Select registration authentication with `AZP_AUTH`. It defaults to `pat`.

For PAT mode, set `AZP_AUTH=pat` and `AZP_TOKEN=<PAT>`. The PAT is used only for registration and removal. The token is passed to the agent configuration script through its supported `VSTS_AGENT_INPUT_TOKEN` environment input.

For Managed Identity mode, set `AZP_AUTH=managedidentity` and `AZP_MANAGED_IDENTITY_CLIENT_ID=<CLIENT_ID>`. The Container Apps identity endpoint variables `IDENTITY_ENDPOINT` and `IDENTITY_HEADER` must also be present. The image requests an Azure DevOps resource token directly from that endpoint at registration and obtains a fresh token again before removal. It does not use Azure CLI, a PAT, client secret, or certificate for this mode. Azure DevOps documents OAuth 2.0 tokens as valid values for the agent's `--token` input; the `pat` auth label is the agent's configuration interface, not a claim that the token is a PAT. See Microsoft's [agent configuration documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/v2-windows), [Entra token guidance](https://learn.microsoft.com/en-us/azure/devops/cli/entra-tokens?view=azure-devops), and [Container Apps managed identity endpoint reference](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity).

For a host that can acquire an Azure DevOps Entra token but must not expose its identity endpoint inside the container, `AZP_AUTH=hosttoken` reads exactly one token line from stdin. The token is used only by `config.sh configure`; the container does not remove the pool registration after its one job. A trusted host supervisor may provide `AZP_EXPECTED_AGENT_ID` as a non-secret numeric runtime value. Hosttoken configuration uses `config.sh --replace`, then verifies the ID saved in the container-local `.agent` file before starting the listener. This lets a supervisor retain one stable pool registration while replacing the container and its private agent key after every job. The supervisor must prevent concurrent containers and verify the existing agent is offline and unassigned before replacement. Do not put the registration token in an environment variable, Compose file, command argument, or pipeline variable. This mode is intended for an external trusted supervisor and is not used by Azure Container Apps Jobs.

The former service-principal environment variables (`AZP_CLIENTID`, `AZP_CLIENTSECRET`, `AZP_TENANTID`) remain supported when `AZP_AUTH` is omitted, for compatibility with existing deployments. Explicit `AZP_AUTH=pat` selects PAT mode.

### Azure resource access from pipeline jobs

Use Azure DevOps service connections with workload identity federation for Azure deployments where supported. The registration service principal exists to register and clean up the ephemeral agent; do not reuse it as a general Azure deployment identity unless that is an explicit requirement and its permissions have been deliberately scoped.

## Azure Container Apps Jobs runtime

Configure these environment variables for each job execution:

| Variable | Required | Description |
| --- | --- | --- |
| `AZP_URL` | Yes | Azure DevOps organization URL, such as `https://dev.azure.com/example` |
| `AZP_POOL` | Yes | Target agent pool name |
| `AZP_AUTH` | No | `pat` (default), `managedidentity`, or `hosttoken` |
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
  --build-arg TERRAFORM_VERSION=1.17.1 \
  --build-arg PACKER_VERSION=1.16.2 \
  --build-arg AZURE_CLI_VERSION=2.92.0 \
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

1. The non-root container starts and gets an Azure DevOps registration token. The pinned agent package is already installed in the image, so startup does not download it.
2. The preinstalled agent is registered for one job. The Oracle hosttoken supervisor uses `config.sh --replace` for its stable pool registration and checks the expected ID before starting; PAT and Managed Identity modes retain their existing registration behavior.
3. `run.sh --once` accepts exactly one pipeline job, then exits.
4. The hosttoken registration is retained for the next Oracle container. PAT and Managed Identity routes remove their registration, including when the container receives `SIGTERM` or `SIGINT`.
5. The container exits with the agent process status; startup and job failures return non-zero.

## Limitations

- Linux amd64 and arm64 are supported. PowerShell, Terraform, and Packer are installed for both architectures.
- No Docker daemon is included. Pipelines that need local Docker require another agent setup.
- Only the preinstalled tools and modules are guaranteed to be available.

## Making the package public

After the first push, make the package public from its GitHub Package Settings page if public access is desired.
