#!/usr/bin/env bash
set -euo pipefail

# =========================
# User-tunable defaults
# =========================
PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"
ENDPOINT_NAME="${ENDPOINT_NAME:-local}"

IOTLAB_NET="${IOTLAB_NET:-lab-test2}"
IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"
IOTLAB_ETC_ROOT="${IOTLAB_ETC_ROOT:-/etc/iot-lab}"
TZ="${TZ:-UTC}"

REPO_URL="${REPO_URL:-https://github.com/ethanspock/iot-lab-repo.git}"
REPO_REF="${REPO_REF:-refs/heads/main}"   # change if your default branch isn't main

# Stacks (Portainer will clone repo; ComposeFilePathInRepository must be correct)
STACKS=(
  "iot-lab-core:stacks/iot-lab-core/docker-compose.yml"
  "iot-lab-mqtt:stacks/iot-lab-mqtt/docker-compose.yml"
  "iot-lab-modbus:stacks/iot-lab-modbus/docker-compose.yml"
  "iot-lab-bacnet:stacks/iot-lab-bacnet/docker-compose.yml"
  "iot-lab-monitoring:stacks/iot-lab-monitoring/docker-compose.yml"
)

# =========================
# Helpers
# =========================
die(){ echo "[!] $*" >&2; exit 1; }
info(){ echo "[*] $*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

info "Repo root: $REPO_ROOT"
info "Portainer:  $PORTAINER_URL"
info "Data root:  $IOTLAB_DATA_ROOT"
info "Etc  root:  $IOTLAB_ETC_ROOT"
info "Network:    $IOTLAB_NET"
info "Repo URL:   $REPO_URL"
info "Repo REF:   $REPO_REF"

command -v jq >/dev/null || die "jq is required (apt-get install -y jq)"
command -v curl >/dev/null || die "curl is required"

# Load .env if present (for TB tokens etc)
if [[ -f "$REPO_ROOT/.env" ]]; then
  info "Loading .env"
  # shellcheck disable=SC2046
  export $(grep -v '^\s*#' "$REPO_ROOT/.env" | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | xargs -d '\n' -r)
else
  info "No .env found at repo root (recommended)."
fi

# Verify required vars (your compose uses :? guards)
: "${TB_GATEWAY_TOKEN_CORE:?set TB_GATEWAY_TOKEN_CORE in .env}"
: "${TB_GATEWAY_TOKEN_WINDFARM:?set TB_GATEWAY_TOKEN_WINDFARM in .env}"
: "${TB_GATEWAY_TOKEN_NUKE:?set TB_GATEWAY_TOKEN_NUKE in .env}"

# Wait for Portainer
info "Waiting for Portainer API..."
until curl -fsS "$PORTAINER_URL/api/status" >/dev/null; do sleep 2; done
PORT_VER="$(curl -fsS "$PORTAINER_URL/api/status" | jq -r '.Version')"
info "Portainer version: $PORT_VER"

read -rsp "Portainer admin password: " PASS; echo
JWT="$(curl -fsS -X POST "$PORTAINER_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u admin --arg p "$PASS" '{Username:$u,Password:$p}')" \
  | jq -r .jwt)"

[[ -n "$JWT" && "$JWT" != "null" ]] || die "Login failed (admin not created yet? create once in UI)."
AUTH=(-H "Authorization: Bearer $JWT")

# Find endpointId by name
ENDPOINT_ID="$(curl -fsS "$PORTAINER_URL/api/endpoints" "${AUTH[@]}" \
  | jq -r --arg n "$ENDPOINT_NAME" '.[] | select(.Name==$n) | .Id' | head -n1)"

[[ -n "$ENDPOINT_ID" && "$ENDPOINT_ID" != "null" ]] || die "Could not find endpoint named '$ENDPOINT_NAME'"
info "Using endpointId: $ENDPOINT_ID"

# Create host directories
info "Creating host directories..."
sudo mkdir -p \
  "$IOTLAB_DATA_ROOT/thingsboard/data" \
  "$IOTLAB_DATA_ROOT/thingsboard/logs" \
  "$IOTLAB_DATA_ROOT/mosquitto/data" \
  "$IOTLAB_DATA_ROOT/mosquitto/log" \
  "$IOTLAB_DATA_ROOT/suricata/logs" \
  "$IOTLAB_DATA_ROOT/evebox/data" \
  "$IOTLAB_ETC_ROOT/suricata"

