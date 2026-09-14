#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="gpu-monitoring"
INSTALL_DIR="/opt/${APP_NAME}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DASH_UID="adl5jhz"
DASH_URL="http://127.0.0.1:3000/d/${DASH_UID}/gpu-monitoring-dashboard?from=now-30m&to=now&timezone=browser&refresh=5s&dtab=Dashboard"

LOG="/tmp/gpu-monitoring-install.log"

exec > >(tee -a "$LOG") 2>&1


########################################
# Helpers
########################################

info()
{
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

fail()
{
    echo
    echo "ERROR: $1"
    echo
    echo "Installer log:"
    echo "$LOG"
    exit 1
}

on_error()
{
    echo
    echo "Installation failed near line ${BASH_LINENO[0]}."
    echo "See $LOG"
}

trap on_error ERR


########################################
# Root check
########################################

if [[ $EUID -ne 0 ]]; then
    fail "Run installer with: sudo ./install.sh"
fi


########################################
# OS detection
########################################

info "1/13 - Checking operating system"

if [[ ! -f /etc/os-release ]]; then
    fail "Cannot identify Linux distribution."
fi

. /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        fail "This installer currently supports Ubuntu/Debian systems only."
        ;;
esac

ARCH="$(dpkg --print-architecture)"

echo "OS: ${PRETTY_NAME:-$ID}"
echo "Architecture: $ARCH"


########################################
# Basic tools
########################################

info "2/13 - Installing base requirements"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    jq \
    openssl \
    libnotify-bin \
    procps


########################################
# NVIDIA driver check
########################################

info "3/13 - Checking NVIDIA GPU driver"

if ! command -v nvidia-smi >/dev/null 2>&1; then

    cat <<EOF

NVIDIA driver is not installed.

The monitoring package will NOT automatically install or replace the
GPU driver because driver installation may require a reboot and depends
on the particular GPU/workstation.

Install the recommended NVIDIA driver, reboot, and run:

    sudo ./install.sh

again.

EOF

    exit 2
fi

if ! nvidia-smi >/dev/null 2>&1; then
    fail "nvidia-smi exists, but the NVIDIA driver/GPU is not responding."
fi

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"

echo "Detected GPU: $GPU_NAME"


########################################
# Docker installation
########################################

info "4/13 - Installing/checking Docker"

if ! command -v docker >/dev/null 2>&1; then

    echo "Docker not found. Installing distribution Docker package..."

    apt-get install -y docker.io

fi

systemctl enable --now docker

if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon is not working."
fi

echo "Docker: $(docker --version)"


########################################
# Docker Compose v2
########################################

info "5/13 - Installing/checking Docker Compose"

if ! docker compose version >/dev/null 2>&1; then

    echo "Docker Compose v2 not found."

    if apt-cache show docker-compose-v2 >/dev/null 2>&1; then

        apt-get install -y docker-compose-v2

    elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then

        apt-get install -y docker-compose-plugin

    else

        echo "Compose package unavailable in current repositories."
        echo "Configuring Docker official repository..."

        install -m 0755 -d /etc/apt/keyrings

        if [[ "$ID" == "ubuntu" ]]; then
            DOCKER_DIST="ubuntu"
        else
            DOCKER_DIST="debian"
        fi

        curl -fsSL \
            "https://download.docker.com/linux/${DOCKER_DIST}/gpg" \
            -o /etc/apt/keyrings/docker.asc

        chmod a+r /etc/apt/keyrings/docker.asc

        cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${DOCKER_DIST}
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        apt-get update

        apt-get install -y docker-compose-plugin

    fi
fi

docker compose version >/dev/null 2>&1 \
    || fail "Docker Compose v2 installation failed."

echo "Compose: $(docker compose version)"


########################################
# NVIDIA Container Toolkit
########################################

info "6/13 - Installing/checking NVIDIA Container Toolkit"

if ! command -v nvidia-ctk >/dev/null 2>&1; then

    echo "Installing NVIDIA Container Toolkit..."

    curl -fsSL \
      https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor --yes \
      -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L \
      https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed \
      's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list

    apt-get update

    apt-get install -y nvidia-container-toolkit

fi

nvidia-ctk runtime configure --runtime=docker

systemctl restart docker

sleep 3

docker info >/dev/null 2>&1 \
    || fail "Docker failed after configuring NVIDIA runtime."

echo "NVIDIA Container Toolkit configured."


########################################
# Chrome
########################################

info "7/13 - Installing/checking Google Chrome"

if ! command -v google-chrome >/dev/null 2>&1 && \
   ! command -v google-chrome-stable >/dev/null 2>&1; then

    if [[ "$ARCH" != "amd64" ]]; then

        echo "Google Chrome automatic installation currently supports amd64."
        echo "Browser integration will be installed, but Chrome must be installed manually."

    else

        TMP_DEB="/tmp/google-chrome-stable_current_amd64.deb"

        curl -fL \
            https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
            -o "$TMP_DEB"

        apt-get install -y "$TMP_DEB"

        rm -f "$TMP_DEB"
    fi
fi

if command -v google-chrome >/dev/null 2>&1; then
    echo "Chrome detected: $(google-chrome --version)"
elif command -v google-chrome-stable >/dev/null 2>&1; then
    echo "Chrome detected: $(google-chrome-stable --version)"
else
    echo "WARNING: Google Chrome is not installed."
fi


########################################
# Copy application
########################################

info "8/13 - Installing GPU Monitoring package"

mkdir -p "$INSTALL_DIR"

# Remove old package files, but runtime Docker volumes remain untouched.
find "$INSTALL_DIR" \
    -mindepth 1 \
    -maxdepth 1 \
    ! -name '.env' \
    -exec rm -rf {} +

cp -a "$SOURCE_DIR"/. "$INSTALL_DIR"/

rm -rf "$INSTALL_DIR/.git"

mkdir -p "$INSTALL_DIR/scripts"

cp \
    "$SOURCE_DIR/guardian/gpu_guardian_daemon.sh" \
    "$INSTALL_DIR/scripts/gpu_guardian_daemon.sh"

chmod 755 "$INSTALL_DIR/scripts/gpu_guardian_daemon.sh"

chown -R root:root "$INSTALL_DIR"


########################################
# Generate Grafana admin secret
########################################

info "9/13 - Configuring Grafana access"

ENV_FILE="$INSTALL_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then

    ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"

    cat >"$ENV_FILE" <<EOF
GRAFANA_ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF

    chmod 600 "$ENV_FILE"

else

    ADMIN_PASSWORD="$(grep '^GRAFANA_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
fi


# Production default = locked
python3 - "$INSTALL_DIR/grafana/dashboards/gpu-monitoring-dashboard.json" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path) as f:
    data = json.load(f)

