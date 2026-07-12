#!/usr/bin/env bash
set -Eeuo pipefail

readonly agent_root="/azp/agent"
agent_configured=false
agent_archive=""

require_environment() {
    local name
    for name in AZP_URL AZP_POOL AZP_TOKEN; do
        if [[ -z "${!name:-}" ]]; then
            printf 'Required environment variable %s is not set.\n' "$name" >&2
            exit 1
        fi
    done
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if [[ "$agent_configured" == true && -x "$agent_root/config.sh" ]]; then
        printf 'Removing Azure DevOps agent registration.\n' >&2
        (
            cd "$agent_root"
            ./config.sh remove --unattended --auth PAT --token "$AZP_TOKEN" || true
        )
    fi

    rm -f "${agent_archive:-}" || true

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_environment

AZP_URL="${AZP_URL%/}"
AZP_AGENT_NAME="${AZP_AGENT_NAME:-aca-agent-$(hostname)}"
AZP_WORK="${AZP_WORK:-/azp/_work}"

mkdir -p "$AZP_WORK"
rm -rf "$agent_root"
mkdir -p "$agent_root"

printf 'Retrieving the latest Azure DevOps Linux x64 agent package.\n'
package_response="$(curl --fail --silent --show-error \
    --user ":${AZP_TOKEN}" \
    --header 'Accept: application/json' \
    "${AZP_URL}/_apis/distributedtask/packages/agent?platform=linux-x64&top=1")"

if ! jq -e . >/dev/null 2>&1 <<<"$package_response"; then
    printf 'Azure DevOps agent package API returned invalid JSON.\n' >&2
    exit 1
fi

download_url="$(jq -er 'if type == "array" then .[0].downloadUrl else .value[0].downloadUrl end' <<<"$package_response")" || {
    printf 'Azure DevOps agent package API did not return a downloadUrl.\n' >&2
    exit 1
}

if [[ -z "$download_url" ]]; then
    printf 'Azure DevOps agent package API returned an empty downloadUrl.\n' >&2
    exit 1
fi

agent_archive="$(mktemp /tmp/azure-pipelines-agent.XXXXXX.tar.gz)"

printf 'Downloading Azure DevOps agent package.\n'
curl --fail --silent --show-error --location --output "$agent_archive" "$download_url"

if ! tar -xzf "$agent_archive" -C "$agent_root"; then
    rm -f "$agent_archive"
    printf 'Unable to unpack the Azure DevOps agent archive.\n' >&2
    exit 1
fi
rm -f "$agent_archive"

cd "$agent_root"
./config.sh \
    --unattended \
    --acceptTeeEula \
    --url "$AZP_URL" \
    --auth PAT \
    --token "$AZP_TOKEN" \
    --pool "$AZP_POOL" \
    --agent "$AZP_AGENT_NAME" \
    --work "$AZP_WORK" \
    --replace
agent_configured=true

printf 'Running one Azure DevOps pipeline job.\n'
./run.sh --once
