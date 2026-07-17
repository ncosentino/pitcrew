#!/bin/sh
set -eu

trap 'exit 0' TERM INT
echo "Listening for Jobs"
while :; do
    sleep 1 &
    wait "$!"
done
