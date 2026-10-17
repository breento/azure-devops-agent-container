#!/usr/bin/env bash
set -Eeuo pipefail

readonly agent_root="/azp/agent"
agent_configured=false
agent_pid=""
agent_pgid=""
auth_mode=""
registration_token=""
cleanup_started=false
readonly ado_resource="499b84ac-1321-427f-aa17-267ca6975798"

# Keep the secret available to this shell for Azure CLI, but never pass it in
# the environment inherited by the agent or pipeline job processes.
export -n AZP_CLIENTSECRET 2>/dev/null || true

require_environment() {
    local name requested_auth
    for name in AZP_URL AZP_POOL; do
        if [[ -z "${!name:-}" ]]; then
            printf 'Required environment variable %s is not set.\n' "$name" >&2
            exit 1
        fi
    done

    requested_auth="${AZP_AUTH:-}"
    case "$requested_auth" in
        ""|pat|managedidentity) ;;
        *) printf 'Unsupported AZP_AUTH value. Use pat or managedidentity.\n' >&2; exit 1 ;;
    esac

    if [[ "$requested_auth" == managedidentity ]]; then
        auth_mode="managedidentity"
        for name in IDENTITY_ENDPOINT IDENTITY_HEADER AZP_MANAGED_IDENTITY_CLIENT_ID; do
            if [[ -z "${!name:-}" ]]; then
                printf 'Managed Identity authentication requires %s.\n' "$name" >&2
                exit 1
            fi
        done
        if [[ ! "$AZP_MANAGED_IDENTITY_CLIENT_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
            printf 'AZP_MANAGED_IDENTITY_CLIENT_ID must be a valid GUID.\n' >&2
            exit 1
        fi
        unset AZP_TOKEN
        return
    fi

    # Preserve the pre-AZP_AUTH service-principal configuration for deployed jobs.
    if [[ "$requested_auth" != pat && ( -n "${AZP_CLIENTID:-}" || -n "${AZP_CLIENTSECRET:-}" || -n "${AZP_TENANTID:-}" ) ]]; then
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
        printf 'Set AZP_TOKEN for PAT authentication.\n' >&2
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

get_managed_identity_token() {
    local response token attempt
    for attempt in {1..4}; do
        # The identity header is sent via curl's stdin config, not argv or logs.
        if response="$(printf 'header = "X-IDENTITY-HEADER: %s"\n' "$IDENTITY_HEADER" | curl --config - --fail --silent --show-error --get \
            --data-urlencode 'api-version=2019-08-01' \
            --data-urlencode "resource=$ado_resource" \
            --data-urlencode "client_id=$AZP_MANAGED_IDENTITY_CLIENT_ID" \
            "$IDENTITY_ENDPOINT" 2>/dev/null)"; then
            token="$(jq -er '.access_token | select(type == "string" and length > 0)' <<<"$response" 2>/dev/null || true)"
            unset response
            if [[ -n "$token" ]]; then printf '%s' "$token"; unset token; return 0; fi
        fi
        unset response token
        if [[ "$attempt" -lt 4 ]]; then sleep "$attempt"; fi
    done
    printf 'Unable to acquire a Microsoft Entra token from the Managed Identity endpoint after 4 attempts. Check identity attachment and endpoint availability.\n' >&2
    return 1
}

acquire_registration_token() {
    local token
    if [[ "$auth_mode" == managedidentity ]]; then
        if ! token="$(get_managed_identity_token)" || [[ -z "$token" ]]; then
            return 1
        fi
    elif ! token="$(get_azp_token)" || [[ -z "$token" ]]; then
        printf 'Unable to acquire an Azure DevOps registration token.\n' >&2
        return 1
    fi
    registration_token="$token"
    unset token
    unset AZP_TOKEN
}

run_config_with_token() {
    local operation="$1"
    export VSTS_AGENT_INPUT_TOKEN="$registration_token"
    if [[ "$operation" == configure ]]; then
        (cd "$agent_root" && ./config.sh --unattended --acceptTeeEula --url "$AZP_URL" --auth PAT --pool "$AZP_POOL" --agent "$AZP_AGENT_NAME" --work "$AZP_WORK" --replace)
    else
        (cd "$agent_root" && timeout --signal=TERM --kill-after=1s 4s ./config.sh remove --unattended --auth PAT)
    fi
    local result=$?
    unset VSTS_AGENT_INPUT_TOKEN
    return "$result"
}

cleanup() {
    local status=$?
    local cleanup_failed=false
    trap - EXIT INT TERM

    if agent_group_is_running; then
        printf 'Stopping remaining Azure Pipelines agent/job processes.\n' >&2
        stop_agent_process_group TERM
    fi

    if [[ "$agent_configured" == true && "$cleanup_started" == false && -x "$agent_root/config.sh" ]]; then
        cleanup_started=true
        printf 'Removing Azure DevOps agent registration.\n' >&2
        if [[ "$auth_mode" == managedidentity ]]; then
            registration_token=""
            if ! acquire_registration_token; then
                printf 'ERROR: could not obtain a fresh authentication token; agent cleanup cannot be confirmed.\n' >&2
                cleanup_failed=true
            fi
        elif [[ "$auth_mode" == "service-principal" ]]; then
            if ! acquire_registration_token; then
                printf 'Could not refresh the registration token; attempting cleanup with the existing token.\n' >&2
            fi
        fi

        local attempt
        for attempt in {1..4}; do
            if [[ -n "$registration_token" ]] && run_config_with_token remove; then
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

if ! acquire_registration_token; then
    printf 'Unable to obtain an Azure DevOps registration token.\n' >&2
    exit 1
fi
unset AZP_TOKEN

if [[ ! -x "$agent_root/config.sh" || ! -x "$agent_root/run.sh" ]]; then
    printf 'Preinstalled Azure DevOps agent is missing from %s.\n' "$agent_root" >&2
    exit 1
fi
mkdir -p "$AZP_WORK"
printf 'Using preinstalled Azure DevOps agent version %s.\n' "${AZP_AGENT_VERSION:-unknown}"

cd "$agent_root"
agent_configured=true
if ! run_config_with_token configure; then
    printf 'Azure DevOps agent registration failed.\n' >&2
    exit 1
fi
if [[ "$auth_mode" == managedidentity ]]; then unset registration_token; fi
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