data["editable"] = False
data["id"] = None

with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY


PROVIDER="$INSTALL_DIR/grafana/provisioning/dashboards/dashboard.yml"

if grep -q 'allowUiUpdates:' "$PROVIDER"; then
    sed -i \
      's/^[[:space:]]*allowUiUpdates:.*/    allowUiUpdates: false/' \
      "$PROVIDER"
else
    sed -i \
      '/type: file/a\    allowUiUpdates: false' \
      "$PROVIDER"
fi


########################################
# Validate package
########################################

info "10/13 - Validating configuration"

cd "$INSTALL_DIR"

docker compose config >/dev/null \
    || fail "docker-compose.yml validation failed."

docker run --rm \
    --entrypoint /bin/promtool \
    -v "$INSTALL_DIR/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    -v "$INSTALL_DIR/prometheus/rules:/etc/prometheus/rules:ro" \
    prom/prometheus \
    check config /etc/prometheus/prometheus.yml \
    || fail "Prometheus configuration validation failed."

echo "Configuration validation passed."


########################################
# Start Docker monitoring stack
########################################

info "11/13 - Starting monitoring stack"

cd "$INSTALL_DIR"

docker compose pull

docker compose up -d

echo "Waiting for Prometheus..."

PROM_READY=0

for i in $(seq 1 60); do

    if curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
        PROM_READY=1
        break
    fi

    sleep 2
