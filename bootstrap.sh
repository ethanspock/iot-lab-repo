#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[*] Repo root: $REPO_ROOT"

PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"
IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"
IOTLAB_ETC_ROOT="${IOTLAB_ETC_ROOT:-/etc/iot-lab}"
IOTLAB_NET="${IOTLAB_NET:-lab-test2}"

REPO_URL="${REPO_URL:-https://github.com/ethanspock/iot-lab-repo.git}"
REPO_REF="${REPO_REF:-refs/heads/main}"

# ThingsBoard HTTP (inside lab network)
TB_HTTP_HOST="${TB_HTTP_HOST:-thingsboard}"
TB_HTTP_PORT="${TB_HTTP_PORT:-9090}"
TB_BASE_URL="http://${TB_HTTP_HOST}:${TB_HTTP_PORT}"

# Tenant admin creds (override in .env)
TB_TENANT_USER="${TB_TENANT_USER:-tenant@thingsboard.org}"
TB_TENANT_PASS="${TB_TENANT_PASS:-tenant}"

# Device names to create (gateway devices)
TB_GW_CORE_NAME="${TB_GW_CORE_NAME:-TB-GW-CORE}"
TB_GW_WINDFARM_NAME="${TB_GW_WINDFARM_NAME:-TB-GW-WINDFARM}"
TB_GW_NUKE_NAME="${TB_GW_NUKE_NAME:-TB-GW-NUKE}"

STACK_CORE_NAME="iot-lab-core"
STACK_CORE_PATH="stacks/iot-lab-core/docker-compose.yml"

STACKS_AFTER_TOKENS=(
  "iot-lab-mqtt:stacks/iot-lab-mqtt/docker-compose.yml"
  "iot-lab-modbus:stacks/iot-lab-modbus/docker-compose.yml"
  "iot-lab-bacnet:stacks/iot-lab-bacnet/docker-compose.yml"
  "iot-lab-monitoring:stacks/iot-lab-monitoring/docker-compose.yml"
)

# Load .env if present
if [[ -f "$REPO_ROOT/.env" ]]; then
  echo "[*] Loading .env"
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

