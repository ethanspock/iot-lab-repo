#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Config (override via .env)
# ------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[*] Repo root: $REPO_ROOT"

PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"

IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"
IOTLAB_ETC_ROOT="${IOTLAB_ETC_ROOT:-/etc/iot-lab}"
IOTLAB_NET="${IOTLAB_NET:-lab-test2}"

# Portainer "repository stack" deploy settings
REPO_URL="${REPO_URL:-https://github.com/ethanspock/iot-lab-repo.git}"
REPO_REF="${REPO_REF:-refs/heads/main}"        # we'll normalize to "main"

# Behavior:
# 0 = skip existing stacks
# 1 = update existing stacks via Portainer API
UPDATE_EXISTING="${UPDATE_EXISTING:-0}"

# Stacks in order (core first)
STACKS=(
  "iot-lab-core:stacks/iot-lab-core/docker-compose.yml"
  "iot-lab-mqtt:stacks/iot-lab-mqtt/docker-compose.yml"
  "iot-lab-modbus:stacks/iot-lab-modbus/docker-compose.yml"
  "iot-lab-bacnet:stacks/iot-lab-bacnet/docker-compose.yml"
  "iot-lab-monitoring:stacks/iot-lab-monitoring/docker-compose.yml"
)

# ------------------------------------------------------------
# Load .env + .env.generated if present
# ------------------------------------------------------------
load_env_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    echo "[*] Loading $(basename "$f")"
    set -a
    # shellcheck disable=SC1090
    source "$f"
    set +a
  fi
}
load_env_file "$REPO_ROOT/.env"
load_env_file "$REPO_ROOT/.env.generated"

