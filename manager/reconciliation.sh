#!/bin/sh

desired_state_is_valid() {
    jq -e '
        def positive_integer:
            type == "number" and . >= 1 and floor == .;
        def valid_url:
            type == "string" and length > 0 and . != "-" and (test("[\\t\\r\\n]") | not);
        type == "object"
        and .schemaVersion == 1
        and (.generation | positive_integer)
        and (.scope == "repo" or .scope == "org" or .scope == "ent")
        and (.repositories | type == "array")
        and (
            if .scope == "repo" then
                (.repositories | length > 0)
                and all(.repositories[]; (.url | valid_url) and (.workers | positive_integer))
                and (([.repositories[].url] | unique | length) == (.repositories | length))
                and .replicas == null
            else
                (.repositories | length == 0)
                and (.replicas | positive_integer)
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
