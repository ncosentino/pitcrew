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
while :; do
    sleep 1 &
    wait "$!"
done
