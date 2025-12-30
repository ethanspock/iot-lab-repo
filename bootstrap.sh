#!/usr/bin/env bash
set -euo pipefail

# ---------
# Config
# ---------
PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"

# Repo root = directory this script lives in
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Data/config roots on the target host (portable defaults)
IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"
IOTLAB_ETC_ROOT="${IOTLAB_ETC_ROOT:-/etc/iot-lab}"

# Optional: override capture interface (otherwise auto-detected from lab network)
SURICATA_IFACE="${SURICATA_IFACE:-}"

# Lab docker network name (must match your stack compose "external network" name)
LAB_NETWORK_NAME="${LAB_NETWORK_NAME:-lab-test2}"

# ---------
# Helpers
# ---------
die() { echo "[!] $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

json_post() {
  local url="$1"
  local data="$2"
  curl -fsS -X POST "$url" -H "Content-Type: application/json" -d "$data"
}

# ---------
# Preflight
# ---------
need curl
need jq
need docker

echo "[*] Repo root: $REPO_ROOT"
echo "[*] Portainer:  $PORTAINER_URL"
echo "[*] Data root:  $IOTLAB_DATA_ROOT"
echo "[*] Etc  root:  $IOTLAB_ETC_ROOT"
echo "[*] Network:    $LAB_NETWORK_NAME"

echo "[*] Waiting for Portainer API..."
until curl -fsS "$PORTAINER_URL/api/status" >/dev/null 2>&1; do sleep 2; done

PORTAINER_VER="$(curl -fsS "$PORTAINER_URL/api/status" | jq -r '.Version // "unknown"')"
echo "[*] Portainer version: $PORTAINER_VER"

# ---------
# Auth
# ---------
read -rsp "Portainer admin password: " PASS
echo

JWT="$(curl -fsS -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u admin --arg p "$PASS" '{Username:$u,Password:$p}')" \
  | jq -r .jwt)"

[[ -n "$JWT" && "$JWT" != "null" ]] || die "Login failed — ensure admin user exists (create once via Portainer UI)."

AUTH=(-H "Authorization: Bearer $JWT")

# ---------
# Detect endpointId (your last output showed local=3)
# ---------
ENDPOINT_ID="$(curl -fsS "$PORTAINER_URL/api/endpoints" "${AUTH[@]}" \
  | jq -r '.[] | select(.Name=="local") | .Id' | head -n1)"

if [[ -z "${ENDPOINT_ID:-}" || "$ENDPOINT_ID" == "null" ]]; then
  ENDPOINT_ID="$(curl -fsS "$PORTAINER_URL/api/endpoints" "${AUTH[@]}" | jq -r '.[0].Id')"
fi

[[ -n "${ENDPOINT_ID:-}" && "$ENDPOINT_ID" != "null" ]] || die "Could not detect Portainer endpointId."

echo "[*] Using endpointId: $ENDPOINT_ID"

# ---------
# Create host directories (portable)
# ---------
echo "[*] Creating host directories..."
sudo mkdir -p \
  "${IOTLAB_DATA_ROOT}/thingsboard/data" \
  "${IOTLAB_DATA_ROOT}/thingsboard/logs" \
  "${IOTLAB_DATA_ROOT}/mosquitto/data" \
  "${IOTLAB_DATA_ROOT}/mosquitto/log" \
  "${IOTLAB_DATA_ROOT}/suricata/logs" \
  "${IOTLAB_DATA_ROOT}/evebox/data" \
  "${IOTLAB_ETC_ROOT}/suricata"

# Reasonable perms for lab (tighten later if you care)
sudo chmod -R 777 "${IOTLAB_DATA_ROOT}" || true

# ---------
# Ensure docker network exists
# ---------
echo "[*] Ensuring docker network exists: $LAB_NETWORK_NAME"
if ! docker network inspect "$LAB_NETWORK_NAME" >/dev/null 2>&1; then
  docker network create "$LAB_NETWORK_NAME" >/dev/null
  echo "    created"
