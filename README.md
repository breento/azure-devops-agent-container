# Azure DevOps Ephemeral Agent

## Purpose

This Linux AMD64 image runs a temporary Azure DevOps self-hosted agent in an Azure Container Apps Job. Each container execution downloads and registers the current Linux x64 agent, accepts one pipeline job with `run.sh --once`, removes its registration, and exits. The startup flow follows Microsoft's documented [Docker agent pattern](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/docker?view=azure-devops).

## Included tools

- Ubuntu 24.04
- PowerShell 7.6.6, installed with SHA256 verification
- Azure CLI with the `azure-devops` and `containerapp` extensions
- Terraform 1.16.5 and Packer 1.16.1
- Git, curl, jq, unzip, zip, OpenSSH client, rsync, and CA certificates
- PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Compute`, `Az.Network`, `Az.ManagedServiceIdentity`, and `Az.DesktopVirtualization`

PowerShell, Terraform, and Packer versions are pinned in the Dockerfile and build workflow. Azure CLI comes from Microsoft's Ubuntu repository; the two CLI extensions are installed explicitly during the image build, including preview support for `containerapp`. Tool verification runs during image build.

## Image location and tags

GitHub Actions publishes to `ghcr.io/<owner>/azure-devops-agent`. Main branch builds publish `latest`, a date/run-number tag, and a commit-based `sha-<commit>` convenience tag. The SHA tag can be republished by the monthly rebuild, so it does not guarantee an immutable image. Builds also publish an SBOM and BuildKit provenance attestations. Pull requests build without pushing. A monthly scheduled build refreshes Ubuntu security updates and upstream packages.

For Azure Container Apps deployments, pin the image by digest for true immutability. The `sha-<commit>` tag is useful for identifying source but can move when that commit is rebuilt. Use `latest` for convenience in development only.

## Authentication

There are two separate authentication concerns.

### Azure DevOps agent registration and runtime

Production uses a dedicated Entra service principal for agent registration. This implementation follows Microsoft's [Docker-agent pattern](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/docker?view=azure-devops): it logs in to Azure CLI with the service principal, acquires an Azure DevOps access token, then configures and removes the agent with that token using PAT-style `config.sh --auth PAT` arguments. The token is not a PAT even though the agent configuration mode is named PAT. Microsoft also documents a separate native [service-principal registration mode](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/service-principal-agent-registration?view=azure-devops), using `config.sh --auth SP` and client ID, tenant ID, and secret arguments. This image does not use that native mode.

At startup, the image uses Azure CLI in a temporary, private `AZURE_CONFIG_DIR` to acquire the Azure DevOps access token. It removes the CLI cache immediately afterward. The token is held only in the startup shell's unexported variable while needed for setup and cleanup. `AZP_CLIENTSECRET` is also unexported before child processes start and excluded from the agent's inherited environment.

An optional `AZP_TOKEN` PAT fallback is retained for local development and tests. The service principal is preferred whenever any `AZP_CLIENTID`, `AZP_CLIENTSECRET`, or `AZP_TENANTID` value is supplied; all three are then required, and the PAT is ignored. A PAT requires the Agent Pools read/manage permission. Do not use a PAT as the production default.

### Azure resource access from pipeline jobs

Use Azure DevOps service connections with workload identity federation for Azure deployments where supported. The registration service principal exists to register and clean up the ephemeral agent; do not reuse it as a general Azure deployment identity unless that is an explicit requirement and its permissions have been deliberately scoped.

## Azure Container Apps Jobs runtime

Configure these environment variables for each job execution:

| Variable | Required | Description |
| --- | --- | --- |
| `AZP_URL` | Yes | Azure DevOps organization URL, such as `https://dev.azure.com/example` |
| `AZP_POOL` | Yes | Target agent pool name |
| `AZP_CLIENTID` | Yes for production | Entra service principal client/application ID |
| `AZP_CLIENTSECRET` | Yes for production | Service principal secret; reference an Azure Container Apps secret and never embed it in the image |
| `AZP_TENANTID` | Yes for production | Entra tenant ID |
| `AZP_AGENT_NAME` | No | Agent name; defaults to a unique name for each container execution |
| `AZP_WORK` | No | Agent work directory; defaults to `/azp/_work` |

Supply `AZP_CLIENTSECRET` using an Azure Container Apps secret reference. Configure the service principal in Azure DevOps with the required agent pool access before starting jobs. The image itself creates no Azure resources and includes no KEDA or Container Apps deployment configuration.

For local-only PAT fallback testing, provide `AZP_TOKEN` instead of the service principal variables.

## Local build

```bash
docker build \
  --build-arg POWERSHELL_VERSION=7.6.6 \
  --build-arg POWERSHELL_SHA256=9585F38AB5A026C3FC0995486E26E12050777960FEF47A22DCA98B577C5D27A7 \
  --build-arg TERRAFORM_VERSION=1.16.5 \
  --build-arg PACKER_VERSION=1.16.1 \
  -t azure-devops-agent:local .
```

Run tool validation without registering an agent:

```bash
docker run --rm \
  --entrypoint pwsh \
  azure-devops-agent:local \
  -NoLogo -NoProfile -File /azp/verify-tools.ps1
```

## One-job lifecycle

1. The container starts and gets an Azure DevOps registration token.
2. The current agent package is downloaded and registered under a unique name.
3. `run.sh --once` accepts exactly one pipeline job, then exits.
4. The registration is removed, including when the container receives `SIGTERM` or `SIGINT`.
5. The container exits with the agent process status; startup and job failures return non-zero.

## Limitations

- Linux AMD64 only.
- No Docker daemon is included. Pipelines that need local Docker require another agent setup.
- Only the preinstalled tools and modules are guaranteed to be available.

## Making the package public

After the first push, make the package public from its GitHub Package Settings page if public access is desired.
