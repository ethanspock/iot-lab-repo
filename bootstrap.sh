#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config (override via .env)
# -----------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[*] Repo root: $REPO_ROOT"

PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"
IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"
IOTLAB_ETC_ROOT="${IOTLAB_ETC_ROOT:-/etc/iot-lab}"
IOTLAB_NET="${IOTLAB_NET:-lab-test2}"

# Repo deploy settings for Portainer "repository stack"
REPO_URL="${REPO_URL:-https://github.com/ethanspock/iot-lab-repo.git}"
REPO_REF="${REPO_REF:-refs/heads/main}"

# Stacks in order
STACKS=(
  "iot-lab-core:stacks/iot-lab-core/docker-compose.yml"
  "iot-lab-mqtt:stacks/iot-lab-mqtt/docker-compose.yml"
  "iot-lab-modbus:stacks/iot-lab-modbus/docker-compose.yml"
  "iot-lab-bacnet:stacks/iot-lab-bacnet/docker-compose.yml"
  "iot-lab-monitoring:stacks/iot-lab-monitoring/docker-compose.yml"
)

echo "[*] Portainer:  $PORTAINER_URL"
echo "[*] Data root:  $IOTLAB_DATA_ROOT"
echo "[*] Etc  root:  $IOTLAB_ETC_ROOT"
echo "[*] Network:    $IOTLAB_NET"
echo "[*] Repo URL:   $REPO_URL"
echo "[*] Repo REF:   $REPO_REF"

# -----------------------------
# Load .env if present
# -----------------------------
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "[*] Loading .env"
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

# -----------------------------
# Helpers
# -----------------------------
http() {
  # usage: http METHOD URL JSON_BODY(optional)
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"

  local tmp
  tmp="$(mktemp)"
  local code

  if [[ -n "$body" ]]; then
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer $JWT" \
      -H "Content-Type: application/json" \
      -d "$body" || true)"
  else
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer $JWT" || true)"
  fi

  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
    cat "$tmp"
    rm -f "$tmp"
    return 0
  fi

  echo "[!] HTTP $code for $method $url" >&2
  if [[ -s "$tmp" ]]; then
    echo "---- response body ----" >&2
    cat "$tmp" >&2
    echo -e "\n-----------------------" >&2
  fi
  rm -f "$tmp"
  return 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[!] Missing: $1" >&2; exit 1; }; }

# -----------------------------
# Preconditions
# -----------------------------
need_cmd curl
need_cmd jq
need_cmd docker
need_cmd ip
need_cmd sed
need_cmd awk

# -----------------------------
# Wait for Portainer
# -----------------------------
echo "[*] Waiting for Portainer API..."
until curl -fsS "$PORTAINER_URL/api/status" >/dev/null; do sleep 2; done
VER="$(curl -fsS "$PORTAINER_URL/api/status" | jq -r .Version)"
echo "[*] Portainer version: $VER"

# -----------------------------
# Auth
# -----------------------------
read -rsp "Portainer admin password: " PASS
echo

JWT="$(curl -sS -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u admin --arg p "$PASS" '{Username:$u,Password:$p}')" \
  | jq -r .jwt)"

if [[ -z "$JWT" || "$JWT" == "null" ]]; then
  echo "[!] Login failed. Initialize admin via UI or /api/users/admin/init first." >&2
  exit 1
fi

# -----------------------------
# Determine endpointId (local docker environment)
# -----------------------------
ENDPOINT_ID="$(curl -sS "$PORTAINER_URL/api/endpoints" -H "Authorization: Bearer $JWT" \
  | jq -r '.[0].Id')"

if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "null" ]]; then
  echo "[!] Could not determine endpointId from /api/endpoints" >&2
  exit 1
fi
echo "[*] Using endpointId: $ENDPOINT_ID"

# -----------------------------
# Host directories
# -----------------------------
echo "[*] Creating host directories..."
sudo mkdir -p \
  "$IOTLAB_DATA_ROOT/thingsboard/data" \
  "$IOTLAB_DATA_ROOT/thingsboard/logs" \
  "$IOTLAB_DATA_ROOT/mosquitto/data" \
  "$IOTLAB_DATA_ROOT/mosquitto/log" \
  "$IOTLAB_DATA_ROOT/suricata/logs" \
  "$IOTLAB_DATA_ROOT/evebox/data"

sudo mkdir -p \
  "$IOTLAB_ETC_ROOT/suricata" \
  "$IOTLAB_ETC_ROOT/mosquitto"

# -----------------------------
# Ensure docker network exists
# -----------------------------
echo "[*] Ensuring docker network exists: $IOTLAB_NET"
if docker network inspect "$IOTLAB_NET" >/dev/null 2>&1; then
  echo "    already exists"
