#!/bin/sh
set -eu

deregistration_credential="${ACCESS_TOKEN:-}"
if [ "${UNSET_CONFIG_VARS:-false}" = "true" ]; then
    deregistration_credential=""
fi
unset ACCESS_TOKEN

shutdown() {
    if [ -z "${deregistration_credential}" ]; then
        echo "Runner deregistration credential was not retained" >&2
        exit 1
    fi
    echo "Graceful runner deregistration"
    exit 0
}

trap shutdown TERM INT
echo "Listening for Jobs"

# Optional one-shot job simulation for the drain/upgrade integration scenarios.
# When FAKE_RUNNER_JOB_SECONDS is a positive integer the runner emits the exact
# log lines the manager scans for its job-busy signal ("Running job:" ->
# job-active; "completed with result" -> idle), stays busy for that many
# seconds, then idles WITHOUT exiting. This drives the real job-active /
# busySlots marker so a cooperative drain must wait for the job to finish; the
# default (unset/0) keeps the historical pure-idle behavior so the existing
# capacity scenarios are unaffected.
if [ -n "${FAKE_RUNNER_JOB_SECONDS:-}" ] && [ "${FAKE_RUNNER_JOB_SECONDS}" -gt 0 ] 2>/dev/null; then
    job_name="${FAKE_RUNNER_JOB_NAME:-integration-job}"
    echo "Running job: ${job_name}"
    remaining="${FAKE_RUNNER_JOB_SECONDS}"
    while [ "${remaining}" -gt 0 ]; do
        sleep 1 &
        wait "$!"
        remaining=$((remaining - 1))
    done
    echo "Job ${job_name} completed with result: Succeeded"
fi

while :; do
    sleep 1 &
    wait "$!"
done
