#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIRECTORY=$(mktemp -d)

same_fixture_process() {
    [ -r "/proc/$1/stat" ] &&
        [ "$(awk '{print $22}' "/proc/$1/stat")" = "$2" ]
}

cleanup() {
    for record in "${TEMP_DIRECTORY}"/*/*.pid; do
        [ -f "${record}" ] || continue
        read -r pid birth < "${record}"
        if same_fixture_process "${pid}" "${birth}"; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    done
    rm -rf "${TEMP_DIRECTORY}"
}
trap cleanup EXIT

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

mkdir "${TEMP_DIRECTORY}/bin"
cat > "${TEMP_DIRECTORY}/bin/docker" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    info) phase=info ;;
    ps)
        if [ "$2" = "-q" ]; then
            phase=manager-ps
        else
            phase=worker-ps
        fi
        ;;
    stats) phase=stats ;;
    *) exit 1 ;;
esac
if [ "${STALL_PHASE}" = "${phase}" ] || [ "${STALL_PHASE}" = "all" ]; then
    trap 'printf "%s\n" TERM > "${CASE_DIRECTORY}/${phase}.term"' TERM
    birth=$(awk '{print $22}' "/proc/$$/stat")
    printf '%s %s\n' "$$" "${birth}" > "${CASE_DIRECTORY}/${phase}.pid"
    # No child sleep or inherited pipe: this exact query ignores TERM until KILL.
    while :; do :; done
fi
case "${phase}" in
    info)
        printf '%s\n' '{"logicalProcessorCount":4,"memoryBytes":4294967296}'
        ;;
    manager-ps) printf '%s\n' manager123 ;;
    worker-ps) printf '%s\n' 'worker123 slot-one runner-one' ;;
    stats)
        printf '%s\n' "$@" > "${CASE_DIRECTORY}/stats-arguments"
        printf '%s\n' \
            '{"CPUPerc":"1%","ID":"manager123","MemUsage":"1MiB / 4GiB","PIDs":"2"}' \
            '{"CPUPerc":"2%","ID":"worker123","MemUsage":"2MiB / 4GiB","PIDs":"3"}'
        ;;
esac
EOF
chmod +x "${TEMP_DIRECTORY}/bin/docker"

cat > "${TEMP_DIRECTORY}/collect.sh" <<'EOF'
#!/bin/sh
set -eu
. "${ROOT}/manager/observability.sh"
collect_resource_telemetry \
    "${CASE_DIRECTORY}/resources.json" \
    'ephemeral-managed-runner-profile=example' \
    'ephemeral-runner-manager-profile=example' \
    'ephemeral-managed-runner-slot' \
    2
printf '%s\n' continued > "${CASE_DIRECTORY}/parent-progress"
EOF

for phase in info manager-ps worker-ps stats all; do
    case_directory="${TEMP_DIRECTORY}/${phase}"
    mkdir "${case_directory}"
    # This outer watchdog is a failure guard, not an elapsed-time assertion.
    # TERM receipt below proves the exact stalled phase was active.
    if ! ROOT="${ROOT}" CASE_DIRECTORY="${case_directory}" STALL_PHASE="${phase}" \
        HOSTNAME= PITCREW_HOST_PROC_PATH="${TEMP_DIRECTORY}/missing-proc" \
        PATH="${TEMP_DIRECTORY}/bin:${PATH}" \
        timeout -s TERM -k 1 60 sh "${TEMP_DIRECTORY}/collect.sh"; then
        fail "The collector did not progress after a stalled ${phase} query."
    fi
    [ -f "${case_directory}/parent-progress" ] ||
        fail "The caller did not continue after ${phase} telemetry."
    expected_phases="${phase}"
    [ "${phase}" != all ] || expected_phases="info manager-ps worker-ps"
    for stalled in ${expected_phases}; do
        [ -s "${case_directory}/${stalled}.pid" ] ||
            fail "The ${stalled} query never reached its armed TERM trap."
        [ -s "${case_directory}/${stalled}.term" ] ||
            fail "The ${stalled} query did not receive and ignore TERM."
        read -r pid birth < "${case_directory}/${stalled}.pid"
        deadline=$(($(date +%s) + 10))
        while same_fixture_process "${pid}" "${birth}"; do
            [ "$(date +%s)" -lt "${deadline}" ] ||
                fail "The exact ${stalled} query was not reaped."
            sleep 0.1
        done
    done
    [ "$(find "${case_directory}" -name '.resource-telemetry.*' | wc -l)" -eq 0 ] ||
        fail "The ${phase} sample leaked a working directory or temporary output."
    case "${phase}" in
        info)
            jq -e '.status == "partial" and .host == null and .manager != null
                and .slots["slot-one"].usage != null' \
                "${case_directory}/resources.json" >/dev/null ||
                fail "Host failure discarded valid container telemetry."
            ;;
        manager-ps)
            jq -e '.status == "partial" and .host != null and .manager == null
                and .slots["slot-one"].usage != null' \
                "${case_directory}/resources.json" >/dev/null ||
                fail "Manager discovery failure fabricated manager telemetry."
            ;;
        worker-ps)
            jq -e '.status == "partial" and .manager != null and .slots == {}' \
                "${case_directory}/resources.json" >/dev/null ||
                fail "Worker discovery failure fabricated worker telemetry."
            ;;
        stats)
            jq -e '.status == "partial" and .host != null
                and .manager == null and .slots == {}' \
                "${case_directory}/resources.json" >/dev/null ||
                fail "Stats failure fabricated container telemetry."
            ;;
        all)
            jq -e '.status == "unavailable" and .host == null
                and .manager == null and .slots == {}' \
                "${case_directory}/resources.json" >/dev/null ||
                fail "Total query failure fabricated available telemetry."
            ;;
    esac
    printf 'PASS: TERM-ignoring %s query reaped; caller progressed; telemetry and cleanup verified.\n' "${phase}"
done

grep -qx manager123 "${TEMP_DIRECTORY}/info/stats-arguments" &&
    grep -qx worker123 "${TEMP_DIRECTORY}/info/stats-arguments" ||
    fail "Stats did not receive the exact discovered container IDs."
