#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# -----------------------------
# Config (override via .env)
# -----------------------------
PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"
IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"
IOTLAB_ETC_ROOT="${IOTLAB_ETC_ROOT:-/etc/iot-lab}"
IOTLAB_NET="${IOTLAB_NET:-lab-test2}"

REPO_URL="${REPO_URL:-https://github.com/ethanspock/iot-lab-repo.git}"
# IMPORTANT: Portainer often wants refs/heads/<branch>
REPO_REF="${REPO_REF:-refs/heads/main}"

# ThingsBoard (your compose maps 8081 -> 9090)
TB_HTTP="${TB_HTTP:-http://127.0.0.1:8081}"
TB_TENANT_USER="${TB_TENANT_USER:-tenant@thingsboard.org}"
TB_TENANT_PASS="${TB_TENANT_PASS:-tenant}"

# Stacks in order (repo paths)
STACK_CORE_NAME="iot-lab-core"
STACK_MQTT_NAME="iot-lab-mqtt"
STACK_MODBUS_NAME="iot-lab-modbus"
STACK_BACNET_NAME="iot-lab-bacnet"
STACK_MON_NAME="iot-lab-monitoring"

STACK_CORE_FILE="stacks/iot-lab-core/docker-compose.yml"
STACK_MQTT_FILE="stacks/iot-lab-mqtt/docker-compose.yml"
STACK_MODBUS_FILE="stacks/iot-lab-modbus/docker-compose.yml"
STACK_BACNET_FILE="stacks/iot-lab-bacnet/docker-compose.yml"
STACK_MON_FILE="stacks/iot-lab-monitoring/docker-compose.yml"

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

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[!] Missing: $1" >&2; exit 1; }; }
need_cmd curl
need_cmd jq
need_cmd docker
need_cmd ip
need_cmd sed

# -----------------------------
# Portainer helpers
# -----------------------------
http_p() {
  # usage: http_p METHOD URL [JSON_BODY]
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"
  local tmp; tmp="$(mktemp)"
  local code
  if [[ -n "$body" ]]; then
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer $PJWT" \
      -H "Content-Type: application/json" \
      -d "$body" || true)"
  else
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer $PJWT" || true)"
  fi
  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
    cat "$tmp"; rm -f "$tmp"; return 0
  fi
  echo "[!] Portainer HTTP $code: $method $url" >&2
  if [[ -s "$tmp" ]]; then
    echo "---- response body ----" >&2
    cat "$tmp" >&2
    echo "-----------------------" >&2
  fi
  rm -f "$tmp"
  return 1
}

portainer_wait() {
  echo "[*] Waiting for Portainer API..."
  until curl -fsS "$PORTAINER_URL/api/status" >/dev/null 2>&1; do sleep 2; done
  echo "[*] Portainer version: $(curl -fsS "$PORTAINER_URL/api/status" | jq -r .Version)"
}

portainer_auth() {
  read -rsp "Portainer admin password: " PASS; echo
  PJWT="$(curl -sS -X POST "$PORTAINER_URL/api/auth" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u admin --arg p "$PASS" '{Username:$u,Password:$p}')" \
    | jq -r .jwt)"
  if [[ -z "$PJWT" || "$PJWT" == "null" ]]; then
    echo "[!] Portainer login failed. Initialize admin first." >&2
    exit 1
  fi

  ENDPOINT_ID="$(curl -sS "$PORTAINER_URL/api/endpoints" -H "Authorization: Bearer $PJWT" | jq -r '.[0].Id')"
  if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "null" ]]; then
    echo "[!] Could not determine endpointId from /api/endpoints" >&2
    exit 1
  fi
  echo "[*] Using endpointId: $ENDPOINT_ID"
}

stack_id_by_name() {
  local name="$1"
  curl -sS "$PORTAINER_URL/api/stacks" -H "Authorization: Bearer $PJWT" \
    | jq -r --arg n "$name" '.[] | select(.Name==$n) | .Id' | head -n 1
}

stack_delete_if_exists() {
  local name="$1"
  local sid
  sid="$(stack_id_by_name "$name" || true)"
  if [[ -n "${sid:-}" && "$sid" != "null" ]]; then
    echo "[*] Deleting existing stack: $name (id=$sid)"
    http_p DELETE "$PORTAINER_URL/api/stacks/$sid?endpointId=$ENDPOINT_ID" >/dev/null
  fi
}

stack_create_repo() {
  local name="$1"
  local compose_path="$2"
  local env_json="$3"

  echo "[*] Creating repo stack: $name"
  echo "    ref:  $REPO_REF"
  echo "    file: $compose_path"

  local payload
  payload="$(jq -n \
    --arg Name "$name" \
    --arg RepositoryURL "$REPO_URL" \
    --arg RepositoryReferenceName "$REPO_REF" \
    --arg ComposeFilePathInRepository "$compose_path" \
    --argjson Env "$env_json" \
    '{
      Name: $Name,
      RepositoryURL: $RepositoryURL,
      RepositoryReferenceName: $RepositoryReferenceName,
      RepositoryAuthentication: false,
      ComposeFilePathInRepository: $ComposeFilePathInRepository,
      Env: $Env
    }')"

  http_p POST "$PORTAINER_URL/api/stacks/create/standalone/repository?endpointId=$ENDPOINT_ID" "$payload" >/dev/null
}

