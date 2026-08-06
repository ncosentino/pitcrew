#!/bin/sh

desired_state_is_valid() {
    jq -e '
        def positive_integer:
            type == "number" and . >= 1 and floor == .;
        def nonnegative_integer:
            type == "number" and . >= 0 and floor == .;
        def valid_url:
            type == "string"
            and length > 0
            and . != "-"
            and (test("\\s") | not)
            and test("^https?://[^/@?#]+/[^?#]+$"; "i")
            and (test("^https?://[^/@]+@"; "i") | not);
        type == "object"
        and .schemaVersion == 1
        and (.generation | positive_integer)
        and (.scope == "repo" or .scope == "org" or .scope == "ent")
        and (.repositories | type == "array")
        and (
            if .scope == "repo" then
                (.repositories | length > 0)
                and all(.repositories[]; (.url | valid_url) and (.workers | nonnegative_integer))
                and (([.repositories[].url] | unique | length) == (.repositories | length))
                and .replicas == null
            else
                (.repositories | length == 0)
                and (.replicas | nonnegative_integer)
            end
        )
    ' "$1" >/dev/null 2>&1
}

desired_state_generation() {
    jq -r '.generation' "$1"
}

desired_state_hash() {
    jq -S -c '.' "$1" | sha256sum | awk '{ print $1 }'
}

classify_desired_state() {
    state_path="$1"
    current_generation="$2"
    current_hash="$3"

    if ! desired_state_is_valid "${state_path}"; then
        echo "invalid"
        return
    fi

    candidate_generation=$(desired_state_generation "${state_path}")
    candidate_hash=$(desired_state_hash "${state_path}")
    if [ "${candidate_generation}" -lt "${current_generation}" ]; then
        echo "stale"
    elif [ "${candidate_generation}" -eq "${current_generation}" ]; then
        if [ "${candidate_hash}" = "${current_hash}" ]; then
            echo "unchanged"
        else
            echo "conflict"
        fi
    else
        echo "new"
    fi
}

render_desired_slots() {
    state_path="$1"
    output_path="$2"
    repositories_path="${output_path}.repositories"
    : > "${output_path}"

    if ! scope=$(jq -r '.scope' "${state_path}"); then
        return 1
    fi
    if [ "${scope}" = "repo" ]; then
        if ! jq -r '.repositories[] | [.url, (.workers | tostring)] | @tsv' \
            "${state_path}" > "${repositories_path}"; then
            rm -f "${repositories_path}"
            return 1
        fi
        tab=$(printf '\t')
        while IFS="${tab}" read -r url count; do
            identity=$(printf '%s' "${url}" | sha256sum | awk '{ print substr($1, 1, 16) }')
            repo_slug=$(
                printf '%s' "${url}" |
                    sed 's#/*$##; s#.*/##' |
                    tr -cs 'A-Za-z0-9' '-' |
                    sed 's/^-*//; s/-*$//'
            )
            [ -n "${repo_slug}" ] || repo_slug="repository"
            ordinal=1
            while [ "${ordinal}" -le "${count}" ]; do
                padded_ordinal=$(printf '%06d' "${ordinal}")
                printf 'repo-%s-%s\t%s\t%s-%s\n' \
                    "${identity}" \
                    "${padded_ordinal}" \
                    "${url}" \
                    "${repo_slug}" \
                    "${ordinal}" >> "${output_path}"
                ordinal=$((ordinal + 1))
            done
        done < "${repositories_path}"
        rm -f "${repositories_path}"
    else
        if ! replicas=$(jq -r '.replicas' "${state_path}"); then
            return 1
        fi
        ordinal=1
        while [ "${ordinal}" -le "${replicas}" ]; do
            padded_ordinal=$(printf '%06d' "${ordinal}")
            printf 'scope-%s\t-\t%s\n' "${padded_ordinal}" "${ordinal}" >> "${output_path}"
            ordinal=$((ordinal + 1))
        done
    fi

    sort -o "${output_path}" "${output_path}"
}

write_undesired_slot_keys() {
    desired_slots_path="$1"
    active_keys_path="$2"
    output_path="$3"
    awk -F '\t' '
        NR == FNR {
            desired[$1] = 1
            next
        }
        !($1 in desired) {
            print $1
        }
    ' "${desired_slots_path}" "${active_keys_path}" > "${output_path}"
}

