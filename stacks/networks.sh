#!/usr/bin/env bash
set -euo pipefail
NET="${IOTLAB_NET:-lab-test2}"

if ! docker network inspect "$NET" >/dev/null 2>&1; then
  docker network create "$NET"
  echo "Created network: $NET"
else
  echo "Network exists: $NET"
fi
