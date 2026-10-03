FROM ubuntu:24.04

ARG TARGETARCH
ARG TARGETPLATFORM
ARG POWERSHELL_VERSION=7.6.6
ARG POWERSHELL_SHA256_AMD64=9585F38AB5A026C3FC0995486E26E12050777960FEF47A22DCA98B577C5D27A7
ARG POWERSHELL_TARBALL_SHA256_ARM64=924829e54c983648f6f1419a2dc7f9433c861b2fb5bd57736ff096c24f133729
ARG TERRAFORM_VERSION=1.16.5
ARG PACKER_VERSION=1.16.1
ARG AZP_AGENT_VERSION=5.279.0
ARG IMAGE_SOURCE=https://github.com

LABEL org.opencontainers.image.title="Azure DevOps ephemeral agent" \
      org.opencontainers.image.description="Multi-architecture Azure DevOps agent image for Azure Container Apps Jobs" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
ENV AGENT_ALLOW_RUNASROOT=1
ENV AZP_WORK=/azp/_work
ENV AZP_AGENT_VERSION=${AZP_AGENT_VERSION}
ENV TARGETARCH=${TARGETARCH}
ENV POWERSHELL_TELEMETRY_OPTOUT=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    case "$TARGETARCH" in \
        amd64) deb_arch=amd64 ;; \
        arm64) deb_arch=arm64 ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    case "$TARGETPLATFORM" in linux/amd64|linux/arm64) ;; *) echo "Unsupported TARGETPLATFORM: $TARGETPLATFORM" >&2; exit 1 ;; esac; \
    test "$(dpkg --print-architecture)" = "$deb_arch"; \
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
        procps \
        rsync \
        tar \
        unzip \
        util-linux \
        zip; \
    if [[ "$TARGETARCH" == amd64 ]]; then \
        powershell_package="powershell_${POWERSHELL_VERSION}-1.deb_amd64.deb"; \
        curl --fail --silent --show-error --location \
            --output "/tmp/${powershell_package}" \
            "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${powershell_package}"; \
        echo "${POWERSHELL_SHA256_AMD64}  /tmp/${powershell_package}" | sha256sum --check --strict -; \
        apt-get install -y --no-install-recommends "/tmp/${powershell_package}"; \
        rm -f "/tmp/${powershell_package}"; \
    else \
        apt-get install -y --no-install-recommends libicu74; \
        powershell_archive="powershell-${POWERSHELL_VERSION}-linux-arm64.tar.gz"; \
        curl --fail --silent --show-error --location \
            --output "/tmp/${powershell_archive}" \
            "https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/${powershell_archive}"; \
        echo "${POWERSHELL_TARBALL_SHA256_ARM64}  /tmp/${powershell_archive}" | sha256sum --check --strict -; \
        install -d -m 0755 /opt/microsoft/powershell/7; \
        tar -xzf "/tmp/${powershell_archive}" -C /opt/microsoft/powershell/7; \
        chmod +x /opt/microsoft/powershell/7/pwsh; \
        ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh; \
        rm -f "/tmp/${powershell_archive}"; \
    fi; \
    pwsh --version; \
    EXPECTED_POWERSHELL_VERSION="$POWERSHELL_VERSION" pwsh -NoLogo -NoProfile -Command \
        'if ($PSVersionTable.PSVersion.ToString() -ne $env:EXPECTED_POWERSHELL_VERSION) { throw "Unexpected PowerShell version" }'; \
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
    az extension add --name containerapp --yes --allow-preview true; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    for tool in terraform packer; do \
        case "$tool" in \
            terraform) version="$TERRAFORM_VERSION" ;; \
            packer) version="$PACKER_VERSION" ;; \
    esac; \
        case "$TARGETARCH" in amd64) hashicorp_arch=amd64 ;; arm64) hashicorp_arch=arm64 ;; esac; \
        archive="${tool}_${version}_linux_${hashicorp_arch}.zip"; \
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
    case "$TARGETARCH" in \
        amd64) agent_arch=x64; agent_sha256=6e3352e1dc44c924cd85840df279f21c200e6365596a7c38f3087015262555dc ;; \
        arm64) agent_arch=arm64; agent_sha256=d97cb1286de41c97347a5da4f663daed70f65f9cdd4322f50f8cc7b4e2df9dd4 ;; \
        *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    agent_archive="vsts-agent-linux-${agent_arch}-${AZP_AGENT_VERSION}.tar.gz"; \
    curl --fail --silent --show-error --location \
        --output "/tmp/${agent_archive}" \
        "https://download.agent.dev.azure.com/agent/${AZP_AGENT_VERSION}/${agent_archive}"; \
    echo "${agent_sha256}  /tmp/${agent_archive}" | sha256sum --check --strict -; \
    install -d -m 0755 /azp/agent; \
    tar -xzf "/tmp/${agent_archive}" -C /azp/agent; \
    rm -f "/tmp/${agent_archive}"; \
    /azp/agent/bin/installdependencies.sh; \
    chmod +x /azp/agent/config.sh /azp/agent/run.sh; \
    installed_agent_version="$(/azp/agent/bin/Agent.Listener --version)"; \
    test "$installed_agent_version" = "$AZP_AGENT_VERSION"

RUN set -eux; \
    pwsh -NoLogo -NoProfile -Command \
      'Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name Az.Accounts,Az.Resources,Az.Storage,Az.Compute,Az.Network,Az.ManagedServiceIdentity,Az.DesktopVirtualization -Scope AllUsers -Force -AllowClobber'

WORKDIR /azp
COPY scripts/start-agent.sh scripts/verify-tools.ps1 /azp/

RUN set -eux; \
    chmod +x /azp/start-agent.sh; \
    pwsh -NoLogo -NoProfile -File /azp/verify-tools.ps1

ENTRYPOINT ["/azp/start-agent.sh"]