done

[[ "$PROM_READY" == "1" ]] \
    || fail "Prometheus did not become ready."


echo "Waiting for Grafana..."

GRAFANA_READY=0

for i in $(seq 1 60); do

    if curl -fsS http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
        GRAFANA_READY=1
        break
    fi

    sleep 2
done

[[ "$GRAFANA_READY" == "1" ]] \
    || fail "Grafana did not become ready."


echo "Checking exporters..."

sleep 10

TARGETS="$(
    curl -fsS http://127.0.0.1:9090/api/v1/targets || true
)"

echo "$TARGETS" | grep -q '"health":"up"' \
    || fail "Prometheus exporters are not healthy."


########################################
# Guardian
########################################

info "12/13 - Installing GPU Guardian"

cp \
    "$SOURCE_DIR/guardian/gpu-guardian.service" \
    /etc/systemd/system/gpu-guardian.service

# Ensure service points to portable installed path.
sed -i \
    's#^ExecStart=.*#ExecStart=/opt/gpu-monitoring/scripts/gpu_guardian_daemon.sh#' \
    /etc/systemd/system/gpu-guardian.service

systemctl daemon-reload

systemctl enable gpu-guardian.service

systemctl restart gpu-guardian.service

sleep 2

systemctl is-active --quiet gpu-guardian.service \
    || fail "GPU Guardian service failed to start."

echo "GPU Guardian is running."


########################################
# Browser / system integration
########################################

info "13/13 - Installing dashboard shortcuts and browser integration"


# Browser launcher
cat >/usr/local/bin/gpu-monitor-browser <<EOF
#!/bin/bash

URL='${DASH_URL}'

for i in \$(seq 1 60); do

    if curl -fsS http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
        break
    fi

    sleep 2
done

if command -v google-chrome >/dev/null 2>&1; then
    exec google-chrome

elif command -v google-chrome-stable >/dev/null 2>&1; then
    exec google-chrome-stable
fi
EOF

chmod 755 /usr/local/bin/gpu-monitor-browser


# System-wide login autostart
mkdir -p /etc/xdg/autostart

cat >/etc/xdg/autostart/gpu-monitoring.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=GPU Monitoring
Comment=GPU workstation monitoring dashboard
Exec=/usr/local/bin/gpu-monitor-browser
Terminal=false
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF


# Application menu shortcut
cat >/usr/share/applications/gpu-monitoring.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=GPU Monitoring
Comment=GPU Workstation Health Monitor
Exec=/usr/local/bin/gpu-monitor-browser
Icon=utilities-system-monitor
Terminal=false
Categories=System;Utility;
EOF


# Chrome policy
mkdir -p /etc/opt/chrome/policies/managed

cp \
    "$SOURCE_DIR/browser/gpu-monitoring.json" \
    /etc/opt/chrome/policies/managed/gpu-monitoring.json

chmod 644 \
    /etc/opt/chrome/policies/managed/gpu-monitoring.json


########################################
# Dashboard edit commands
########################################

cat >/usr/local/bin/gpu-monitor-edit-on <<'EOF'
#!/bin/bash

set -e

INSTALL_DIR="/opt/gpu-monitoring"
DASH="$INSTALL_DIR/grafana/dashboards/gpu-monitoring-dashboard.json"
PROV="$INSTALL_DIR/grafana/provisioning/dashboards/dashboard.yml"

if [[ $EUID -ne 0 ]]; then
    echo "Run: sudo gpu-monitor-edit-on"
    exit 1
fi

python3 - "$DASH" <<'PY'
import json
import sys

