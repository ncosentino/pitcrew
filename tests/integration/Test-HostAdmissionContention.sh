#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUN_ID="${GITHUB_RUN_ID:-$$}"
IMAGE="pitcrew-admission-contention:${RUN_ID}"
VOLUME="pitcrew-admission-contention-${RUN_ID}"
COORDINATOR="pitcrew-admission-contention-${RUN_ID}"
SOCKET="/var/lib/pitcrew-admission/coordinator.sock"
TEMP_DIRECTORY=$(mktemp -d)
GENERATION=0

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

cleanup() {
    status=$?
    if [ "${status}" -ne 0 ]; then
        docker logs "${COORDINATOR}" 2>&1 || true
    fi
    docker rm -f "${COORDINATOR}" >/dev/null 2>&1 || true
    docker volume rm "${VOLUME}" >/dev/null 2>&1 || true
    docker image rm -f "${IMAGE}" >/dev/null 2>&1 || true
    rm -rf "${TEMP_DIRECTORY}"
    trap - EXIT
    exit "${status}"
}
trap cleanup EXIT

client() {
    docker run \
        --rm \
        --mount "type=volume,src=${VOLUME},dst=/var/lib/pitcrew-admission" \
        --entrypoint /usr/local/bin/pitcrew-admission \
        "${IMAGE}" \
        "$@" \
        --socket "${SOCKET}"
}

client_with_stdin() {
    docker run \
        --rm \
        --interactive \
        --mount "type=volume,src=${VOLUME},dst=/var/lib/pitcrew-admission" \
        --entrypoint /usr/local/bin/pitcrew-admission \
        "${IMAGE}" \
        "$@" \
        --socket "${SOCKET}"
}

start_coordinator() {
    docker run \
        --detach \
        --rm \
        --name "${COORDINATOR}" \
        --network none \
        --mount "type=volume,src=${VOLUME},dst=/var/lib/pitcrew-admission" \
        --entrypoint /usr/local/bin/pitcrew-admission \
        "${IMAGE}" \
        serve \
        --socket "${SOCKET}" \
        --state-dir /var/lib/pitcrew-admission/state \
        >/dev/null

    deadline=$((SECONDS + 30))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if client status >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    fail "Coordinator did not become reachable."
}

stop_coordinator() {
    docker stop --time 2 "${COORDINATOR}" >/dev/null
    deadline=$((SECONDS + 10))
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if ! docker inspect "${COORDINATOR}" >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done
    fail "Coordinator container was not removed after stop."
}

apply_policy() {
    policy_path="$1"
    client_with_stdin apply-policy --policy-file - < "${policy_path}"
}

write_pair_policy() {
    left_profile="$1"
    right_profile="$2"
    total_units="$3"
    left_reserved="$4"
    left_borrowable="$5"
    right_reserved="$6"
    right_borrowable="$7"
    GENERATION=$((GENERATION + 1))
    policy_path="${TEMP_DIRECTORY}/policy-${GENERATION}.json"
    capacity_units=$((total_units + 1))
    cat > "${policy_path}" <<EOF
{
  "generation": ${GENERATION},
  "totalUnits": ${total_units},
  "namespace": "synthetic",
  "capacityUnits": ${capacity_units},
  "safetyMarginUnits": 1,
  "hostPolicyFingerprint": "synthetic-host-${GENERATION}",
  "profiles": [
    {
      "profileId": "${left_profile}",
      "unitCost": 1,
      "reservedUnits": ${left_reserved},
      "borrowable": ${left_borrowable},
      "profilePolicyFingerprint": "${left_profile}-${GENERATION}"
    },
    {
      "profileId": "${right_profile}",
      "unitCost": 1,
      "reservedUnits": ${right_reserved},
      "borrowable": ${right_borrowable},
      "profilePolicyFingerprint": "${right_profile}-${GENERATION}"
    }
  ]
}
EOF
    apply_policy "${policy_path}"
}

fixed_acquire_activate() {
    profile="$1"
    slot="$2"
    actor_directory="${TEMP_DIRECTORY}/fixed-${profile}-${slot}"
    mkdir -p "${actor_directory}/slots/${slot}"
    docker run \
        --rm \
        --mount "type=volume,src=${VOLUME},dst=/var/lib/pitcrew-admission" \
        --mount "type=bind,src=${actor_directory},dst=/state" \
        --env "PROFILE_ID=${profile}" \
        --env "TEST_SLOT=${slot}" \
        --env "PITCREW_HOST_ADMISSION_NAMESPACE=synthetic" \
        --env "PITCREW_HOST_ADMISSION_SOCKET=${SOCKET}" \
        --env "PITCREW_HOST_ADMISSION_CLI=/usr/local/bin/pitcrew-admission" \
        --env "PITCREW_HOST_ADMISSION_CLI_TIMEOUT=5" \
        --entrypoint /bin/sh \
        "${IMAGE}" \
        -c '
            set -u
            . /usr/local/bin/host-admission.sh
            host_admission_acquire \
                "/state/slots/${TEST_SLOT}" \
                "${TEST_SLOT}" \
                /state/slots || exit $?
            host_admission_activate \
                "/state/slots/${TEST_SLOT}" \
                "${TEST_SLOT}" || exit $?
        '
}

