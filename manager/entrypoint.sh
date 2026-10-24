#!/bin/sh
set -eu

case "${PITCREW_AUTOSCALING_MODE:-}" in
    '')
        if [ -n "${PITCREW_WORKER_DOCKER_MODE:-}${PITCREW_WORKER_DOCKER_STORAGE_BYTES:-}" ]; then
            echo '[manager] nested Docker requires scale-set mode' >&2
            exit 1
        fi
        exec /usr/local/bin/manage-runners.sh
        ;;
    scale-set)
        exec /usr/local/bin/pitcrew-autoscaler
        ;;
    *)
        echo "[manager] unsupported autoscaling mode: ${PITCREW_AUTOSCALING_MODE}" >&2
        exit 1
        ;;
esac
