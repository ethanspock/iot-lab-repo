#!/usr/bin/env bash
set -euo pipefail

PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"
ENDPOINT_ID="${ENDPOINT_ID:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load env if present (for IOTLAB_NET / IOTLAB_DATA_ROOT / tokens)
if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
fi

IOTLAB_NET="${IOTLAB_NET:-lab-test2}"
IOTLAB_DATA_ROOT="${IOTLAB_DATA_ROOT:-/opt/iot-lab}"

echo "[*] Waiting for Portainer at ${PORTAINER_URL} ..."
until curl -fsS "${PORTAINER_URL}/api/status" >/dev/null; do sleep 2; done

# Auth
read -rsp "Portainer admin password: " PASS
echo

JWT="$(curl -fsS -X POST "${PORTAINER_URL}/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"Username\":\"admin\",\"Password\":\"$PASS\"}" | jq -r .jwt)"

if [[ -z "${JWT}" || "${JWT}" == "null" ]]; then
  echo "Login failed — create the admin user once via the Portainer UI first."
  exit 1
fi

AUTH=(-H "Authorization: Bearer ${JWT}" -H "Content-Type: application/json")

# ---------- Host directories (portable, no /mnt hardcoding) ----------
sudo mkdir -p \
  /etc/iot-lab/suricata \
  "${IOTLAB_DATA_ROOT}/thingsboard/data" \
  "${IOTLAB_DATA_ROOT}/thingsboard/logs" \
  "${IOTLAB_DATA_ROOT}/mosquitto/data" \
  "${IOTLAB_DATA_ROOT}/mosquitto/log" \
  "${IOTLAB_DATA_ROOT}/suricata/logs" \
  "${IOTLAB_DATA_ROOT}/evebox/data"

# Reasonable perms (no 777)
sudo chown -R root:root /etc/iot-lab || true
sudo chown -R root:root "${IOTLAB_DATA_ROOT}" || true
sudo chmod -R 755 "${IOTLAB_DATA_ROOT}" || true

# ---------- Ensure external docker network exists ----------
if ! docker network inspect "${IOTLAB_NET}" >/dev/null 2>&1; then
  echo "[*] Creating docker network ${IOTLAB_NET}"
  docker network create "${IOTLAB_NET}" >/dev/null
else
  echo "[*] Docker network ${IOTLAB_NET} already exists"
fi

# ---------- Generate Suricata config with correct bridge interface ----------
# Determine docker bridge interface name for the network: br-<first12(netid)>
NET_ID="$(docker network inspect "${IOTLAB_NET}" -f '{{slice .Id 0 12}}')"
BR_IF="br-${NET_ID}"

echo "[*] Using Suricata capture interface: ${BR_IF}"

# Create /etc/iot-lab/suricata/suricata.yaml from template
# Expect template contains "br-CHANGE-ME"
if grep -q "br-CHANGE-ME" "${ROOT_DIR}/configs/suricata/suricata.yaml"; then
  sed "s/br-CHANGE-ME/${BR_IF}/g" "${ROOT_DIR}/configs/suricata/suricata.yaml" \
    | sudo tee /etc/iot-lab/suricata/suricata.yaml >/dev/null
else
  # If your template already has a specific interface, replace it anyway:
  sed -E "s/^[[:space:]]*-[[:space:]]*interface:.*$/  - interface: ${BR_IF}/" \
    "${ROOT_DIR}/configs/suricata/suricata.yaml" \
    | sudo tee /etc/iot-lab/suricata/suricata.yaml >/dev/null
fi

# ---------- Portainer Stack deploy (idempotent: create or update) ----------
get_stack_id() {
  local name="$1"
  curl -fsS "${PORTAINER_URL}/api/stacks" "${AUTH[@]}" \
    | jq -r --arg n "${name}" '.[] | select(.Name==$n) | .Id' \
    | head -n 1
}

create_stack() {
  local name="$1"
  local file="$2"
  curl -fsS -X POST \
    "${PORTAINER_URL}/api/stacks?type=2&method=string&endpointId=${ENDPOINT_ID}" \
    "${AUTH[@]}" \
    -d "$(jq -n --arg n "${name}" --arg c "$(cat "${file}")" '{Name:$n,StackFileContent:$c}')"
}

update_stack() {
  local id="$1"
  local file="$2"
  curl -fsS -X PUT \
    "${PORTAINER_URL}/api/stacks/${id}?endpointId=${ENDPOINT_ID}" \
    "${AUTH[@]}" \
    -d "$(jq -n --arg c "$(cat "${file}")" '{StackFileContent:$c, Prune:true}')"
}

deploy() {
  local name="$1"
  local file="$2"
  echo "[*] Deploying ${name} from ${file}"
  local id
  id="$(get_stack_id "${name}" || true)"
  if [[ -z "${id}" || "${id}" == "null" ]]; then
    create_stack "${name}" "${file}" >/dev/null
    echo "    created"
  else
    update_stack "${id}" "${file}" >/dev/null
    echo "    updated (id=${id})"
  fi
}

# ---------- Deploy stacks in dependency order ----------
deploy iot-lab-core       "${ROOT_DIR}/stacks/iot-lab-core/docker-compose.yml"
deploy iot-lab-mqtt       "${ROOT_DIR}/stacks/iot-lab-mqtt/docker-compose.yml"
deploy iot-lab-modbus     "${ROOT_DIR}/stacks/iot-lab-modbus/docker-compose.yml"
deploy iot-lab-bacnet     "${ROOT_DIR}/stacks/iot-lab-bacnet/docker-compose.yml"
deploy iot-lab-monitoring "${ROOT_DIR}/stacks/iot-lab-monitoring/docker-compose.yml"

echo
echo "[+] Done."
echo "    ThingsBoard: http://<host>:8081"
echo "    EveBox:      https://<host>:5636"
