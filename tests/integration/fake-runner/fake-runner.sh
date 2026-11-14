#!/bin/sh
set -eu

if [ "${PITCREW_FAKE_SERVICE:-0}" = "1" ]; then
    while :; do
        printf 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nready\n' |
            nc -l -p 8080
    done
fi

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
if [ -f /mnt/pitcrew-data/handoff/migration-fixture ]; then
    echo "Running job: migration-fixture"
    progress=0
    while [ ! -f /mnt/pitcrew-data/handoff/finish ]; do
        progress=$((progress + 1))
        printf '%s\n' "$progress" > /tmp/progress.new
        mv /tmp/progress.new /tmp/progress
        sleep 1 &
        wait "$!"
    done
    printf '%s\n' "$progress" > /mnt/pitcrew-data/handoff/completed
    echo "Job migration-fixture completed with result: Succeeded"
    exit 0
fi
while :; do
    sleep 1 &
    wait "$!"
done