else
  echo "    already exists"
fi

# ---------
# Determine the linux bridge iface for the docker network (for Suricata)
# ---------
if [[ -z "$SURICATA_IFACE" ]]; then
  NET_ID="$(docker network inspect "$LAB_NETWORK_NAME" --format '{{.Id}}' | head -n1)"
  [[ -n "$NET_ID" ]] || die "Could not get network ID for $LAB_NETWORK_NAME"
  SURICATA_IFACE="br-$(echo "$NET_ID" | cut -c1-12)"
fi
echo "[*] Suricata capture interface: $SURICATA_IFACE"

# ---------
# Render Suricata config from template
# ---------
SURICATA_TEMPLATE="${REPO_ROOT}/configs/suricata/suricata.yaml"
[[ -f "$SURICATA_TEMPLATE" ]] || die "Missing $SURICATA_TEMPLATE"

echo "[*] Installing Suricata config to ${IOTLAB_ETC_ROOT}/suricata/suricata.yaml"
sudo sed "s/br-CHANGE-ME/${SURICATA_IFACE}/g" "$SURICATA_TEMPLATE" | sudo tee "${IOTLAB_ETC_ROOT}/suricata/suricata.yaml" >/dev/null

# ---------
# Stack deploy helpers (create or update)
# ---------
get_stack_id() {
  local name="$1"
  curl -fsS "$PORTAINER_URL/api/stacks" "${AUTH[@]}" \
    | jq -r --arg n "$name" '.[] | select(.Name==$n) | .Id' | head -n1
}

deploy_stack_string() {
  local name="$1"
  local compose_file="$2"
  [[ -f "$compose_file" ]] || die "Missing compose: $compose_file"

  echo "[*] Deploying stack: $name"
  local id
  id="$(get_stack_id "$name" || true)"

  if [[ -z "${id:-}" || "$id" == "null" ]]; then
    curl -fsS -X POST \
      "$PORTAINER_URL/api/stacks?type=2&method=string&endpointId=$ENDPOINT_ID" \
      "${AUTH[@]}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg n "$name" --arg c "$(cat "$compose_file")" \
        '{Name:$n, StackFileContent:$c, Env: []}')" >/dev/null
    echo "    created"
  else
    curl -fsS -X PUT \
      "$PORTAINER_URL/api/stacks/$id?endpointId=$ENDPOINT_ID" \
      "${AUTH[@]}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg c "$(cat "$compose_file")" \
        '{StackFileContent:$c, Env: [], Prune:true}')" >/dev/null
    echo "    updated (id=$id)"
  fi
}

# ---------
# Deploy stacks (order matters)
# ---------
deploy_stack_string "iot-lab-core"       "${REPO_ROOT}/stacks/iot-lab-core/docker-compose.yml"
deploy_stack_string "iot-lab-mqtt"       "${REPO_ROOT}/stacks/iot-lab-mqtt/docker-compose.yml"
deploy_stack_string "iot-lab-modbus"     "${REPO_ROOT}/stacks/iot-lab-modbus/docker-compose.yml"
deploy_stack_string "iot-lab-bacnet"     "${REPO_ROOT}/stacks/iot-lab-bacnet/docker-compose.yml"
deploy_stack_string "iot-lab-monitoring" "${REPO_ROOT}/stacks/iot-lab-monitoring/docker-compose.yml"

echo
echo "[+] Done."
echo "    Portainer UI: ${PORTAINER_URL}"
echo "    Data root:    ${IOTLAB_DATA_ROOT}"
echo "    Suricata cfg: ${IOTLAB_ETC_ROOT}/suricata/suricata.yaml"
echo
echo "Tip: To override defaults:"
echo "  PORTAINER_URL=http://127.0.0.1:9000 IOTLAB_DATA_ROOT=/opt/iot-lab IOTLAB_ETC_ROOT=/etc/iot-lab LAB_NETWORK_NAME=lab-test2 ./bootstrap.sh"
