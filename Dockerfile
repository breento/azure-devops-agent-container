FROM ubuntu:24.04

ARG POWERSHELL_VERSION=7.6.3

ARG POWERSHELL_SHA256
ARG TERRAFORM_VERSION=1.15.8
ARG PACKER_VERSION=1.15.4
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
        apt-transport-https \
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
    test -n "$POWERSHELL_SHA256"; \
    powershell_package="powershell_${POWERSHELL_VERSION}-1.deb_amd64.deb"; \
    curl --fail --silent --show-error --location \
        --output "/tmp/${powershell_package}" \
        "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${powershell_package}"; \
    echo "${POWERSHELL_SHA256}  /tmp/${powershell_package}" | sha256sum --check --strict -; \
    apt-get install -y --no-install-recommends "/tmp/${powershell_package}"; \
    pwsh --version; \
    EXPECTED_POWERSHELL_VERSION="$POWERSHELL_VERSION" pwsh -NoLogo -NoProfile -Command \
        'if ($PSVersionTable.PSVersion.ToString() -ne $env:EXPECTED_POWERSHELL_VERSION) { throw "Unexpected PowerShell version" }'; \
    rm -f "/tmp/${powershell_package}"; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg; \
    chmod a+r /etc/apt/keyrings/microsoft.gpg; \
    AZ_DIST="$(lsb_release -cs)"; \
    AZ_ARCH="$(dpkg --print-architecture)"; \
    printf '%s\n' \
        'Types: deb' \
        'URIs: https://packages.microsoft.com/repos/azure-cli/' \
        "Suites: ${AZ_DIST}" \
        'Components: main' \
        "Architectures: ${AZ_ARCH}" \
        'Signed-by: /etc/apt/keyrings/microsoft.gpg' \
        > /etc/apt/sources.list.d/azure-cli.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends azure-cli; \
    az version; \
    az extension add --name azure-devops --yes; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    for tool in terraform packer; do \
        case "$tool" in \
            terraform) version="$TERRAFORM_VERSION" ;; \
            packer) version="$PACKER_VERSION" ;; \
    esac; \
        archive="${tool}_${version}_linux_amd64.zip"; \
        checksums="${tool}_${version}_SHA256SUMS"; \
        base_url="https://releases.hashicorp.com/${tool}/${version}"; \
        temp_dir="$(mktemp -d)"; \
        curl -fsSLO "${base_url}/${archive}"; \
        curl -fsSLO "${base_url}/${checksums}"; \
        grep " ${archive}$" "$checksums" | sha256sum -c -; \
        unzip -q "$archive" -d "$temp_dir"; \
        install -m 0755 "${temp_dir}/${tool}" "/usr/local/bin/${tool}"; \
        rm -rf "$temp_dir" "$archive" "$checksums"; \
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
