#!/usr/bin/env bash
set -euo pipefail

apt-get update -y
apt-get install -y ca-certificates curl gnupg jq git

# Docker
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# Portainer
docker volume create portainer_data >/dev/null 2>&1 || true
docker rm -f portainer >/dev/null 2>&1 || true

docker run -d \
  --name portainer \
  --restart=unless-stopped \
  -p 9000:9000 \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest

echo
echo "Portainer:"
echo "  UI:  http://<host>:9000"
echo "  TLS: https://<host>:9443"
