#!/bin/sh

reconcile_orphaned_host_admission_leases() {
    host_admission_enabled || return 0
    recovery_pending_path="${HOST_ADMISSION_RECOVERY_DIRECTORY}/pending.json"
    recovery_records_path="${HOST_ADMISSION_RECOVERY_DIRECTORY}/pending.tsv"
    recovery_labels_path="${HOST_ADMISSION_RECOVERY_DIRECTORY}/labels.json"
    recovery_inventory_directory="${HOST_ADMISSION_RECOVERY_DIRECTORY}/inventory"
    if ! rm -rf "${HOST_ADMISSION_RECOVERY_DIRECTORY}" ||
        ! mkdir -p "${recovery_inventory_directory}"; then
        return 1
    fi
    if ! host_admission_pending_lease_inventory "${recovery_pending_path}"; then
        recovery_state="status-unavailable"
        if [ "${recovery_state}" != "${HOST_ADMISSION_LAST_RECOVERY_STATE}" ]; then
            record_manager_diagnostic \
                recovery \
                manager-start \
                "" \
                blocked \
                "" \
                invalid-state \
                "Host admission lease recovery could not read pending adoption state"
            HOST_ADMISSION_LAST_RECOVERY_STATE="${recovery_state}"
        fi
        return 1
    fi
    recovery_pending_count=$(
        jq -er 'if type == "array" then length else error("invalid") end' \
            "${recovery_pending_path}"
    ) || return 1
    if [ "${recovery_pending_count}" -eq 0 ]; then
        HOST_ADMISSION_LAST_RECOVERY_STATE=""
        return 0
    fi
    printf '%s\n' "${LABELS}" |
        tr ',' '\n' |
        jq -R -s \
            'split("\n") | map(select(length > 0)) | unique' \
            > "${recovery_labels_path}"
    jq -r \
        '.[] | [.slotKey, (.registrationName // "")] | @tsv' \
        "${recovery_pending_path}" > "${recovery_records_path}"

    recovery_unresolved=0
    recovery_reconciled=0
    recovery_tab=$(printf '\t')
    while IFS="${recovery_tab}" read -r recovery_slot_key recovery_registration_name; do
        [ -n "${recovery_slot_key}" ] || continue
        recovery_desired_record=$(
            awk -F "${recovery_tab}" -v key="${recovery_slot_key}" '
                $1 == key { print $2 "\t" $3; exit }
            ' "${CURRENT_DESIRED_SLOTS}"
        )
        recovery_repo=""
        recovery_tag=""
        if [ -n "${recovery_desired_record}" ]; then
            recovery_repo=$(printf '%s\n' "${recovery_desired_record}" | cut -f1)
            recovery_tag=$(printf '%s\n' "${recovery_desired_record}" | cut -f2)
            [ "${recovery_repo}" = "-" ] && recovery_repo=""
        fi
        if [ "${RUNNER_SCOPE:-repo}" = "repo" ] && [ -z "${recovery_repo}" ]; then
            recovery_unresolved=$((recovery_unresolved + 1))
            continue
        fi
        recovery_endpoint=$(registration_endpoint_for_slot "${recovery_repo}") || {
            recovery_unresolved=$((recovery_unresolved + 1))
            continue
        }
        recovery_target_hash=$(printf '%s' "${recovery_endpoint}" | sha256sum | awk '{ print $1 }')
        recovery_inventory_path="${recovery_inventory_directory}/${recovery_target_hash}.json"
        if [ ! -f "${recovery_inventory_path}" ]; then
            if ! fetch_github_runner_inventory \
                "${recovery_inventory_path}" \
                "${recovery_endpoint}" \
                "${ACCESS_TOKEN:-}" \
                "${REGISTRATION_API_TIMEOUT}"; then
                recovery_unresolved=$((recovery_unresolved + 1))
                continue
            fi
        fi

        recovery_candidates_path="${HOST_ADMISSION_RECOVERY_DIRECTORY}/candidates-${recovery_slot_key}.json"
        if [ -n "${recovery_registration_name}" ]; then
            if ! jq \
                --arg runnerName "${recovery_registration_name}" \
                '[
                    .runners[]
                    | select(.name == $runnerName)
                    | {id, name, status, busy, labels}
                ]' \
                "${recovery_inventory_path}" > "${recovery_candidates_path}"; then
                recovery_unresolved=$((recovery_unresolved + 1))
                continue
            fi
        else
            if [ -z "${recovery_tag}" ]; then
                recovery_unresolved=$((recovery_unresolved + 1))
                continue
            fi
            recovery_name_prefix="${PREFIX}-${recovery_tag}-"
            if ! jq \
                --arg namePrefix "${recovery_name_prefix}" \
                '[
                    .runners[] as $runner
                    | select(
                        ($runner.name | startswith($namePrefix))
                        and (
                            $runner.name
                            | ltrimstr($namePrefix)
                            | test("^[0-9]+-[a-f0-9]{6}$")
                        )
                    )
                    | {
                        id: $runner.id,
                        name: $runner.name,
                        status: $runner.status,
                        busy: $runner.busy,
                        labels: $runner.labels
                    }
                ]' "${recovery_inventory_path}" > "${recovery_candidates_path}"; then
                recovery_unresolved=$((recovery_unresolved + 1))
                continue
            fi
        fi
        recovery_candidate_count=$(
            jq -er 'if type == "array" then length else error("invalid") end' \
                "${recovery_candidates_path}"
        ) || {
            recovery_unresolved=$((recovery_unresolved + 1))
            continue
        }
        if [ "${recovery_candidate_count}" -gt 1 ]; then
            recovery_unresolved=$((recovery_unresolved + 1))
            continue
        fi
        if [ "${recovery_candidate_count}" -eq 1 ]; then
            if [ -n "${recovery_registration_name}" ]; then
                if ! jq -e \
                    '.[0].status == "offline" and .[0].busy == false' \
                    "${recovery_candidates_path}" >/dev/null 2>&1; then
                    recovery_unresolved=$((recovery_unresolved + 1))
                    continue
                fi
            else
                if ! jq -e \
                    --slurpfile requiredLabels "${recovery_labels_path}" \
                    '
                        .[0].status == "offline"
                        and .[0].busy == false
                        and (
                            (($requiredLabels[0] - .[0].labels) | length)
                            == 0
                        )
                    ' "${recovery_candidates_path}" >/dev/null 2>&1; then
                    recovery_unresolved=$((recovery_unresolved + 1))
                    continue
                fi
            fi
            recovery_runner_id=$(jq -r '.[0].id' "${recovery_candidates_path}")
            recovery_verified_name=$(jq -r '.[0].name' "${recovery_candidates_path}")
            if ! remove_github_runner_registration \
                "${recovery_endpoint}" \
                "${recovery_runner_id}" \
                "${ACCESS_TOKEN:-}" \
                "${REGISTRATION_API_TIMEOUT}"; then
                recovery_unresolved=$((recovery_unresolved + 1))
                continue
            fi
            rm -f "${recovery_inventory_path}"
            if ! fetch_github_runner_inventory \
                "${recovery_inventory_path}" \
                "${recovery_endpoint}" \
                "${ACCESS_TOKEN:-}" \
                "${REGISTRATION_API_TIMEOUT}" ||
                jq -e \
                    --arg runnerName "${recovery_verified_name}" \
                    'any(.runners[]; .name == $runnerName)' \
                    "${recovery_inventory_path}" >/dev/null 2>&1; then
                recovery_unresolved=$((recovery_unresolved + 1))
                continue
            fi
        fi
        if host_admission_reconcile_absent \
            "$(slot_path "${recovery_slot_key}")" \
            "${recovery_slot_key}"; then
            recovery_reconciled=$((recovery_reconciled + 1))
        else
            recovery_unresolved=$((recovery_unresolved + 1))
        fi
    done < "${recovery_records_path}"

    if [ "${recovery_reconciled}" -gt 0 ]; then
        record_manager_diagnostic \
            recovery \
            manager-start \
            "" \
            recovered \
            "" \
            recovered \
            "Manager reconciled ${recovery_reconciled} orphaned host admission leases"
        mark_observed_state_dirty
    fi
    if [ "${recovery_unresolved}" -gt 0 ]; then
        recovery_state="pending-${recovery_unresolved}"
        if [ "${recovery_state}" != "${HOST_ADMISSION_LAST_RECOVERY_STATE}" ]; then
            record_manager_diagnostic \
                recovery \
                manager-start \
                "" \
                blocked \
                "" \
                invalid-state \
                "Host admission recovery retained ${recovery_unresolved} unresolved active leases"
            HOST_ADMISSION_LAST_RECOVERY_STATE="${recovery_state}"
            mark_observed_state_dirty
        fi
        return 1
    fi
    HOST_ADMISSION_LAST_RECOVERY_STATE=""
    return 0
}
