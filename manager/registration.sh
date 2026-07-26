#!/bin/sh

github_runner_endpoint() {
    scope="$1"
    repository="$2"
    organization="$3"
    enterprise="$4"

    case "${scope}" in
        repo)
            repository_path=${repository#https://github.com/}
            owner=${repository_path%%/*}
            name=${repository_path#*/}
            if [ -z "${owner}" ] ||
                [ -z "${name}" ] ||
                [ "${name}" = "${repository_path}" ] ||
                printf '%s' "${name}" | grep -q '/'; then
                return 1
            fi
            printf '/repos/%s/%s/actions/runners' "${owner}" "${name}"
            ;;
        org)
            [ -n "${organization}" ] || return 1
            printf '/orgs/%s/actions/runners' "${organization}"
            ;;
        ent)
            [ -n "${enterprise}" ] || return 1
            printf '/enterprises/%s/actions/runners' "${enterprise}"
            ;;
        *)
            return 1
            ;;
    esac
}

fetch_github_runner_inventory() {
    output_path="$1"
    endpoint="$2"
    access_token="$3"
    response_timeout="${4:-5}"
    [ -n "${access_token}" ] || return 1

    records_path="${output_path}.records"
    response_path="${output_path}.response"
    temporary_path="${output_path}.tmp"
    : > "${records_path}"
    page=1
    expected_total=""
    fetched_count=0
    while [ "${page}" -le 20 ]; do
        if ! wget \
            -q \
            -T "${response_timeout}" \
            -O "${response_path}" \
            --header "Authorization: Bearer ${access_token}" \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com${endpoint}?per_page=100&page=${page}"; then
            rm -f "${records_path}" "${response_path}" "${temporary_path}"
            return 1
        fi
        if ! jq -e '
            type == "object"
            and (.total_count | type == "number" and . >= 0 and floor == .)
            and (.runners | type == "array")
            and all(.runners[];
                (.name | type == "string" and length > 0)
                and (.status == "online" or .status == "offline")
                and (.busy | type == "boolean"))
        ' "${response_path}" >/dev/null 2>&1; then
            rm -f "${records_path}" "${response_path}" "${temporary_path}"
            return 1
        fi
        response_total=$(jq -r '.total_count' "${response_path}")
        if [ -z "${expected_total}" ]; then
            expected_total="${response_total}"
        elif [ "${response_total}" != "${expected_total}" ]; then
            rm -f "${records_path}" "${response_path}" "${temporary_path}"
            return 1
        fi
        jq -c '.runners[] | {name, status, busy}' \
            "${response_path}" >> "${records_path}" || {
                rm -f "${records_path}" "${response_path}" "${temporary_path}"
                return 1
            }
        page_count=$(jq -r '.runners | length' "${response_path}")
        fetched_count=$((fetched_count + page_count))
        if [ "${fetched_count}" -eq "${expected_total}" ]; then
            break
        fi
        if [ "${fetched_count}" -gt "${expected_total}" ] ||
            [ "${page_count}" -lt 100 ]; then
            rm -f "${records_path}" "${response_path}" "${temporary_path}"
            return 1
        fi
        page=$((page + 1))
    done
    rm -f "${response_path}"
    if [ "${fetched_count}" -ne "${expected_total}" ] ||
        ! jq -s \
            --argjson totalCount "${expected_total}" \
            '
                . as $runners
                | if ($runners | length) == $totalCount
                    and ([$runners[].name] | unique | length) == ($runners | length)
                  then {
                    totalCount: $totalCount,
                    runners: $runners
                  }
                  else error("GitHub runner inventory was incomplete or ambiguous")
                  end
            ' "${records_path}" > "${temporary_path}"; then
        rm -f "${records_path}" "${temporary_path}"
        return 1
    fi
    rm -f "${records_path}"
    mv -f "${temporary_path}" "${output_path}"
}

classify_github_runner_registration() {
    inventory_path="$1"
    runner_name="$2"
    [ -n "${runner_name}" ] || {
        printf 'unknown\tunknown\t0\n'
        return
    }
    if ! jq -e '
        type == "object"
        and (.totalCount | type == "number" and . >= 0 and floor == .)
        and (.runners | type == "array")
        and (.totalCount == (.runners | length))
        and (([.runners[].name] | unique | length) == (.runners | length))
        and all(.runners[];
            (.name | type == "string" and length > 0)
            and (.status == "online" or .status == "offline")
            and (.busy | type == "boolean"))
    ' "${inventory_path}" >/dev/null 2>&1; then
        printf 'unknown\tunknown\t0\n'
        return
    fi

    matches=$(jq -r \
        --arg runnerName "${runner_name}" \
        '[.runners[] | select(.name == $runnerName)] | length' \
        "${inventory_path}" 2>/dev/null) || {
            printf 'unknown\tunknown\t0\n'
            return
        }
    case "${matches}" in
        0)
            printf 'registration-missing\tunknown\t1\n'
            return
            ;;
        1) ;;
        *)
            printf 'unknown\tunknown\t0\n'
            return
            ;;
    esac

    status=$(jq -r \
        --arg runnerName "${runner_name}" \
        '.runners[] | select(.name == $runnerName) | .status' \
        "${inventory_path}")
    busy=$(jq -r \
        --arg runnerName "${runner_name}" \
        '.runners[] | select(.name == $runnerName) | .busy' \
        "${inventory_path}")
    if [ "${status}" = "online" ]; then
        if [ "${busy}" = "true" ]; then
            printf 'connected\tbusy\t0\n'
        else
            printf 'connected\tidle\t0\n'
        fi
    elif [ "${busy}" = "true" ]; then
        printf 'disconnected\tbusy\t0\n'
    else
        printf 'disconnected\tunknown\t1\n'
    fi
}