# Ensure network exists
info "Ensuring docker network exists: $IOTLAB_NET"
if docker network inspect "$IOTLAB_NET" >/dev/null 2>&1; then
  echo "    already exists"
else
  docker network create "$IOTLAB_NET" >/dev/null
  echo "    created"
fi

# Derive bridge name for Suricata
NET_ID="$(docker network inspect "$IOTLAB_NET" --format '{{slice .Id 0 12}}')"
SURICATA_IFACE="br-${NET_ID}"
info "Suricata capture interface: $SURICATA_IFACE"

# Install Suricata config (replace br-CHANGE-ME)
SRC_SURICATA_CFG="$REPO_ROOT/configs/suricata/suricata.yaml"
DST_SURICATA_CFG="$IOTLAB_ETC_ROOT/suricata/suricata.yaml"
[[ -f "$SRC_SURICATA_CFG" ]] || die "Missing $SRC_SURICATA_CFG"

info "Installing Suricata config to $DST_SURICATA_CFG"
sudo cp "$SRC_SURICATA_CFG" "$DST_SURICATA_CFG"
sudo sed -i "s/^  - interface: br-CHANGE-ME/  - interface: ${SURICATA_IFACE}/" "$DST_SURICATA_CFG"

# Build stack Env array for Portainer (from current environment)
mk_env_json() {
  # Only send the variables your lab actually uses (keeps it clean + predictable)
  local keys=(
    TZ
    IOTLAB_NET IOTLAB_DATA_ROOT IOTLAB_ETC_ROOT
    TB_HOST TB_MQTT_PORT TB_GATEWAY_TOKEN_CORE TB_GATEWAY_TOKEN_WINDFARM TB_GATEWAY_TOKEN_NUKE
    MQTT_HOST MQTT_PORT
  )
  jq -n --argjson keys "$(printf '%s\n' "${keys[@]}" | jq -R . | jq -s .)" '
    [ $keys[] as $k
      | (env[$k] // empty) as $v
      | select($v != "")
      | { name: $k, value: $v }
    ]'
}

ENV_JSON="$(mk_env_json)"

# Deploy (create or update) a repository stack
deploy_repo_stack() {
  local name="$1"
  local compose_path="$2"

  info "Deploying stack: $name ($compose_path)"

  # Check if stack exists
  local existing_id
  existing_id="$(curl -fsS "$PORTAINER_URL/api/stacks" "${AUTH[@]}" \
    | jq -r --arg n "$name" '.[] | select(.Name==$n) | .Id' | head -n1)"

  if [[ -n "$existing_id" && "$existing_id" != "null" ]]; then
    info "  Stack exists (id=$existing_id) -> updating via git pull + redeploy"
    # Update endpoint (Portainer uses /stacks/{id}/git/redeploy for repo stacks)
    curl -fsS -X POST \
      "$PORTAINER_URL/api/stacks/$existing_id/git/redeploy?endpointId=$ENDPOINT_ID" \
      "${AUTH[@]}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg ref "$REPO_REF" --argjson env "$ENV_JSON" \
        '{RepositoryReferenceName:$ref, Env:$env}')" \
      >/dev/null
    echo "  updated"
    return
  fi

  # Create repo stack
  # NOTE: repo auth omitted (public repo). For private, add RepositoryAuthentication + credentials.
  local payload
  payload="$(jq -n \
    --arg name "$name" \
    --arg url "$REPO_URL" \
    --arg ref "$REPO_REF" \
    --arg cpath "$compose_path" \
    --argjson env "$ENV_JSON" \
    '{
      Name: $name,
      RepositoryURL: $url,
      RepositoryReferenceName: $ref,
      ComposeFilePathInRepository: $cpath,
      Env: $env
    }')"

  curl -fsS -X POST \
    "$PORTAINER_URL/api/stacks/create/standalone/repository?endpointId=$ENDPOINT_ID" \
    "${AUTH[@]}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    >/dev/null

  echo "  created"
}

# Export defaults so compose interpolation matches your YAML
export TZ IOTLAB_NET IOTLAB_DATA_ROOT IOTLAB_ETC_ROOT

# Deploy all stacks
for item in "${STACKS[@]}"; do
  name="${item%%:*}"
  path="${item#*:}"
  [[ -f "$REPO_ROOT/$path" ]] || die "Missing compose file: $path"
  deploy_repo_stack "$name" "$path"
done

info "Done."
info "ThingsBoard: http://<host>:8081"
info "EveBox:      https://<host>:5636   (self-signed TLS; your browser will warn)"