p = sys.argv[1]

with open(p) as f:
    d = json.load(f)

d["editable"] = True

with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY

sed -i \
  's/^[[:space:]]*allowUiUpdates:.*/    allowUiUpdates: true/' \
  "$PROV"

cd "$INSTALL_DIR"

docker compose restart grafana >/dev/null

echo
echo "EDIT MODE ENABLED"
echo "Admin login: http://127.0.0.1:3000/login"
echo "Admin credentials: /etc/gpu-monitoring/admin-credentials"
EOF

chmod 755 /usr/local/bin/gpu-monitor-edit-on


cat >/usr/local/bin/gpu-monitor-edit-off <<'EOF'
#!/bin/bash

set -e

INSTALL_DIR="/opt/gpu-monitoring"
DASH="$INSTALL_DIR/grafana/dashboards/gpu-monitoring-dashboard.json"
PROV="$INSTALL_DIR/grafana/provisioning/dashboards/dashboard.yml"

if [[ $EUID -ne 0 ]]; then
    echo "Run: sudo gpu-monitor-edit-off"
    exit 1
fi

python3 - "$DASH" <<'PY'
import json
import sys

p = sys.argv[1]

with open(p) as f:
    d = json.load(f)

d["editable"] = False

with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY

sed -i \
  's/^[[:space:]]*allowUiUpdates:.*/    allowUiUpdates: false/' \
  "$PROV"

cd "$INSTALL_DIR"

docker compose restart grafana >/dev/null

echo "GPU Monitoring dashboard LOCKED / VIEW-ONLY."
EOF

chmod 755 /usr/local/bin/gpu-monitor-edit-off


########################################
# Store admin credentials safely
########################################

mkdir -p /etc/gpu-monitoring

cat >/etc/gpu-monitoring/admin-credentials <<EOF
Grafana Admin
=============
URL: http://127.0.0.1:3000/login
Username: admin
Password: ${ADMIN_PASSWORD}

Normal users do NOT need these credentials.
EOF

chmod 600 /etc/gpu-monitoring/admin-credentials


########################################
# Final verification
########################################

info "VERIFYING INSTALLATION"

echo
echo "Docker containers:"
docker compose ps

echo
echo "Guardian:"
systemctl --no-pager --full status gpu-guardian.service | head -15 || true


GPU_STATUS="$(
    curl -fsSG \
      http://127.0.0.1:9090/api/v1/query \
      --data-urlencode 'query=gpu_status_code' \
      || true
)"

echo "$GPU_STATUS" | grep -q '"status":"success"' \
    || fail "gpu_status_code query failed."


OVERALL_STATUS="$(
    curl -fsSG \
      http://127.0.0.1:9090/api/v1/query \
      --data-urlencode 'query=overall_health_score' \
      || true
)"

echo "$OVERALL_STATUS" | grep -q '"status":"success"' \
    || fail "overall_health_score query failed."


echo
echo "============================================================"
echo " GPU MONITORING INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Dashboard:"
echo "${DASH_URL}"
echo
echo "Normal users:"
echo "  No login required."
echo "  Dashboard is view-only."
echo
echo "Admin maintenance:"
echo "  sudo gpu-monitor-edit-on"
echo "  sudo gpu-monitor-edit-off"
echo
echo "Admin credentials:"
echo "  sudo cat /etc/gpu-monitoring/admin-credentials"
echo
echo "GPU Guardian:"
echo "  systemctl status gpu-guardian"
echo
echo "Docker stack:"
echo "  cd /opt/gpu-monitoring"
echo "  sudo docker compose ps"
echo
echo "The dashboard will:"
echo "  - start automatically with the system"
echo "  - open when a desktop user logs in"
echo "  - open whenever Chrome is started"
echo "  - remain available from the managed bookmark"
echo
echo "Installer log:"
echo "  ${LOG}"
echo
echo "A reboot is recommended after the first installation."
echo
