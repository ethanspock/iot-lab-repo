#!/usr/bin/env bash
set -euo pipefail

PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"
IOTLAB_ETC_ROOT="${IOTLAB_ETC_ROOT:-/etc/iot-lab}"

LAB_NETWORK_NAME="${LAB_NETWORK_NAME:-lab-test2}"
SURICATA_IFACE="${SURICATA_IFACE:-}"

die(){ echo "[!] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

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
echo "[*] Portainer version: $(curl -fsS "$PORTAINER_URL/api/status" | jq -r '.Version // "unknown"')"

read -rsp "Portainer admin password: " PASS; echo
JWT="$(curl -fsS -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"Username\":\"admin\",\"Password\":\"$PASS\"}" | jq -r .jwt)"
[[ -n "$JWT" && "$JWT" != "null" ]] || die "Login failed."

ENDPOINT_ID="$(curl -fsS "$PORTAINER_URL/api/endpoints" -H "Authorization: Bearer $JWT" \
  | jq -r '.[] | select(.Name=="local") | .Id' | head -n1)"
[[ -n "$ENDPOINT_ID" && "$ENDPOINT_ID" != "null" ]] || die "Could not find endpointId."
echo "[*] Using endpointId: $ENDPOINT_ID"

# -----------------------
# Load env (.env preferred)
# -----------------------
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  [[ -f "$REPO_ROOT/env.example" ]] || die "Missing .env and env.example. Create one."
  echo "[*] No .env found; using env.example (you should copy it to .env)"
  ENV_FILE="$REPO_ROOT/env.example"
fi
echo "[*] Using env file: $ENV_FILE"

# Parse env file into Portainer Env array [{name,value}]
# - ignores comments/blank lines
# - supports KEY=VALUE
# - strips surrounding quotes
ENV_JSON="$(awk '
  BEGIN{print "["; first=1}
  /^[[:space:]]*#/ {next}
  /^[[:space:]]*$/ {next}
  {
    line=$0
    sub(/^[[:space:]]*/, "", line)
    sub(/[[:space:]]*$/, "", line)
    split(line, a, "=")
    key=a[1]
    sub(/^[[:space:]]*/, "", key); sub(/[[:space:]]*$/, "", key)
    val=substr(line, index(line, "=")+1)
    sub(/^[[:space:]]*/, "", val); sub(/[[:space:]]*$/, "", val)
    # strip surrounding quotes
    if (val ~ /^".*"$/) { sub(/^"/,"",val); sub(/"$/,"",val) }
    if (val ~ /^\047.*\047$/) { sub(/^\047/,"",val); sub(/\047$/,"",val) }
    if (first==0) print ","
    first=0
    gsub(/\\/,"\\\\",val); gsub(/"/,"\\\"",val)
    printf "{\"name\":\"%s\",\"value\":\"%s\"}", key, val
  }
  END{print "]"}
' "$ENV_FILE")"

# -----------------------
# Host dirs
# -----------------------
echo "[*] Creating host directories..."
sudo mkdir -p \
  "${IOTLAB_DATA_ROOT}/thingsboard/data" \
  "${IOTLAB_DATA_ROOT}/thingsboard/logs" \
  "${IOTLAB_DATA_ROOT}/mosquitto/data" \
  "${IOTLAB_DATA_ROOT}/mosquitto/log" \
  "${IOTLAB_DATA_ROOT}/suricata/logs" \
  "${IOTLAB_DATA_ROOT}/evebox/data" \
  "${IOTLAB_ETC_ROOT}/suricata"
sudo chmod -R 777 "${IOTLAB_DATA_ROOT}" || true

# -----------------------
# Ensure docker network
# -----------------------
echo "[*] Ensuring docker network exists: $LAB_NETWORK_NAME"
if ! docker network inspect "$LAB_NETWORK_NAME" >/dev/null 2>&1; then
  docker network create "$LAB_NETWORK_NAME" >/dev/null
  echo "    created"