else
  docker network create "$IOTLAB_NET" >/dev/null
  echo "    created"
fi

# -----------------------------
# Suricata: detect bridge interface + install config
# -----------------------------
# Pick a likely docker bridge interface (br-xxxx) that exists on host.
SURICATA_IFACE="${SURICATA_IFACE:-}"
if [[ -z "$SURICATA_IFACE" ]]; then
  # Choose first br-* that is UP; fallback to any br-*
  SURICATA_IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^br-' | head -n 1 || true)"
fi

if [[ -z "$SURICATA_IFACE" ]]; then
  echo "[!] Could not auto-detect a br-* interface for Suricata. Set SURICATA_IFACE in .env" >&2
  exit 1
fi
echo "[*] Suricata capture interface: $SURICATA_IFACE"

if [[ ! -f "$REPO_ROOT/configs/suricata/suricata.yaml" ]]; then
  echo "[!] Missing $REPO_ROOT/configs/suricata/suricata.yaml" >&2
  exit 1
fi

echo "[*] Installing Suricata config to $IOTLAB_ETC_ROOT/suricata/suricata.yaml"
sudo cp -f "$REPO_ROOT/configs/suricata/suricata.yaml" "$IOTLAB_ETC_ROOT/suricata/suricata.yaml"
sudo sed -i "s/br-CHANGE-ME/$SURICATA_IFACE/g" "$IOTLAB_ETC_ROOT/suricata/suricata.yaml"

# -----------------------------
# Mosquitto: install config
# -----------------------------
if [[ ! -f "$REPO_ROOT/configs/mosquitto/mosquitto.conf" ]]; then
  echo "[!] Missing $REPO_ROOT/configs/mosquitto/mosquitto.conf" >&2
  echo "    Create it and commit it, then rerun bootstrap." >&2
  exit 1
fi

echo "[*] Installing Mosquitto config to $IOTLAB_ETC_ROOT/mosquitto/mosquitto.conf"
sudo cp -f "$REPO_ROOT/configs/mosquitto/mosquitto.conf" "$IOTLAB_ETC_ROOT/mosquitto/mosquitto.conf"

# -----------------------------
# Deploy stacks as Portainer repository stacks
# -----------------------------
# NOTE: Your compose files must be repo-stack friendly:
# - All bind mounts should be absolute or use ${IOTLAB_*} roots
# - No ./relative mounts for configs (use ${IOTLAB_ETC_ROOT})
#
# Portainer repo stack payload fields (common across versions):
# Name, RepositoryURL, RepositoryReferenceName, ComposeFilePathInRepository
# Env is optional
#
deploy_repo_stack() {
  local name="$1"
  local compose_path="$2"

  echo "[*] Creating stack: $name ($compose_path)"

  local payload
  payload="$(jq -n \
    --arg Name "$name" \
    --arg RepositoryURL "$REPO_URL" \
    --arg RepositoryReferenceName "$REPO_REF" \
    --arg ComposeFilePathInRepository "$compose_path" \
    --arg IOTLAB_DATA_ROOT "$IOTLAB_DATA_ROOT" \
    --arg IOTLAB_ETC_ROOT "$IOTLAB_ETC_ROOT" \
    --arg IOTLAB_NET "$IOTLAB_NET" \
    '{
      Name: $Name,
      RepositoryURL: $RepositoryURL,
      RepositoryReferenceName: $RepositoryReferenceName,
      ComposeFilePathInRepository: $ComposeFilePathInRepository,
      Env: [
        {name:"IOTLAB_DATA_ROOT", value:$IOTLAB_DATA_ROOT},
        {name:"IOTLAB_ETC_ROOT",  value:$IOTLAB_ETC_ROOT},
        {name:"IOTLAB_NET",       value:$IOTLAB_NET}
      ]
    }')"

  http POST "$PORTAINER_URL/api/stacks/create/standalone/repository?endpointId=$ENDPOINT_ID" "$payload" >/dev/null
}

# If stacks already exist, you might want to skip or update.
# For now: create only if missing.
EXISTING="$(curl -sS "$PORTAINER_URL/api/stacks" -H "Authorization: Bearer $JWT" | jq -r '.[].Name' || true)"

for item in "${STACKS[@]}"; do
  name="${item%%:*}"
  path="${item#*:}"
  if echo "$EXISTING" | grep -qx "$name"; then
    echo "[*] Stack already exists, skipping: $name"
  else
    deploy_repo_stack "$name" "$path"
  fi
done

echo "[*] Done. Check Portainer UI for stack status."