# -----------------------------
# ThingsBoard helpers
# -----------------------------
tb_wait() {
  echo "[*] Waiting for ThingsBoard API at $TB_HTTP ..."
  until curl -fsS "$TB_HTTP/api/health" >/dev/null 2>&1; do sleep 3; done
  echo "[*] ThingsBoard is reachable"
}

tb_login() {
  echo "[*] Logging into ThingsBoard as tenant admin: $TB_TENANT_USER"
  TB_JWT="$(curl -sS -X POST "$TB_HTTP/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$TB_TENANT_USER" --arg p "$TB_TENANT_PASS" '{username:$u,password:$p}')" \
    | jq -r .token)"
  if [[ -z "$TB_JWT" || "$TB_JWT" == "null" ]]; then
    echo "[!] ThingsBoard login failed. Check TB is up and creds are correct." >&2
    exit 1
  fi
}

tb_get_or_create_device_id() {
  local dev_name="$1"
  local dev_type="$2"

  # Try lookup by name
  local id
  id="$(curl -sS "$TB_HTTP/api/tenant/devices?deviceName=$(python3 - <<PY
import urllib.parse; print(urllib.parse.quote("$dev_name"))
PY
)" -H "X-Authorization: Bearer $TB_JWT" | jq -r '.id.id // empty' || true)"

  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi

  # Create
  id="$(curl -sS -X POST "$TB_HTTP/api/device" \
    -H "Content-Type: application/json" \
    -H "X-Authorization: Bearer $TB_JWT" \
    -d "$(jq -n --arg n "$dev_name" --arg t "$dev_type" '{name:$n,type:$t}')" \
    | jq -r '.id.id')"

  if [[ -z "$id" || "$id" == "null" ]]; then
    echo "[!] Failed to create device: $dev_name" >&2
    exit 1
  fi
  echo "$id"
}

tb_get_token_for_device() {
  local dev_id="$1"
  local token
  token="$(curl -sS "$TB_HTTP/api/device/$dev_id/credentials" \
    -H "X-Authorization: Bearer $TB_JWT" | jq -r '.credentialsId')"
  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "[!] Failed to read credentials for deviceId=$dev_id" >&2
    exit 1
  fi
  echo "$token"
}

# -----------------------------
# Host setup (dirs + configs + net)
# -----------------------------
echo "[*] Repo root: $REPO_ROOT"

portainer_wait
portainer_auth

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

echo "[*] Ensuring docker network exists: $IOTLAB_NET"
docker network inspect "$IOTLAB_NET" >/dev/null 2>&1 || docker network create "$IOTLAB_NET" >/dev/null
echo "    ok"

# Suricata iface + config
SURICATA_IFACE="${SURICATA_IFACE:-}"
if [[ -z "$SURICATA_IFACE" ]]; then
  SURICATA_IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^br-' | head -n 1 || true)"
fi
if [[ -z "$SURICATA_IFACE" ]]; then
  echo "[!] Could not auto-detect br-* interface. Set SURICATA_IFACE in .env" >&2
  exit 1
fi
echo "[*] Suricata capture interface: $SURICATA_IFACE"

echo "[*] Installing Suricata config -> $IOTLAB_ETC_ROOT/suricata/suricata.yaml"
sudo cp -f "$REPO_ROOT/configs/suricata/suricata.yaml" "$IOTLAB_ETC_ROOT/suricata/suricata.yaml"
sudo sed -i "s/br-CHANGE-ME/$SURICATA_IFACE/g" "$IOTLAB_ETC_ROOT/suricata/suricata.yaml"

# Mosquitto config
if [[ ! -f "$REPO_ROOT/configs/mosquitto/mosquitto.conf" ]]; then
  echo "[!] Missing $REPO_ROOT/configs/mosquitto/mosquitto.conf" >&2
  echo "    Create it (I gave you the content) then rerun." >&2
  exit 1
fi
echo "[*] Installing Mosquitto config -> $IOTLAB_ETC_ROOT/mosquitto/mosquitto.conf"
sudo cp -f "$REPO_ROOT/configs/mosquitto/mosquitto.conf" "$IOTLAB_ETC_ROOT/mosquitto/mosquitto.conf"

