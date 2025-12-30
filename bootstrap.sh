#!/usr/bin/env bash
set -euo pipefail

### ----------------------------
### Config (override via env)
### ----------------------------
PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"
ADMIN_USER="${ADMIN_USER:-admin}"
IOTLAB_NET="${IOTLAB_NET:-lab-test2}"

# Where data/config live on the host
IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"
IOTLAB_ETC_ROOT="${IOTLAB_ETC_ROOT:-/etc/iot-lab}"

# Repo info (override if you fork)
REPO_URL="${REPO_URL:-https://github.com/ethanspock/iot-lab-repo.git}"
REPO_REF="${REPO_REF:-refs/heads/main}"

# Stacks and their compose file path within the repo
declare -a STACKS=(
  "iot-lab-core:stacks/iot-lab-core/docker-compose.yml"
  "iot-lab-mqtt:stacks/iot-lab-mqtt/docker-compose.yml"
  "iot-lab-modbus:stacks/iot-lab-modbus/docker-compose.yml"
  "iot-lab-bacnet:stacks/iot-lab-bacnet/docker-compose.yml"
  "iot-lab-monitoring:stacks/iot-lab-monitoring/docker-compose.yml"
)

### ----------------------------
### Helpers
### ----------------------------
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
ROOT="$(repo_root)"

info() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

http_json() {
  # http_json METHOD URL DATA(optional)
  local method="$1"; shift
  local url="$1"; shift
  local data="${1:-}"

  local tmp http
  tmp="$(mktemp)"
  if [[ -n "$data" ]]; then
    http="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" \
      -H "Content-Type: application/json" \
      "${AUTH[@]:-}" \
      "$url" \
      -d "$data" || true)"
  else
    http="$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" \
      "${AUTH[@]:-}" \
      "$url" || true)"
  fi

  if [[ "$http" -lt 200 || "$http" -ge 300 ]]; then
    warn "HTTP $http for $method $url"
    echo "---- response body ----" >&2
    cat "$tmp" >&2 || true
    echo >&2
    echo "-----------------------" >&2
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp"
  rm -f "$tmp"
}

### ----------------------------
### Preflight
### ----------------------------
need_cmd curl
need_cmd jq
need_cmd docker
need_cmd git

info "Repo root: $ROOT"
info "Portainer:  $PORTAINER_URL"
info "Data root:  $IOTLAB_DATA_ROOT"
info "Etc  root:  $IOTLAB_ETC_ROOT"
info "Network:    $IOTLAB_NET"
info "Repo URL:   $REPO_URL"
info "Repo REF:   $REPO_REF"

# Load .env if present
if [[ -f "$ROOT/.env" ]]; then
  info "Loading .env"
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

# Validate required tokens exist (your compose uses :? which will fail otherwise)
: "${TB_GATEWAY_TOKEN_CORE:?set TB_GATEWAY_TOKEN_CORE in .env}"
: "${TB_GATEWAY_TOKEN_WINDFARM:?set TB_GATEWAY_TOKEN_WINDFARM in .env}"
: "${TB_GATEWAY_TOKEN_NUKE:?set TB_GATEWAY_TOKEN_NUKE in .env}"

### ----------------------------
### Wait for Portainer
### ----------------------------
info "Waiting for Portainer API..."
until curl -fsS "$PORTAINER_URL/api/status" >/dev/null; do sleep 2; done
VER="$(curl -fsS "$PORTAINER_URL/api/status" | jq -r '.Version')"
info "Portainer version: $VER"

### ----------------------------
### Admin init (fresh installs)
### ----------------------------
read -rsp "Portainer admin password: " PASS; echo

# Try init (safe: will fail on already-initialized installs)
INIT_PAYLOAD="$(jq -n --arg u "$ADMIN_USER" --arg p "$PASS" '{Username:$u,Password:$p}')"
if ! curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "$PORTAINER_URL/api/users/admin/init" \
  -H "Content-Type: application/json" \
  -d "$INIT_PAYLOAD" | grep -qE '^(2|4)'; then
  # If Portainer is weird, we don't die here; auth will tell us
  warn "Admin init call returned unexpected status (continuing)."
fi

### ----------------------------
### Authenticate
### ----------------------------
AUTH_PAYLOAD="$(jq -n --arg u "$ADMIN_USER" --arg p "$PASS" '{Username:$u,Password:$p}')"
JWT="$(curl -fsS -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "$AUTH_PAYLOAD" | jq -r .jwt)"

[[ -n "$JWT" && "$JWT" != "null" ]] || die "Login failed (check admin password / UI init)."
AUTH=(-H "Authorization: Bearer $JWT")

### ----------------------------
### Discover endpoint ID
### ----------------------------
ENDPOINT_ID="$(http_json GET "$PORTAINER_URL/api/endpoints" | jq -r '.[0].Id')"
[[ -n "$ENDPOINT_ID" && "$ENDPOINT_ID" != "null" ]] || die "No endpoints found in Portainer."
info "Using endpointId: $ENDPOINT_ID"

### ----------------------------
### Host directories
### ----------------------------
info "Creating host directories..."
sudo mkdir -p \
  "$IOTLAB_DATA_ROOT/thingsboard/data" \
  "$IOTLAB_DATA_ROOT/thingsboard/logs" \
  "$IOTLAB_DATA_ROOT/mosquitto/data" \
  "$IOTLAB_DATA_ROOT/mosquitto/log" \
  "$IOTLAB_DATA_ROOT/suricata/logs" \
  "$IOTLAB_DATA_ROOT/evebox/data" \
  "$IOTLAB_ETC_ROOT/suricata"