autoscaled_acquire_activate() {
    profile="$1"
    slot="$2"
    client acquire \
        --profile "${profile}" \
        --slot "${slot}" \
        --demand 2 \
        >/dev/null || {
            status=$?
            return "${status}"
        }
    client activate \
        --profile "${profile}" \
        --slot "${slot}" \
        >/dev/null || {
            status=$?
            return "${status}"
        }
}

actor_acquire_activate() {
    mode="$1"
    profile="$2"
    slot="$3"
    case "${mode}" in
        fixed)
            set +e
            fixed_acquire_activate "${profile}" "${slot}"
            status=$?
            set -e
            case "${status}" in
                2) return 3 ;;
                3) return 5 ;;
                *) return "${status}" ;;
            esac
            ;;
        autoscaled) autoscaled_acquire_activate "${profile}" "${slot}" ;;
        *) fail "Unsupported actor mode '${mode}'." ;;
    esac
}

expect_exit() {
    expected="$1"
    shift
    set +e
    "$@" >/dev/null 2>&1
    actual=$?
    set -e
    [ "${actual}" -eq "${expected}" ] ||
        fail "Expected exit ${expected}, got ${actual}: $*"
}

release_slot() {
    profile="$1"
    slot="$2"
    client release --profile "${profile}" --slot "${slot}" >/dev/null
}

