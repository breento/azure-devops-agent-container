#!/usr/bin/env bash
set -Eeuo pipefail

readonly agent_root="/azp/agent"
agent_configured=false
agent_pid=""
agent_pgid=""
auth_mode=""
registration_token=""

# Keep the secret available to this shell for Azure CLI, but never pass it in
# the environment inherited by the agent or pipeline job processes.
export -n AZP_CLIENTSECRET 2>/dev/null || true

require_environment() {
    local name
    for name in AZP_URL AZP_POOL; do
        if [[ -z "${!name:-}" ]]; then
            printf 'Required environment variable %s is not set.\n' "$name" >&2
            exit 1
        fi
    done

    if [[ -n "${AZP_CLIENTID:-}" || -n "${AZP_CLIENTSECRET:-}" || -n "${AZP_TENANTID:-}" ]]; then
        for name in AZP_CLIENTID AZP_CLIENTSECRET AZP_TENANTID; do
            if [[ -z "${!name:-}" ]]; then
                printf 'Service principal authentication requires %s.\n' "$name" >&2
                exit 1
            fi
        done
        auth_mode="service-principal"
    elif [[ -n "${AZP_TOKEN:-}" ]]; then
        auth_mode="pat"
    else
        printf 'Set AZP_CLIENTID, AZP_CLIENTSECRET, and AZP_TENANTID, or set AZP_TOKEN for the optional PAT fallback.\n' >&2
        exit 1
    fi
}

get_azp_token() {
    if [[ "$auth_mode" == "pat" ]]; then
        printf '%s' "$AZP_TOKEN"
        return
    fi

    local config_dir
    config_dir="$(mktemp -d /tmp/azure-cli.XXXXXX)"
    chmod 700 "$config_dir"
    (
        export AZURE_CONFIG_DIR="$config_dir"
        trap 'az logout --username "$AZP_CLIENTID" >/dev/null 2>&1 || true; az account clear >/dev/null 2>&1 || true; rm -rf "$AZURE_CONFIG_DIR"' EXIT
        az login --allow-no-subscriptions --service-principal \
            --username "$AZP_CLIENTID" \
            --password "$AZP_CLIENTSECRET" \
            --tenant "$AZP_TENANTID" >/dev/null
        az account get-access-token --query accessToken --output tsv
    )
}

acquire_registration_token() {
    local token
    if ! token="$(get_azp_token)" || [[ -z "$token" ]]; then
        printf 'Unable to acquire an Azure DevOps registration token.\n' >&2
        return 1
    fi
    registration_token="$token"
    unset token
    unset AZP_TOKEN
}

cleanup() {
    local status=$?
    local cleanup_failed=false
    trap - EXIT INT TERM

    if agent_group_is_running; then
        printf 'Stopping remaining Azure Pipelines agent/job processes.\n' >&2
        stop_agent_process_group TERM
    fi

    if [[ "$agent_configured" == true && -x "$agent_root/config.sh" ]]; then
        printf 'Removing Azure DevOps agent registration.\n' >&2
        if [[ "$auth_mode" == "service-principal" ]]; then
            if ! acquire_registration_token; then
                printf 'Could not refresh the registration token; attempting cleanup with the existing token.\n' >&2
            fi
        fi

        local attempt
        for attempt in {1..4}; do
            if (cd "$agent_root" && timeout --signal=TERM --kill-after=1s 4s ./config.sh remove --unattended --auth PAT --token "$registration_token"); then
                printf 'Azure DevOps agent registration removed.\n' >&2
                break
            fi
            if [[ "$attempt" -lt 4 ]]; then
                printf 'Agent deregistration attempt %s/4 failed; retrying in 2 seconds.\n' "$attempt" >&2
                sleep 2
            else
                printf 'ERROR: unable to remove the Azure DevOps agent registration after 4 attempts.\n' >&2
                cleanup_failed=true
            fi
        done
    fi

    unset registration_token AZP_CLIENTSECRET
    if [[ "$status" -eq 0 && "$cleanup_failed" == true ]]; then
        status=1
    fi
    exit "$status"
}

agent_group_is_running() {
    [[ -n "$agent_pgid" ]] || return 1
    ps -eo pgid=,stat= | awk -v pgid="$agent_pgid" '$1 == pgid && $2 !~ /^Z/ { found = 1 } END { exit !found }'
}

stop_agent_process_group() {
    local signal="$1"
    local deadline=$((SECONDS + 5))

    if ! agent_group_is_running; then
        if [[ -n "$agent_pid" ]]; then
            wait "$agent_pid" 2>/dev/null || true
            agent_pid=""
        fi
        return 0
    fi

    printf 'Forwarding %s to the Azure Pipelines agent/job process group.\n' "$signal" >&2
    kill -s "$signal" -- "-$agent_pgid" 2>/dev/null || true
    while agent_group_is_running && (( SECONDS < deadline )); do
        sleep 1
    done

    if agent_group_is_running; then
        printf 'Agent/job process group did not stop within 5 seconds; sending KILL.\n' >&2
        kill -KILL -- "-$agent_pgid" 2>/dev/null || true
    fi

    if [[ -n "$agent_pid" ]]; then
        wait "$agent_pid" 2>/dev/null || true
        agent_pid=""
    fi

    deadline=$((SECONDS + 3))
    while agent_group_is_running && (( SECONDS < deadline )); do
        sleep 1
    done
    if agent_group_is_running; then
        printf 'Warning: agent/job process group still exists after signal escalation.\n' >&2
    fi
}

handle_signal() {
    local status="$1"
    stop_agent_process_group "$2"
    exit "$status"
}

trap cleanup EXIT
trap 'handle_signal 130 INT' INT
trap 'handle_signal 143 TERM' TERM

require_environment

AZP_URL="${AZP_URL%/}"
AZP_AGENT_NAME="${AZP_AGENT_NAME:-aca-agent-$(hostname)-$(cat /proc/sys/kernel/random/uuid | cut -c1-8)}"
AZP_WORK="${AZP_WORK:-/azp/_work}"
export AZP_URL AZP_POOL AZP_AGENT_NAME AZP_WORK
export VSO_AGENT_IGNORE="AZP_TOKEN,AZP_CLIENTSECRET"

acquire_registration_token
unset AZP_TOKEN

if [[ ! -x "$agent_root/config.sh" || ! -x "$agent_root/run.sh" ]]; then
    printf 'Preinstalled Azure DevOps agent is missing from %s.\n' "$agent_root" >&2
    exit 1
fi
mkdir -p "$AZP_WORK"
printf 'Using preinstalled Azure DevOps agent version %s.\n' "${AZP_AGENT_VERSION:-unknown}"

cd "$agent_root"
agent_configured=true
./config.sh \
    --unattended \
    --acceptTeeEula \
    --url "$AZP_URL" \
    --auth PAT \
    --token "$registration_token" \
    --pool "$AZP_POOL" \
    --agent "$AZP_AGENT_NAME" \
    --work "$AZP_WORK" \
    --replace
printf 'Running one Azure DevOps pipeline job.\n'
setsid ./run.sh --once &
agent_pid=$!
agent_pgid="$agent_pid"
if wait "$agent_pid"; then
    job_status=0
else
    job_status=$?
fi
agent_pid=""
exit "$job_status"