# Normalize REPO_REF for Portainer: "refs/heads/main" -> "main"
if [[ "${REPO_REF}" == refs/heads/* ]]; then
  REPO_REF_BRANCH="${REPO_REF#refs/heads/}"
else
  REPO_REF_BRANCH="$REPO_REF"
fi


need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[!] Missing: $1" >&2; exit 1; }; }
need_cmd curl
need_cmd jq
need_cmd docker
need_cmd ip
need_cmd sed
need_cmd awk
need_cmd sudo

http_portainer() {
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"

  local tmp code
  tmp="$(mktemp)"

  if [[ -n "$body" ]]; then
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer $PORTAINER_JWT" \
      -H "Content-Type: application/json" \
      -d "$body" || true)"
  else
    code="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer $PORTAINER_JWT" || true)"
  fi

  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
    cat "$tmp"; rm -f "$tmp"; return 0
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

# --- Wait for Portainer ---
echo "[*] Waiting for Portainer API..."
until curl -fsS "$PORTAINER_URL/api/status" >/dev/null; do sleep 2; done
VER="$(curl -fsS "$PORTAINER_URL/api/status" | jq -r .Version)"
echo "[*] Portainer version: $VER"

# --- Portainer Auth ---
read -rsp "Portainer admin password: " PASS
echo

PORTAINER_JWT="$(curl -sS -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u admin --arg p "$PASS" '{Username:$u,Password:$p}')" \
  | jq -r .jwt)"

if [[ -z "$PORTAINER_JWT" || "$PORTAINER_JWT" == "null" ]]; then
  echo "[!] Portainer login failed. Initialize admin via UI or /api/users/admin/init first." >&2
  exit 1
fi

# Determine endpointId (local docker)
ENDPOINT_ID="$(curl -sS "$PORTAINER_URL/api/endpoints" -H "Authorization: Bearer $PORTAINER_JWT" | jq -r '.[0].Id')"
if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "null" ]]; then
  echo "[!] Could not determine endpointId from /api/endpoints" >&2
  exit 1
fi
echo "[*] Using endpointId: $ENDPOINT_ID"

# --- Host dirs ---
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

# --- Ensure docker network exists ---
echo "[*] Ensuring docker network exists: $IOTLAB_NET"
if docker network inspect "$IOTLAB_NET" >/dev/null 2>&1; then
  echo "    already exists"
else
  docker network create "$IOTLAB_NET" >/dev/null
  echo "    created"
fi

# --- Suricata config install ---
SURICATA_IFACE="${SURICATA_IFACE:-}"
if [[ -z "$SURICATA_IFACE" ]]; then
  SURICATA_IFACE="$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^br-' | head -n 1 || true)"
fi
if [[ -z "$SURICATA_IFACE" ]]; then
  echo "[!] Could not auto-detect br-* interface for Suricata. Set SURICATA_IFACE in .env" >&2
  exit 1
fi
echo "[*] Suricata capture interface: $SURICATA_IFACE"

sudo cp -f "$REPO_ROOT/configs/suricata/suricata.yaml" "$IOTLAB_ETC_ROOT/suricata/suricata.yaml"
sudo sed -i "s/br-CHANGE-ME/$SURICATA_IFACE/g" "$IOTLAB_ETC_ROOT/suricata/suricata.yaml"

# --- Mosquitto config install (host absolute path expected) ---
if [[ ! -f "$REPO_ROOT/configs/mosquitto/mosquitto.conf" ]]; then
  echo "[!] Missing $REPO_ROOT/configs/mosquitto/mosquitto.conf" >&2
  exit 1
fi
sudo cp -f "$REPO_ROOT/configs/mosquitto/mosquitto.conf" "$IOTLAB_ETC_ROOT/mosquitto/mosquitto.conf"

# --- Create repo stack in Portainer ---
create_repo_stack() {
  local name="$1"
  local compose_path="$2"
  shift 2

  # remaining args are Env entries "NAME=VALUE"
  local env_json="[]"
  while [[ $# -gt 0 ]]; do
    local kv="$1"; shift
    local k="${kv%%=*}"
    local v="${kv#*=}"
    env_json="$(jq -c --arg k "$k" --arg v "$v" '. + [{name:$k, value:$v}]' <<<"$env_json")"
  done

  # Portainer is annoyingly inconsistent across versions:
  # - some use ComposeFilePathInRepository
  # - some use ComposeFile
  # - some need branch name not refs/heads/*
  #
  # We include BOTH keys, and we normalize the ref.
  local payload
  payload="$(jq -n \
    --arg Name "$name" \
    --arg RepositoryURL "$REPO_URL" \
    --arg RepositoryReferenceName "$REPO_REF_BRANCH" \
    --arg ComposePath "$compose_path" \
    --argjson Env "$env_json" \
    '{
      Name: $Name,
      RepositoryURL: $RepositoryURL,
      RepositoryReferenceName: $RepositoryReferenceName,
      RepositoryAuthentication: false,
      # Send both keys to handle Portainer schema differences
      ComposeFilePathInRepository: $ComposePath,
      ComposeFile: $ComposePath,
      Env: $Env
    }')"

  echo "[*] Creating repo stack via Portainer: $name"
  echo "    ref:   $REPO_REF_BRANCH"
  echo "    file:  $compose_path"

  # Create
  if ! http_portainer POST "$PORTAINER_URL/api/stacks/create/standalone/repository?endpointId=$ENDPOINT_ID" "$payload" >/dev/null; then
    echo "[!] Failed to create stack '$name'. Debug payload:" >&2
    echo "$payload" | jq . >&2 || true
    return 1
  fi
}

# --- Deploy ThingsBoard core FIRST ---
echo "[*] Deploying core stack first: $STACK_CORE_NAME"
if stack_exists "$STACK_CORE_NAME"; then
  echo "    already exists (skipping create)"
else
  create_repo_stack "$STACK_CORE_NAME" "$STACK_CORE_PATH" \
    "IOTLAB_DATA_ROOT=$IOTLAB_DATA_ROOT" \
    "IOTLAB_ETC_ROOT=$IOTLAB_ETC_ROOT" \
    "IOTLAB_NET=$IOTLAB_NET"
fi

# --- Wait for ThingsBoard HTTP to be reachable (via docker network) ---
# We exec a curl from a temp container attached to the lab network to avoid host/port confusion.
echo "[*] Waiting for ThingsBoard API at $TB_BASE_URL ..."
until docker run --rm --network "$IOTLAB_NET" curlimages/curl:8.7.1 -fsS "$TB_BASE_URL" >/dev/null 2>&1; do
  sleep 3
done
echo "[*] ThingsBoard is reachable"

# --- ThingsBoard REST helpers (run curls from inside network) ---
tb_api() {
  local method="$1"; shift
  local path="$1"; shift
  local body="${1:-}"

  if [[ -n "$body" ]]; then
    docker run --rm --network "$IOTLAB_NET" curlimages/curl:8.7.1 -sS \
      -X "$method" "$TB_BASE_URL$path" \
      -H "Content-Type: application/json" \
      -H "X-Authorization: Bearer $TB_JWT" \
      -d "$body"
  else
    docker run --rm --network "$IOTLAB_NET" curlimages/curl:8.7.1 -sS \
      -X "$method" "$TB_BASE_URL$path" \
      -H "X-Authorization: Bearer $TB_JWT"
  fi
}

# --- TB Login ---
echo "[*] Logging into ThingsBoard as tenant admin: $TB_TENANT_USER"
TB_JWT="$(docker run --rm --network "$IOTLAB_NET" curlimages/curl:8.7.1 -sS \
  -X POST "$TB_BASE_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$TB_TENANT_USER" --arg p "$TB_TENANT_PASS" '{username:$u,password:$p}')" \
  | jq -r .token)"

if [[ -z "$TB_JWT" || "$TB_JWT" == "null" ]]; then
  echo "[!] ThingsBoard login failed. Set TB_TENANT_USER/TB_TENANT_PASS in .env" >&2
  exit 1
fi

# --- Create or find device by name; return deviceId ---
tb_get_device_id_by_name() {
  local name="$1"
  # Search via text search endpoint
  tb_api GET "/api/tenant/devices?deviceName=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$name'''))")" \
    | jq -r '.id.id // empty' 2>/dev/null || true
}

tb_create_device() {
  local name="$1"
  tb_api POST "/api/device" "$(jq -n --arg n "$name" '{name:$n,type:"gateway"}')" | jq -r '.id.id'
}

tb_get_or_create_device_id() {
  local name="$1"
  local id
  id="$(tb_get_device_id_by_name "$name" || true)"
  if [[ -n "$id" ]]; then
    echo "$id"
    return 0
  fi
  tb_create_device "$name"
}

# --- Get device token (credentialsId) ---
tb_get_device_token() {
  local id="$1"
  tb_api GET "/api/device/$id/credentials" | jq -r '.credentialsId'
}

echo "[*] Ensuring gateway devices exist and pulling tokens..."
CORE_ID="$(tb_get_or_create_device_id "$TB_GW_CORE_NAME")"
WINDFARM_ID="$(tb_get_or_create_device_id "$TB_GW_WINDFARM_NAME")"
NUKE_ID="$(tb_get_or_create_device_id "$TB_GW_NUKE_NAME")"

TB_GATEWAY_TOKEN_CORE="$(tb_get_device_token "$CORE_ID")"
TB_GATEWAY_TOKEN_WINDFARM="$(tb_get_device_token "$WINDFARM_ID")"
TB_GATEWAY_TOKEN_NUKE="$(tb_get_device_token "$NUKE_ID")"

if [[ -z "$TB_GATEWAY_TOKEN_CORE" || -z "$TB_GATEWAY_TOKEN_WINDFARM" || -z "$TB_GATEWAY_TOKEN_NUKE" ]]; then
  echo "[!] Failed to retrieve one or more device tokens from ThingsBoard" >&2
  exit 1
fi

echo "[*] Writing tokens to .env.generated (gitignore this)"
cat > "$REPO_ROOT/.env.generated" <<EOF
# Generated by bootstrap.sh - do not commit
TB_GATEWAY_TOKEN_CORE=$TB_GATEWAY_TOKEN_CORE
TB_GATEWAY_TOKEN_WINDFARM=$TB_GATEWAY_TOKEN_WINDFARM
TB_GATEWAY_TOKEN_NUKE=$TB_GATEWAY_TOKEN_NUKE
EOF

# --- Deploy remaining stacks with tokens injected ---
for item in "${STACKS_AFTER_TOKENS[@]}"; do
  name="${item%%:*}"
  path="${item#*:}"
  echo "[*] Deploying stack: $name"
  if stack_exists "$name"; then
    echo "    already exists (skipping create)"
    continue
  fi

  create_repo_stack "$name" "$path" \
    "IOTLAB_DATA_ROOT=$IOTLAB_DATA_ROOT" \
    "IOTLAB_ETC_ROOT=$IOTLAB_ETC_ROOT" \
    "IOTLAB_NET=$IOTLAB_NET" \
    "TB_GATEWAY_TOKEN_CORE=$TB_GATEWAY_TOKEN_CORE" \
    "TB_GATEWAY_TOKEN_WINDFARM=$TB_GATEWAY_TOKEN_WINDFARM" \
    "TB_GATEWAY_TOKEN_NUKE=$TB_GATEWAY_TOKEN_NUKE"
done

echo "[*] Done. Tokens saved in .env.generated. Stacks deployed."