run_mode_pair() {
    left_mode="$1"
    right_mode="$2"
    left_profile="${left_mode}-a"
    right_profile="${right_mode}-b"
    scenario="${left_mode}-${right_mode}"
    results="${TEMP_DIRECTORY}/results-${scenario}"
    mkdir -p "${results}"

    write_pair_policy \
        "${left_profile}" \
        "${right_profile}" \
        2 \
        1 \
        false \
        1 \
        false
    client set-demand --profile "${left_profile}" --demand 2 >/dev/null
    client set-demand --profile "${right_profile}" --demand 2 >/dev/null

    for actor in \
        "${left_mode}|${left_profile}|${left_profile}-0" \
        "${left_mode}|${left_profile}|${left_profile}-1" \
        "${right_mode}|${right_profile}|${right_profile}-0" \
        "${right_mode}|${right_profile}|${right_profile}-1"; do
        IFS='|' read -r mode profile slot <<< "${actor}"
        (
            if actor_acquire_activate "${mode}" "${profile}" "${slot}"; then
                printf 'success|%s|%s\n' "${profile}" "${slot}"
            else
                status=$?
                printf 'denied|%s|%s|%s\n' "${profile}" "${slot}" "${status}"
            fi
        ) > "${results}/${slot}" &
    done
    wait

    success_count=$(awk -F'|' '$1 == "success" { count++ } END { print count + 0 }' "${results}"/*)
    [ "${success_count}" -eq 2 ] ||
        fail "${scenario} admitted ${success_count} slots against budget 2."
    if ! awk -F'|' '$1 == "denied" && $4 != 3 { exit 1 }' "${results}"/*; then
        failures=$(awk -F'|' '$1 == "denied" && $4 != 3 { print }' "${results}"/*)
        fail "${scenario} observed a non-budget admission failure: ${failures}"
    fi
    for profile in "${left_profile}" "${right_profile}"; do
        profile_successes=$(awk -F'|' \
            -v profile="${profile}" \
            '$1 == "success" && $2 == profile { count++ } END { print count + 0 }' \
            "${results}"/*)
        [ "${profile_successes}" -eq 1 ] ||
            fail "${scenario} did not preserve one reserved unit for ${profile}."
    done

    status_path="${TEMP_DIRECTORY}/status-${scenario}.json"
    client status > "${status_path}"
    [ "$(jq '[.leases[].units] | add // 0' "${status_path}")" -eq 2 ] ||
        fail "${scenario} status exceeded its synthetic budget."
    [ "$(jq '[.leases[] | select(.status == "active")] | length' "${status_path}")" -eq 2 ] ||
        fail "${scenario} did not activate both admitted leases."

    expect_exit 3 \
        client acquire \
            --profile "${left_profile}" \
            --slot "${left_profile}-withheld" \
            --demand 1

    released_record=$(awk -F'|' \
        -v profile="${left_profile}" \
        '$1 == "success" && $2 == profile { print; exit }' \
        "${results}"/*)
    released_slot=${released_record##*|}
    release_slot "${left_profile}" "${released_slot}"
    autoscaled_acquire_activate "${left_profile}" "${left_profile}-replacement"

    while IFS='|' read -r outcome profile slot; do
        [ "${outcome}" = "success" ] || continue
        [ "${profile}" = "${left_profile}" ] &&
            [ "${slot}" = "${released_slot}" ] &&
            continue
        release_slot "${profile}" "${slot}"
    done < <(cat "${results}"/*)
    release_slot "${left_profile}" "${left_profile}-replacement"
    client set-demand --profile "${left_profile}" --demand 0 >/dev/null
    client set-demand --profile "${right_profile}" --demand 0 >/dev/null
}

docker build --tag "${IMAGE}" "${ROOT}/manager"
docker volume create "${VOLUME}" >/dev/null
start_coordinator

run_mode_pair fixed fixed
run_mode_pair fixed autoscaled
run_mode_pair autoscaled autoscaled

write_pair_policy fixed-owner autoscaled-borrower 2 1 true 0 false
client set-demand --profile fixed-owner --demand 0 >/dev/null
client set-demand --profile autoscaled-borrower --demand 2 >/dev/null
autoscaled_acquire_activate autoscaled-borrower borrower-0
autoscaled_acquire_activate autoscaled-borrower borrower-1
expect_exit 3 \
    client acquire \
        --profile fixed-owner \
        --slot owner-0 \
        --demand 1
release_slot autoscaled-borrower borrower-0
fixed_acquire_activate fixed-owner owner-0
borrow_status="${TEMP_DIRECTORY}/borrow-status.json"
client status > "${borrow_status}"
[ "$(jq -r '.accounting[] | select(.profileId == "autoscaled-borrower") | .borrowedUnits' "${borrow_status}")" -eq 1 ] ||
    fail "Borrowed-unit accounting did not retain the active borrower."
release_slot autoscaled-borrower borrower-1
release_slot fixed-owner owner-0

write_pair_policy fixed-crash autoscaled-crash 2 0 false 0 false
client acquire --profile fixed-crash --slot active-slot --demand 1 >/dev/null
client activate --profile fixed-crash --slot active-slot >/dev/null
client acquire --profile autoscaled-crash --slot provisional-slot --demand 1 >/dev/null
stop_coordinator
start_coordinator
restart_status="${TEMP_DIRECTORY}/restart-status.json"
client status > "${restart_status}"
[ "$(jq '[.leases[] | select(.profileId == "fixed-crash" and .status == "active")] | length' "${restart_status}")" -eq 1 ] ||
    fail "Coordinator restart did not retain the active lease."
[ "$(jq '[.leases[] | select(.slotKey == "provisional-slot")] | length' "${restart_status}")" -eq 0 ] ||
    fail "Coordinator restart retained an unsafe provisional lease."

GENERATION=$((GENERATION + 1))
removal_policy="${TEMP_DIRECTORY}/policy-${GENERATION}.json"
cat > "${removal_policy}" <<EOF
{
  "generation": ${GENERATION},
  "totalUnits": 1,
  "namespace": "synthetic",
  "capacityUnits": 2,
  "safetyMarginUnits": 1,
  "hostPolicyFingerprint": "synthetic-host-${GENERATION}",
  "profiles": [
    {
      "profileId": "autoscaled-crash",
      "unitCost": 1,
      "reservedUnits": 0,
      "borrowable": false,
      "profilePolicyFingerprint": "autoscaled-crash-${GENERATION}"
    }
  ]
}
EOF
apply_policy "${removal_policy}"
removed_status="${TEMP_DIRECTORY}/removed-status.json"
client status > "${removed_status}"
[ "$(jq '[.leases[] | select(.profileId == "fixed-crash" and .status == "active")] | length' "${removed_status}")" -eq 1 ] ||
    fail "Profile removal revoked an active lease."
expect_exit 5 \
    client acquire \
        --profile fixed-crash \
        --slot removed-profile-new \
        --demand 1
release_slot fixed-crash active-slot
autoscaled_acquire_activate autoscaled-crash replacement-slot
release_slot autoscaled-crash replacement-slot

echo "Real-Docker host admission contention passed."
