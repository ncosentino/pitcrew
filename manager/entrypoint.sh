#!/bin/sh
set -eu

case "${PITCREW_AUTOSCALING_MODE:-}" in
    '')
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