# -----------------------------
# Deploy core FIRST so TB is up (or recreate it cleanly)
# -----------------------------
ENV_BASE="$(jq -n \
  --arg d "$IOTLAB_DATA_ROOT" --arg e "$IOTLAB_ETC_ROOT" --arg n "$IOTLAB_NET" \
  '[
    {name:"IOTLAB_DATA_ROOT", value:$d},
    {name:"IOTLAB_ETC_ROOT",  value:$e},
    {name:"IOTLAB_NET",       value:$n}
  ]')"

# Ensure core exists (create if missing)
CORE_ID="$(stack_id_by_name "$STACK_CORE_NAME" || true)"
if [[ -z "$CORE_ID" || "$CORE_ID" == "null" ]]; then
  echo "[*] Deploying core stack first: $STACK_CORE_NAME"
  stack_create_repo "$STACK_CORE_NAME" "$STACK_CORE_FILE" "$ENV_BASE"
else
  echo "[*] Core stack already exists (id=$CORE_ID)"
fi

# -----------------------------
# Create TB gateway devices + pull tokens
# -----------------------------
tb_wait
tb_login

echo "[*] Ensuring gateway devices exist and pulling tokens..."
CORE_GW_ID="$(tb_get_or_create_device_id "core-gateway" "gateway")"
WIND_GW_ID="$(tb_get_or_create_device_id "windfarm-gateway" "gateway")"
NUKE_GW_ID="$(tb_get_or_create_device_id "nuke-gateway" "gateway")"

TB_GATEWAY_TOKEN_CORE="$(tb_get_token_for_device "$CORE_GW_ID")"
TB_GATEWAY_TOKEN_WINDFARM="$(tb_get_token_for_device "$WIND_GW_ID")"
TB_GATEWAY_TOKEN_NUKE="$(tb_get_token_for_device "$NUKE_GW_ID")"

echo "[*] Writing tokens to .env.generated (DO NOT COMMIT)"
cat > "$REPO_ROOT/.env.generated" <<EOF
TB_GATEWAY_TOKEN_CORE=$TB_GATEWAY_TOKEN_CORE
TB_GATEWAY_TOKEN_WINDFARM=$TB_GATEWAY_TOKEN_WINDFARM
TB_GATEWAY_TOKEN_NUKE=$TB_GATEWAY_TOKEN_NUKE
EOF

# -----------------------------
# Recreate stacks that REQUIRE tokens (core/modbus/bacnet)
# -----------------------------
ENV_WITH_TOKENS="$(jq -n \
  --arg d "$IOTLAB_DATA_ROOT" --arg e "$IOTLAB_ETC_ROOT" --arg n "$IOTLAB_NET" \
  --arg t1 "$TB_GATEWAY_TOKEN_CORE" \
  --arg t2 "$TB_GATEWAY_TOKEN_WINDFARM" \
  --arg t3 "$TB_GATEWAY_TOKEN_NUKE" \
  '[
    {name:"IOTLAB_DATA_ROOT", value:$d},
    {name:"IOTLAB_ETC_ROOT",  value:$e},
    {name:"IOTLAB_NET",       value:$n},
    {name:"TB_GATEWAY_TOKEN_CORE", value:$t1},
    {name:"TB_GATEWAY_TOKEN_WINDFARM", value:$t2},
    {name:"TB_GATEWAY_TOKEN_NUKE", value:$t3}
  ]')"

# Hard reset ONLY stacks that need tokens (and re-create them with Env)
stack_delete_if_exists "$STACK_CORE_NAME"
stack_delete_if_exists "$STACK_MODBUS_NAME"
stack_delete_if_exists "$STACK_BACNET_NAME"

echo "[*] Recreating token-dependent stacks..."
stack_create_repo "$STACK_CORE_NAME"   "$STACK_CORE_FILE"   "$ENV_WITH_TOKENS"
stack_create_repo "$STACK_MODBUS_NAME" "$STACK_MODBUS_FILE" "$ENV_WITH_TOKENS"
stack_create_repo "$STACK_BACNET_NAME" "$STACK_BACNET_FILE" "$ENV_WITH_TOKENS"

# Remaining stacks
MQTT_ID="$(stack_id_by_name "$STACK_MQTT_NAME" || true)"
if [[ -z "$MQTT_ID" || "$MQTT_ID" == "null" ]]; then
  stack_create_repo "$STACK_MQTT_NAME" "$STACK_MQTT_FILE" "$ENV_BASE"
else
  echo "[*] Stack already exists, skipping: $STACK_MQTT_NAME"
fi

MON_ID="$(stack_id_by_name "$STACK_MON_NAME" || true)"
if [[ -z "$MON_ID" || "$MON_ID" == "null" ]]; then
  stack_create_repo "$STACK_MON_NAME" "$STACK_MON_FILE" "$ENV_BASE"
else
  echo "[*] Stack already exists, skipping: $STACK_MON_NAME"
fi

echo "[*] DONE."
echo "    - Tokens saved to: $REPO_ROOT/.env.generated"
echo "    - Open ThingsBoard UI and you should see gateway devices + telemetry shortly."
