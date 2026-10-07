#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo
echo "=== NoLimits WARDOGS 50vs50 AI Balancer ==="
echo "1/7 Server pruefen"
. /etc/os-release
echo "System: ${PRETTY_NAME:-unbekannt}"
case "${ID:-}" in
  ubuntu|debian) ;;
  *) echo "FEHLER: Nur Ubuntu/Debian unterstuetzt."; exit 11 ;;
esac

if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)4180$'; then
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'nolimits-balancer'; then
    echo "FEHLER: Port 4180 ist bereits durch einen anderen Dienst belegt."
    ss -ltnp 2>/dev/null | grep ':4180' || true
    exit 12
  fi
fi

echo "2/7 Abhaengigkeiten"
apt-get update -qq
apt-get install -y -qq git unzip ca-certificates curl openssl docker.io >/dev/null
systemctl enable --now docker >/dev/null
echo "Docker: $(docker --version)"

echo "3/7 Paket laden und pruefen"
rm -rf /tmp/nolimits-deploy /tmp/nolimits-balancer-v1.zip /tmp/nolimits-balancer-v1.b64
git clone -q --depth 1 --branch deploy-ai-balancer https://github.com/redshoxx/Wardogs-NoLimits.git /tmp/nolimits-deploy
cat \
  /tmp/nolimits-deploy/deploy/nolimits-balancer-v1.b64.part0 \
  /tmp/nolimits-deploy/deploy/nolimits-balancer-v1.b64.part1 \
  /tmp/nolimits-deploy/deploy/nolimits-balancer-v1.b64.part2 \
  /tmp/nolimits-deploy/deploy/nolimits-balancer-v1.b64.part3c \
  /tmp/nolimits-deploy/deploy/nolimits-balancer-v1.b64.part4 \
  > /tmp/nolimits-balancer-v1.b64
[ "$(wc -c < /tmp/nolimits-balancer-v1.b64)" = "32228" ] || { echo "FEHLER: Paketlaenge."; exit 20; }
base64 -d /tmp/nolimits-balancer-v1.b64 > /tmp/nolimits-balancer-v1.zip
EXPECTED="0721749f64594a402e58f87e27205628133c67ab7ed912817013c0c4085ace07"
ACTUAL="$(sha256sum /tmp/nolimits-balancer-v1.zip | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED" ] || { echo "FEHLER: SHA256."; exit 21; }
unzip -tq /tmp/nolimits-balancer-v1.zip >/dev/null
echo "Paket: OK"

echo "4/7 Anwendung installieren"
rm -rf /opt/nolimits-balancer.new
mkdir -p /opt/nolimits-balancer.new
unzip -q /tmp/nolimits-balancer-v1.zip -d /opt/nolimits-balancer.new
NEW_DIR="/opt/nolimits-balancer.new/nolimits-balancer"
OLD_ENV=""
if [ -f /opt/nolimits-balancer/.env ]; then OLD_ENV="$(cat /opt/nolimits-balancer/.env)"; fi
docker rm -f nolimits-balancer >/dev/null 2>&1 || true
if [ -d /opt/nolimits-balancer ]; then
  BACKUP="/opt/nolimits-balancer.backup-$(date +%Y%m%d-%H%M%S)"
  mv /opt/nolimits-balancer "$BACKUP"
  echo "Backup: $BACKUP"
fi
mv "$NEW_DIR" /opt/nolimits-balancer
rm -rf /opt/nolimits-balancer.new
mkdir -p /opt/nolimits-balancer/data

echo "5/7 Konfiguration"
if [ -n "$OLD_ENV" ]; then
  printf '%s\n' "$OLD_ENV" > /opt/nolimits-balancer/.env
  ADMIN_USER="$(grep '^ADMIN_USER=' /opt/nolimits-balancer/.env | cut -d= -f2- || true)"
  ADMIN_USER="${ADMIN_USER:-admin}"
  ADMIN_PASS="$(grep '^ADMIN_PASSWORD=' /opt/nolimits-balancer/.env | cut -d= -f2- || true)"
else
  ADMIN_USER=admin
  ADMIN_PASS="$(openssl rand -hex 12)"
  cat > /opt/nolimits-balancer/.env <<EOF
PORT=4180
DATA_DIR=/data
ADMIN_USER=${ADMIN_USER}
ADMIN_PASSWORD=${ADMIN_PASS}
WARDOGS_RCON_URL=http://127.0.0.1:7776
WARDOGS_RCON_TOKEN=
DEMO_MODE=false
LEARNING_RATE=0.035
EOF
fi
chmod 600 /opt/nolimits-balancer/.env

echo "6/7 Docker bauen und starten"
docker build -q -t nolimits-balancer:latest /opt/nolimits-balancer >/dev/null
docker run -d --name nolimits-balancer --restart unless-stopped --network host \
  --env-file /opt/nolimits-balancer/.env \
  -v /opt/nolimits-balancer/data:/data \
  nolimits-balancer:latest >/dev/null

if command -v ufw >/dev/null 2>&1 && ufw status | head -1 | grep -q 'Status: active'; then
  ufw allow 4180/tcp >/dev/null
fi

echo "7/7 Healthcheck"
OK=0
for i in $(seq 1 30); do
  if curl -fsS -u "${ADMIN_USER}:${ADMIN_PASS}" http://127.0.0.1:4180/health 2>/dev/null | grep -q '"ok":true'; then OK=1; break; fi
  sleep 1
done
if [ "$OK" != 1 ]; then
  echo "FEHLER: Healthcheck"
  docker logs --tail 80 nolimits-balancer || true
  exit 30
fi

PUBLIC_IP="$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
echo
echo "================================================"
echo " NOLIMITS AI BALANCER LAEUFT"
echo " Dashboard: http://${PUBLIC_IP}:4180"
echo " Benutzer:  ${ADMIN_USER}"
echo " Passwort:  ${ADMIN_PASS}"
echo "================================================"
echo
echo "RCON ist noch NICHT freigeschaltet: Token ist leer."
echo "Automatische Teamwechsel bleiben aus, bis RCON getestet wurde."
docker ps --filter name=nolimits-balancer --format 'Container: {{.Names}} | {{.Status}}'