registration_evidence_count() {
    slot_path="$1"
    status="$2"
    cleanup_candidate="$3"
    [ "${cleanup_candidate}" = "1" ] || {
        printf '0'
        return
    }
    previous_status=""
    previous_count=0
    registration_path="${slot_path}/registration-state.json"
    if [ -f "${registration_path}" ]; then
        previous_status=$(jq -r '.status // ""' "${registration_path}" 2>/dev/null || true)
        previous_count=$(jq -r '.cleanupEvidenceCount // 0' "${registration_path}" 2>/dev/null || echo 0)
    fi
    if [ "${previous_status}" = "${status}" ]; then
        printf '%s' "$((previous_count + 1))"
    else
        printf '1'
    fi
}

stop_confirmed_ghost() {
    slot_path="$1"
    runner_name="$2"
    profile_id="$3"
    managed_label_key="$4"
    slot_label_key="$5"
    stop_timeout="$6"
    cleanup_threshold="$7"
    slot_key=${slot_path##*/}
    [ ! -f "${slot_path}/drain" ] || return 0
    [ -f "${slot_path}/container-id" ] || return 0
    [ -f "${slot_path}/container-name" ] || return 0
    current_name=$(cat "${slot_path}/container-name")
    [ "${current_name}" = "${runner_name}" ] || {
        echo "[slot ${slot_key}] runner identity changed before cleanup; preserving container" >&2
        return 0
    }
    grace_until=0
    [ -f "${slot_path}/registration-grace-until" ] &&
        grace_until=$(cat "${slot_path}/registration-grace-until")
    case "${grace_until}" in
        ''|*[!0-9]*) grace_until=0 ;;
    esac
    [ "$(date +%s)" -ge "${grace_until}" ] || {
        echo "[slot ${slot_key}] runner grace period restarted before cleanup; preserving container" >&2
        return 0
    }
    container_id=$(cat "${slot_path}/container-id")
    [ -n "${container_id}" ] || return 0
    if ! docker inspect "${container_id}" |
        jq -e \
            --arg profile "${profile_id}" \
            --arg slot "${slot_key}" \
            --arg runnerName "/${runner_name}" \
            --arg managedLabel "${managed_label_key}" \
            --arg slotLabel "${slot_label_key}" \
            '
                length == 1
                and .[0].State.Running == true
                and .[0].Name == $runnerName
                and .[0].Config.Labels[$managedLabel] == $profile
                and .[0].Config.Labels[$slotLabel] == $slot
            ' >/dev/null 2>&1; then
        echo "[slot ${slot_key}] ghost evidence became stale before cleanup; preserving container" >&2
        return 0
    fi
    echo "[slot ${slot_key}] GitHub registration is unusable after ${cleanup_threshold} observations; replacing exact container ${container_id}"
    docker stop --time "${stop_timeout}" "${container_id}" >/dev/null 2>&1 || {
        echo "[slot ${slot_key}] could not stop confirmed ghost container ${container_id}" >&2
        return 1
    }
}

write_registration_observation() {
    slot_path="$1"
    dirty_path="$2"
    status="$3"
    activity="$4"
    evidence_count="$5"
    output_path="${slot_path}/registration-state.json"
    temporary_path="${output_path}.$$"
    previous_status=""
    previous_activity=""
    previous_count=""
    if [ -f "${output_path}" ]; then
        previous_status=$(jq -r '.status // ""' "${output_path}" 2>/dev/null || true)
        previous_activity=$(jq -r '.activity // ""' "${output_path}" 2>/dev/null || true)
        previous_count=$(jq -r '.cleanupEvidenceCount // ""' "${output_path}" 2>/dev/null || true)
    fi
    if ! jq -n \
        --arg status "${status}" \
        --arg activity "${activity}" \
        --arg observedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson cleanupEvidenceCount "${evidence_count}" \
        '{
            status: $status,
            activity: $activity,
            observedAt: $observedAt,
            cleanupEvidenceCount: $cleanupEvidenceCount
        }' > "${temporary_path}"; then
        rm -f "${temporary_path}"
        return 1
    fi
    if ! mv -f "${temporary_path}" "${output_path}"; then
        rm -f "${temporary_path}"
        return 1
    fi
    if [ "${status}" != "${previous_status}" ] ||
        [ "${activity}" != "${previous_activity}" ] ||
        [ "${evidence_count}" != "${previous_count}" ]; then
        : > "${dirty_path}"
    fi
}