else
  echo "    already exists"
fi

# -----------------------
# Determine Suricata iface
# -----------------------
if [[ -z "$SURICATA_IFACE" ]]; then
  NET_ID="$(docker network inspect "$LAB_NETWORK_NAME" --format '{{.Id}}' | head -n1)"
  [[ -n "$NET_ID" ]] || die "Could not get network ID for $LAB_NETWORK_NAME"
  SURICATA_IFACE="br-$(echo "$NET_ID" | cut -c1-12)"
fi
echo "[*] Suricata capture interface: $SURICATA_IFACE"

SURICATA_TEMPLATE="$REPO_ROOT/configs/suricata/suricata.yaml"
[[ -f "$SURICATA_TEMPLATE" ]] || die "Missing $SURICATA_TEMPLATE"

echo "[*] Installing Suricata config to ${IOTLAB_ETC_ROOT}/suricata/suricata.yaml"
sudo sed "s/br-CHANGE-ME/${SURICATA_IFACE}/g" "$SURICATA_TEMPLATE" \
  | sudo tee "${IOTLAB_ETC_ROOT}/suricata/suricata.yaml" >/dev/null

# -----------------------
# Portainer stack deploy
# -----------------------
list_stacks() {
  curl -fsS "$PORTAINER_URL/api/stacks" -H "Authorization: Bearer $JWT"
}

get_stack_id() {
  local name="$1"
  list_stacks | jq -r --arg n "$name" '.[] | select(.Name==$n) | .Id' | head -n1
}

remove_stack_if_exists() {
  local name="$1"
  local id
  id="$(get_stack_id "$name" || true)"
  if [[ -n "${id:-}" && "$id" != "null" ]]; then
    echo "    removing existing stack $name (id=$id)"
    curl -fsS -X DELETE \
      "$PORTAINER_URL/api/stacks/$id?endpointId=$ENDPOINT_ID" \
      -H "Authorization: Bearer $JWT" >/dev/null
  fi
}

create_stack_string() {
  local name="$1"
  local compose_file="$2"
  [[ -f "$compose_file" ]] || die "Missing compose: $compose_file"

  # Compose content
  local content
  content="$(cat "$compose_file")"

  # Payload for create/standalone/string
  local payload
  payload="$(jq -n \
    --arg n "$name" \
    --arg c "$content" \
    --argjson env "$ENV_JSON" \
    '{Name:$n, StackFileContent:$c, Env:$env}')"

  # Correct endpoint for your Portainer (we confirmed this works)
  curl -fsS -X POST \
    "$PORTAINER_URL/api/stacks/create/standalone/string?endpointId=$ENDPOINT_ID" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null
}

deploy_stack() {
  local name="$1"
  local compose_file="$2"
  echo "[*] Deploying stack: $name"
  remove_stack_if_exists "$name"
  create_stack_string "$name" "$compose_file"
  echo "    created"
}

# Deploy in order
deploy_stack "iot-lab-core"       "$REPO_ROOT/stacks/iot-lab-core/docker-compose.yml"
deploy_stack "iot-lab-mqtt"       "$REPO_ROOT/stacks/iot-lab-mqtt/docker-compose.yml"
deploy_stack "iot-lab-modbus"     "$REPO_ROOT/stacks/iot-lab-modbus/docker-compose.yml"
deploy_stack "iot-lab-bacnet"     "$REPO_ROOT/stacks/iot-lab-bacnet/docker-compose.yml"
deploy_stack "iot-lab-monitoring" "$REPO_ROOT/stacks/iot-lab-monitoring/docker-compose.yml"

echo
echo "[+] Done."
echo "    Portainer UI: ${PORTAINER_URL}"
echo "    EndpointId:   ${ENDPOINT_ID}"
echo "    Env file:     ${ENV_FILE}"
echo "    Data root:    ${IOTLAB_DATA_ROOT}"
echo "    Suricata cfg: ${IOTLAB_ETC_ROOT}/suricata/suricata.yaml"
