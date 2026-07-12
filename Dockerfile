FROM mcr.microsoft.com/powershell:7.5-ubuntu-24.04

ARG TERRAFORM_VERSION=1.12.2
ARG PACKER_VERSION=1.14.1
ARG IMAGE_SOURCE=https://github.com

LABEL org.opencontainers.image.title="Azure DevOps ephemeral agent" \
      org.opencontainers.image.description="Linux AMD64 Azure DevOps agent image for Azure Container Apps Jobs" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
ENV AGENT_ALLOW_RUNASROOT=1
ENV AZP_WORK=/azp/_work
ENV POWERSHELL_TELEMETRY_OPTOUT=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        lsb-release \
        openssh-client \
        rsync \
        tar \
        unzip \
        zip; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft-prod.gpg; \
    chmod a+r /etc/apt/keyrings/microsoft-prod.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main" > /etc/apt/sources.list.d/azure-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends azure-cli; \
    az extension add --name azure-devops; \
    az extension add --name containerapp; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    for tool in terraform packer; do \
        case "$tool" in \
            terraform) version="$TERRAFORM_VERSION" ;; \
            packer) version="$PACKER_VERSION" ;; \
        esac; \
        archive="${tool}_${version}_linux_amd64.zip"; \
        base_url="https://releases.hashicorp.com/${tool}/${version}"; \
        curl -fsSLO "${base_url}/${archive}"; \
        curl -fsSLO "${base_url}/${tool}_${version}_SHA256SUMS"; \
        grep " ${archive}$" "${tool}_${version}_SHA256SUMS" | sha256sum -c -; \
        unzip -q "$archive" -d /usr/local/bin; \
        rm -f "$archive" "${tool}_${version}_SHA256SUMS"; \
    done; \
    terraform version; \
    packer version

RUN set -eux; \
    pwsh -NoLogo -NoProfile -Command \
      'Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name Az.Accounts,Az.Resources,Az.Storage,Az.Compute,Az.Network,Az.ManagedServiceIdentity,Az.DesktopVirtualization -Scope AllUsers -Force -AllowClobber'

WORKDIR /azp
COPY scripts/start-agent.sh scripts/verify-tools.ps1 /azp/

RUN set -eux; \
    chmod +x /azp/start-agent.sh; \
    pwsh -NoLogo -NoProfile -File /azp/verify-tools.ps1

ENTRYPOINT ["/azp/start-agent.sh"]
