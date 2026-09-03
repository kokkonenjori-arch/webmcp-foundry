#!/usr/bin/env bash
# deploy/gcp-provision.sh — provision a small Debian VM (e2-micro is enough) as the permanent
# WebMCP Foundry backend: systemd-managed Julia process + Caddy automatic HTTPS. No Docker.
#
#   bash deploy/gcp-provision.sh <foundry-host> <ledgerly-host> [git-ref]
#   e.g.  bash deploy/gcp-provision.sh foundry.34-1-2-3.sslip.io ledgerly.34-1-2-3.sslip.io main
#
# Idempotent: re-running updates the checkout and restarts the services. The ledger and all
# runtime state live in /opt/webmcp-foundry/data on the boot disk and survive reboots.
set -euo pipefail
FOUNDRY_HOST="$1"; APP_HOST="$2"; REF="${3:-main}"
REPO="https://github.com/kokkonenjori-arch/webmcp-foundry"
JULIA_URL="https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-1.12.6-linux-x86_64.tar.gz"
APP_DIR=/opt/webmcp-foundry
RUN_USER="$(id -un)"

echo "== packages"
sudo apt-get update -y -q
sudo apt-get install -y -q curl git ca-certificates debian-keyring debian-archive-keyring apt-transport-https gnupg

echo "== swap (2 GiB; Julia's verifier peaks above what 1 GiB of RAM alone allows comfortably)"
if ! sudo swapon --show | grep -q /swapfile; then
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
fi

echo "== julia"
if [ ! -x /opt/julia/bin/julia ]; then
  curl -fsSL "$JULIA_URL" -o /tmp/julia.tgz
  sudo mkdir -p /opt/julia && sudo tar -xzf /tmp/julia.tgz -C /opt/julia --strip-components=1 && rm -f /tmp/julia.tgz
fi
/opt/julia/bin/julia --version

echo "== caddy"
if ! command -v caddy > /dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
  sudo apt-get update -y -q && sudo apt-get install -y -q caddy
fi

echo "== checkout $REF"
sudo mkdir -p "$APP_DIR" && sudo chown "$RUN_USER" "$APP_DIR"
if [ -d "$APP_DIR/.git" ]; then git -C "$APP_DIR" fetch -q origin && git -C "$APP_DIR" checkout -q "$REF" && git -C "$APP_DIR" pull -q --ff-only origin "$REF" || true
else git clone -q "$REPO" "$APP_DIR" && git -C "$APP_DIR" checkout -q "$REF"; fi
mkdir -p "$APP_DIR/data"
echo "https://$FOUNDRY_HOST" > "$APP_DIR/data/public-foundry-url.txt"
echo "https://$APP_HOST" > "$APP_DIR/data/public-app-url.txt"

echo "== systemd unit"
sudo tee /etc/systemd/system/webmcp-foundry.service > /dev/null <<EOF
[Unit]
Description=WebMCP Foundry (Foundry :8090 + Ledgerly :8091)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DIR
Environment=JULIA_DEPOT_PATH=$APP_DIR/.julia
ExecStart=/opt/julia/bin/julia bin/foundry.jl --foundry-url https://$FOUNDRY_HOST
Restart=always
RestartSec=3
StandardOutput=append:$APP_DIR/data/server.log
StandardError=append:$APP_DIR/data/server.log

[Install]
WantedBy=multi-user.target
EOF

echo "== caddy (automatic HTTPS for both hosts)"
sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
$FOUNDRY_HOST {
    reverse_proxy 127.0.0.1:8090
}
$APP_HOST {
    reverse_proxy 127.0.0.1:8091
}
EOF

sudo systemctl daemon-reload
sudo systemctl enable webmcp-foundry caddy > /dev/null
sudo systemctl restart webmcp-foundry
sudo systemctl restart caddy
for i in $(seq 1 60); do curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/health | grep -q 200 && break; sleep 2; done
echo "== local health"; curl -s http://127.0.0.1:8090/health; echo; curl -s http://127.0.0.1:8091/health; echo
echo "== done: https://$FOUNDRY_HOST  https://$APP_HOST"