# Normalize REPO_REF for Portainer: "refs/heads/main" -> "main"
if [[ "${REPO_REF}" == refs/heads/* ]]; then
  REPO_REF_BRANCH="${REPO_REF#refs/heads/}"
else
  REPO_REF_BRANCH="$REPO_REF"
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[!] Missing: $1" >&2; exit 1; }; }

# Portainer HTTP helper with better errors
http_portainer() {
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"

  local tmp code
  tmp="$(mktemp)"

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

get_stack_id_by_name() {
  local name="$1"
  curl -sS "$PORTAINER_URL/api/stacks" -H "Authorization: Bearer $JWT" \
    | jq -r --arg n "$name" '.[] | select(.Name==$n) | .Id' \
    | head -n 1
}

stack_exists() {
  local name="$1"
  local id
  id="$(get_stack_id_by_name "$name")"
  [[ -n "$id" && "$id" != "null" ]]
}

# ------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------
need_cmd curl
need_cmd jq
need_cmd docker
need_cmd ip
need_cmd sed
need_cmd awk
need_cmd sudo

# ------------------------------------------------------------
# Wait for Portainer + auth
# ------------------------------------------------------------
echo "[*] Waiting for Portainer API..."
until curl -fsS "$PORTAINER_URL/api/status" >/dev/null; do sleep 2; done
VER="$(curl -fsS "$PORTAINER_URL/api/status" | jq -r .Version)"
echo "[*] Portainer version: $VER"

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

# Determine endpointId (local docker environment)
ENDPOINT_ID="$(curl -sS "$PORTAINER_URL/api/endpoints" -H "Authorization: Bearer $JWT" \
  | jq -r '.[0].Id')"

if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "null" ]]; then
  echo "[!] Could not determine endpointId from /api/endpoints" >&2
  exit 1
fi
echo "[*] Using endpointId: $ENDPOINT_ID"

# ------------------------------------------------------------
# Host dirs + network
# ------------------------------------------------------------
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
if docker network inspect "$IOTLAB_NET" >/dev/null 2>&1; then
  echo "    already exists"
else
  docker network create "$IOTLAB_NET" >/dev/null
  echo "    created"
fi

# ------------------------------------------------------------
# Suricata: detect bridge interface + install config
# ------------------------------------------------------------
SURICATA_IFACE="${SURICATA_IFACE:-}"
if [[ -z "$SURICATA_IFACE" ]]; then
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

echo "[*] Installing Suricata config -> $IOTLAB_ETC_ROOT/suricata/suricata.yaml"
sudo cp -f "$REPO_ROOT/configs/suricata/suricata.yaml" "$IOTLAB_ETC_ROOT/suricata/suricata.yaml"
sudo sed -i "s/br-CHANGE-ME/$SURICATA_IFACE/g" "$IOTLAB_ETC_ROOT/suricata/suricata.yaml"

# Mosquitto config must exist in repo
if [[ ! -f "$REPO_ROOT/configs/mosquitto/mosquitto.conf" ]]; then
  echo "[!] Missing $REPO_ROOT/configs/mosquitto/mosquitto.conf" >&2
  echo "    Create it, commit it, then rerun bootstrap." >&2
  exit 1
fi

echo "[*] Installing Mosquitto config -> $IOTLAB_ETC_ROOT/mosquitto/mosquitto.conf"
sudo cp -f "$REPO_ROOT/configs/mosquitto/mosquitto.conf" "$IOTLAB_ETC_ROOT/mosquitto/mosquitto.conf"

# ------------------------------------------------------------
# Portainer stack create/update (repo stacks)
# ------------------------------------------------------------
create_repo_stack() {
  local name="$1"
  local compose_path="$2"

  local payload
  payload="$(jq -n \
    --arg Name "$name" \
    --arg RepositoryURL "$REPO_URL" \
    --arg RepositoryReferenceName "$REPO_REF_BRANCH" \
    --arg ComposePath "$compose_path" \
    --arg IOTLAB_DATA_ROOT "$IOTLAB_DATA_ROOT" \
    --arg IOTLAB_ETC_ROOT "$IOTLAB_ETC_ROOT" \
    --arg IOTLAB_NET "$IOTLAB_NET" \
    '{
      Name: $Name,
      RepositoryURL: $RepositoryURL,
      RepositoryReferenceName: $RepositoryReferenceName,
      RepositoryAuthentication: false,
      ComposeFilePathInRepository: $ComposePath,
      ComposeFile: $ComposePath,
      Env: [
        {name:"IOTLAB_DATA_ROOT", value:$IOTLAB_DATA_ROOT},
        {name:"IOTLAB_ETC_ROOT",  value:$IOTLAB_ETC_ROOT},
        {name:"IOTLAB_NET",       value:$IOTLAB_NET}
      ]
    }')"

  echo "[*] Creating repo stack via Portainer: $name"
  echo "    ref:   $REPO_REF_BRANCH"
  echo "    file:  $compose_path"

  http_portainer POST "$PORTAINER_URL/api/stacks/create/standalone/repository?endpointId=$ENDPOINT_ID" "$payload" >/dev/null
}

update_repo_stack() {
  local name="$1"
  local compose_path="$2"

  local id
  id="$(get_stack_id_by_name "$name")"
  if [[ -z "$id" || "$id" == "null" ]]; then
    echo "[!] Can't update '$name' because it doesn't exist." >&2
    return 1
  fi

  # Update endpoint: PUT /api/stacks/{id}/git?endpointId=X
  # payload keys are usually: RepositoryReferenceName + Env + AutoUpdate (optional)
  local payload
  payload="$(jq -n \
    --arg RepositoryReferenceName "$REPO_REF_BRANCH" \
    --arg IOTLAB_DATA_ROOT "$IOTLAB_DATA_ROOT" \
    --arg IOTLAB_ETC_ROOT "$IOTLAB_ETC_ROOT" \
    --arg IOTLAB_NET "$IOTLAB_NET" \
    '{
      RepositoryReferenceName: $RepositoryReferenceName,
      Env: [
        {name:"IOTLAB_DATA_ROOT", value:$IOTLAB_DATA_ROOT},
        {name:"IOTLAB_ETC_ROOT",  value:$IOTLAB_ETC_ROOT},
        {name:"IOTLAB_NET",       value:$IOTLAB_NET}
      ],
      PullImage: true
    }')"

  echo "[*] Updating existing repo stack: $name (id=$id)"
  http_portainer PUT "$PORTAINER_URL/api/stacks/$id/git?endpointId=$ENDPOINT_ID" "$payload" >/dev/null

  # Force immediate git redeploy (some builds require this endpoint)
  echo "[*] Triggering git redeploy: $name"
  http_portainer POST "$PORTAINER_URL/api/stacks/$id/git/redeploy?endpointId=$ENDPOINT_ID" "{}" >/dev/null || true
}

# ------------------------------------------------------------
# Deploy all stacks (create or update)
# ------------------------------------------------------------
for item in "${STACKS[@]}"; do
  name="${item%%:*}"
  path="${item#*:}"

  if stack_exists "$name"; then
    if [[ "$UPDATE_EXISTING" == "1" ]]; then
      update_repo_stack "$name" "$path"
    else
      echo "[*] Stack already exists, skipping: $name"
    fi
  else
    create_repo_stack "$name" "$path"
  fi
done

echo "[*] Done. Check Portainer UI for stack status."