write_legacy_desired_state() {
    output_path="$1"
    scope="$2"
    repositories="$3"
    replicas="$4"
    repository_objects="${output_path}.repositories"
    rm -f "${output_path}" "${repository_objects}"

    case "${scope}" in
        repo)
            [ -n "${repositories}" ] || return 1
            : > "${repository_objects}"
            if ! printf '%s\n' "${repositories}" |
                tr ',' '\n' |
                while IFS= read -r entry; do
                    entry=$(printf '%s' "${entry}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
                    [ -n "${entry}" ] || continue
                    url="${entry%%=*}"
                    workers="${entry##*=}"
                    [ "${workers}" = "${url}" ] && workers=1
                    case "${workers}" in
                        ''|*[!0-9]*|0) exit 1 ;;
                    esac
                    jq -n \
                        --arg url "${url}" \
                        --argjson workers "${workers}" \
                        '{url: $url, workers: $workers}' >> "${repository_objects}" ||
                        exit 1
                done; then
                rm -f "${repository_objects}"
                return 1
            fi
            if ! jq -s \
                '{
                    schemaVersion: 1,
                    generation: 1,
                    scope: "repo",
                    repositories: .,
                    replicas: null
                }' "${repository_objects}" > "${output_path}"; then
                rm -f "${output_path}" "${repository_objects}"
                return 1
            fi
            ;;
        org|ent)
            case "${replicas}" in
                ''|*[!0-9]*|0) return 1 ;;
            esac
            if ! jq -n \
                --arg scope "${scope}" \
                --argjson replicas "${replicas}" \
                '{
                    schemaVersion: 1,
                    generation: 1,
                    scope: $scope,
                    repositories: [],
                    replicas: $replicas
                }' > "${output_path}"; then
                rm -f "${output_path}"
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac

    rm -f "${repository_objects}"
    desired_state_is_valid "${output_path}"
}

# Contract-11 worker resource policy. An empty value means the dimension has no
# configured limit and must never be published or applied as zero.
WORKER_MEMORY_MINIMUM_BYTES=6291456
WORKER_PIDS_MAXIMUM=2147483647

worker_policy_byte_value_is_valid() {
    case "$1" in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ "$1" -ge "${WORKER_MEMORY_MINIMUM_BYTES}" ]
}

worker_resource_policy_is_valid() {
    policy_memory_bytes="$1"
    policy_memory_swap_bytes="$2"
    policy_cpu_cores="$3"
    policy_pids_limit="$4"

    if [ -n "${policy_memory_bytes}" ] &&
        ! worker_policy_byte_value_is_valid "${policy_memory_bytes}"; then
        return 1
    fi
    if [ -n "${policy_memory_swap_bytes}" ]; then
        worker_policy_byte_value_is_valid "${policy_memory_swap_bytes}" || return 1
        [ -n "${policy_memory_bytes}" ] || return 1
        [ "${policy_memory_swap_bytes}" -ge "${policy_memory_bytes}" ] || return 1
    fi
    if [ -n "${policy_cpu_cores}" ]; then
        printf '%s' "${policy_cpu_cores}" |
            grep -Eq '^([1-9][0-9]*(\.[0-9]{1,9})?|0\.[0-9]{0,8}[1-9])$' || return 1
    fi
    if [ -n "${policy_pids_limit}" ]; then
        case "${policy_pids_limit}" in
            ''|*[!0-9]*|0*) return 1 ;;
        esac
        [ "${policy_pids_limit}" -le "${WORKER_PIDS_MAXIMUM}" ] || return 1
    fi
}

render_worker_resource_arguments() {
    worker_resource_policy_is_valid "$1" "$2" "$3" "$4" || return 1
    policy_arguments=""
    if [ -n "$1" ]; then
        policy_arguments="${policy_arguments}--memory $1 "
    fi
    if [ -n "$2" ]; then
        policy_arguments="${policy_arguments}--memory-swap $2 "
    fi
    if [ -n "$3" ]; then
        policy_arguments="${policy_arguments}--cpus $3 "
    fi
    if [ -n "$4" ]; then
        policy_arguments="${policy_arguments}--pids-limit $4 "
    fi
    printf '%s\n' "${policy_arguments% }"
}

write_worker_resource_policy() {
    policy_output_path="$1"
    shift
    worker_resource_policy_is_valid "$@" || return 1
    if [ -z "$1$2$3$4" ]; then
        printf 'null\n' > "${policy_output_path}"
        return
    fi
    jq -n \
        --arg memoryBytes "$1" \
        --arg memorySwapBytes "$2" \
        --arg cpuCores "$3" \
        --arg pids "$4" \
        '{
            memoryBytes: (if $memoryBytes == "" then null else ($memoryBytes | tonumber) end),
            memorySwapBytes: (
                if $memorySwapBytes == "" then null else ($memorySwapBytes | tonumber) end
            ),
            cpuCores: (if $cpuCores == "" then null else $cpuCores end),
            pids: (if $pids == "" then null else ($pids | tonumber) end)
        }' > "${policy_output_path}"
}