# Give docker containers access
sudo chmod -R a+rwx "$IOTLAB_DATA_ROOT" || true

### ----------------------------
### Ensure docker network exists
### ----------------------------
info "Ensuring docker network exists: $IOTLAB_NET"
if docker network inspect "$IOTLAB_NET" >/dev/null 2>&1; then
  echo "    already exists"
else
  docker network create "$IOTLAB_NET" >/dev/null
  echo "    created"
fi

# Determine bridge interface name for Suricata capture
NET_ID="$(docker network inspect "$IOTLAB_NET" --format '{{slice .Id 0 12}}')"
BR_IF="br-${NET_ID}"
info "Suricata capture interface: $BR_IF"

### ----------------------------
### Install Suricata config (portable)
### ----------------------------
SURICATA_SRC="$ROOT/configs/suricata/suricata.yaml"
SURICATA_DST="$IOTLAB_ETC_ROOT/suricata/suricata.yaml"

[[ -f "$SURICATA_SRC" ]] || die "Missing $SURICATA_SRC"

info "Installing Suricata config to $SURICATA_DST"
sudo sed "s/br-CHANGE-ME/$BR_IF/g" "$SURICATA_SRC" | sudo tee "$SURICATA_DST" >/dev/null

### ----------------------------
### Env list for Portainer stack deploy
### ----------------------------
ENV_JSON="$(jq -n \
  --arg TZ "${TZ:-UTC}" \
  --arg IOTLAB_NET "$IOTLAB_NET" \
  --arg IOTLAB_DATA_ROOT "$IOTLAB_DATA_ROOT" \
  --arg IOTLAB_ETC_ROOT "$IOTLAB_ETC_ROOT" \
  --arg TB_HOST "${TB_HOST:-thingsboard}" \
  --arg TB_MQTT_PORT "${TB_MQTT_PORT:-1883}" \
  --arg MQTT_HOST "${MQTT_HOST:-mosquitto}" \
  --arg MQTT_PORT "${MQTT_PORT:-1883}" \
  --arg TB_GATEWAY_TOKEN_CORE "$TB_GATEWAY_TOKEN_CORE" \
  --arg TB_GATEWAY_TOKEN_WINDFARM "$TB_GATEWAY_TOKEN_WINDFARM" \
  --arg TB_GATEWAY_TOKEN_NUKE "$TB_GATEWAY_TOKEN_NUKE" \
'[
  {name:"TZ", value:$TZ},
  {name:"IOTLAB_NET", value:$IOTLAB_NET},
  {name:"IOTLAB_DATA_ROOT", value:$IOTLAB_DATA_ROOT},
  {name:"IOTLAB_ETC_ROOT", value:$IOTLAB_ETC_ROOT},
  {name:"TB_HOST", value:$TB_HOST},
  {name:"TB_MQTT_PORT", value:$TB_MQTT_PORT},
  {name:"MQTT_HOST", value:$MQTT_HOST},
  {name:"MQTT_PORT", value:$MQTT_PORT},
  {name:"TB_GATEWAY_TOKEN_CORE", value:$TB_GATEWAY_TOKEN_CORE},
  {name:"TB_GATEWAY_TOKEN_WINDFARM", value:$TB_GATEWAY_TOKEN_WINDFARM},
  {name:"TB_GATEWAY_TOKEN_NUKE", value:$TB_GATEWAY_TOKEN_NUKE}
]')"

### ----------------------------
### Stack ops: delete if exists, then create from repo
### ----------------------------
get_stack_id_by_name() {
  local name="$1"
  http_json GET "$PORTAINER_URL/api/stacks" | jq -r --arg n "$name" '.[] | select(.Name==$n) | .Id' | head -n1
}

delete_stack_if_exists() {
  local name="$1"
  local id
  id="$(get_stack_id_by_name "$name" || true)"
  if [[ -n "$id" && "$id" != "null" ]]; then
    info "Deleting existing stack: $name (id=$id)"
    # Portainer supports endpointId on delete for standalone stacks
    http_json DELETE "$PORTAINER_URL/api/stacks/$id?endpointId=$ENDPOINT_ID" >/dev/null || true
  fi
}

create_repo_stack() {
  local name="$1"
  local compose_path="$2"

  info "Creating stack: $name ($compose_path)"

  local payload
  payload="$(jq -n \
    --arg Name "$name" \
    --arg RepositoryURL "$REPO_URL" \
    --arg RepositoryReferenceName "$REPO_REF" \
    --arg ComposeFile "$compose_path" \
    --arg ComposeFilePathInRepository "$compose_path" \
    --argjson Env "$ENV_JSON" \
    '{
      Name: $Name,
      RepositoryURL: $RepositoryURL,
      RepositoryReferenceName: $RepositoryReferenceName,

      # Compatibility: different Portainer versions use different keys
      ComposeFile: $ComposeFile,
      ComposeFilePathInRepository: $ComposeFilePathInRepository,

      Env: $Env
    }')"

  http_json POST \
    "$PORTAINER_URL/api/stacks/create/standalone/repository?endpointId=$ENDPOINT_ID" \
    "$payload" >/dev/null
}


### ----------------------------
### Deploy all stacks
### ----------------------------
for entry in "${STACKS[@]}"; do
  name="${entry%%:*}"
  path="${entry#*:}"

  # sanity: repo paths must exist locally (helps catch typos)
  [[ -f "$ROOT/$path" ]] || die "Compose path not found in repo: $path"

  delete_stack_if_exists "$name"
  create_repo_stack "$name" "$path"
done

info "Done."
info "ThingsBoard: http://<host>:8081"
info "EveBox:      https://<host>:5636  (TLS enabled by EveBox; use https)"
