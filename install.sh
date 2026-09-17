#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="gpu-monitoring"
INSTALL_DIR="/opt/${APP_NAME}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DASH_RESOURCE_NAME="gpu-monitoring"
DASH_URL=""

LOG="/tmp/gpu-monitoring-install.log"

# Private per-run workspace.
# Avoid predictable /tmp filenames that can collide with files left by
# previous installer runs or files owned by another user.
TMP_DIR="$(mktemp -d /tmp/gpu-monitoring-install.XXXXXXXXXX)"
chmod 700 "$TMP_DIR"

cleanup_tmp() {
    rm -rf "$TMP_DIR"
}

trap cleanup_tmp EXIT

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

# Do not contact every configured APT repository unnecessarily.
# Deployment machines may contain unrelated third-party repositories that
# are temporarily unavailable. If all required base packages are already
# installed, continue without running apt-get update.
BASE_PACKAGES=(
    ca-certificates
    curl
    gnupg
    jq
    openssl
    libnotify-bin
    procps
)

MISSING_BASE_PACKAGES=()

for pkg in "${BASE_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
         grep -q '^install ok installed$'; then
        MISSING_BASE_PACKAGES+=("$pkg")
    fi
done

if (( ${#MISSING_BASE_PACKAGES[@]} > 0 )); then
    echo "Missing base packages: ${MISSING_BASE_PACKAGES[*]}"
    echo "Refreshing APT metadata..."

    apt-get         -o Acquire::Retries=1         -o Acquire::http::Timeout=15         -o Acquire::https::Timeout=15         update         || fail "APT metadata refresh failed. Check configured APT repositories."

    apt-get install -y "${MISSING_BASE_PACKAGES[@]}"         || fail "Could not install required base packages."
else
    echo "All base requirements already installed; skipping apt-get update."
fi


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

# Docker may be installed through Ubuntu/Debian packages, Docker CE,
# or Snap. Only manage docker.service when that systemd unit exists.
if systemctl list-unit-files docker.service >/dev/null 2>&1; then
    systemctl enable --now docker
fi

# The authoritative check is whether the Docker daemon is reachable.
if ! docker info >/dev/null 2>&1; then
    fail "Docker is installed, but the Docker daemon is not reachable."
fi

echo "Docker: $(docker --version)"

if [[ "$(command -v docker)" == /snap/* ]]; then
    echo "Docker installation: Snap"
elif systemctl list-unit-files docker.service >/dev/null 2>&1; then
    echo "Docker installation: systemd-managed"
else
    echo "Docker installation: externally managed"
fi


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


# V2 dashboard is installed through Grafana's API after Grafana
# becomes healthy. Do not provision the V2 resource as a classic
# file dashboard and do not modify the canonical JSON here.

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


########################################
# Install Grafana V2 dashboard
########################################

echo "Preparing Grafana V2 dashboard..."

# Existing Grafana volumes may contain an admin password that predates
# the current .env file. Synchronize it before using authenticated APIs.
docker exec grafana \
    grafana cli admin reset-admin-password "$ADMIN_PASSWORD" \
    >/dev/null \
    || fail "Could not synchronize Grafana admin password."


# Discover the actual Prometheus datasource UID generated by Grafana.
DATASOURCES="$(
    curl -fsS \
      -u "admin:${ADMIN_PASSWORD}" \
      http://127.0.0.1:3000/api/datasources
)" || fail "Could not query Grafana datasources."


PROM_UID="$(
    printf '%s' "$DATASOURCES" |
    jq -r '
      [
        .[]
        | select(
            .name == "Prometheus"
            and .type == "prometheus"
          )
      ]
      | if length == 1
        then .[0].uid
        else empty
        end
    '
)"


[[ -n "$PROM_UID" && "$PROM_UID" != "null" ]] \
    || fail "Could not uniquely resolve the Prometheus datasource UID."


echo "Prometheus datasource UID resolved."


# Verify the datasource itself before creating the dashboard.
PROM_DS_HTTP="$(
    curl -sS \
      -u "admin:${ADMIN_PASSWORD}" \
      -o ${TMP_DIR}/prometheus-health.json \
      -w '%{http_code}' \
      "http://127.0.0.1:3000/api/datasources/uid/${PROM_UID}/health"
)"


[[ "$PROM_DS_HTTP" == "200" ]] \
    || fail "Grafana Prometheus datasource health check failed."


V2_SOURCE="$INSTALL_DIR/grafana/dashboards/gpu-monitoring-dashboard-v2.json"
V2_RUNTIME="${TMP_DIR}/dashboard-runtime.json"


[[ -f "$V2_SOURCE" ]] \
    || fail "Canonical Grafana V2 dashboard is missing."


# Never modify the canonical dashboard.
# Patch only a temporary runtime payload with this machine's
# actual Prometheus datasource UID.
python3 - "$V2_SOURCE" "$V2_RUNTIME" "$PROM_UID" "$DASH_RESOURCE_NAME" <<'PYV2'
import json
import sys

source, destination, prometheus_uid, expected_resource_name = sys.argv[1:5]

with open(source) as f:
    data = json.load(f)

if data.get("apiVersion") != "dashboard.grafana.app/v2":
    raise SystemExit("Dashboard is not a Grafana V2 resource.")

metadata = data.setdefault("metadata", {})

if metadata.get("name") != expected_resource_name:
    raise SystemExit(
        "Unexpected dashboard resource name: "
        + repr(metadata.get("name"))
        + "; expected "
        + repr(expected_resource_name)
    )

layout = data.get("spec", {}).get("layout", {})

if layout.get("kind") != "TabsLayout":
    raise SystemExit("Canonical dashboard does not contain TabsLayout.")

tabs = [
    tab.get("spec", {}).get("title")
    for tab in layout.get("spec", {}).get("tabs", [])
]

if tabs != ["Dashboard", "Guidance"]:
    raise SystemExit(
        "Unexpected dashboard tabs: " + repr(tabs)
    )

replacement_count = 0

def patch(obj):
    global replacement_count

    if isinstance(obj, dict):
        # Grafana V2 Prometheus query datasource reference:
        # {"group":"prometheus","datasource":{"name":"<uid>"}}
        if obj.get("group") == "prometheus":
            datasource = obj.get("datasource")

            if isinstance(datasource, dict) and "name" in datasource:
                datasource["name"] = prometheus_uid
                replacement_count += 1

        for value in obj.values():
            patch(value)

    elif isinstance(obj, list):
        for value in obj:
            patch(value)

patch(data)

if replacement_count == 0:
    raise SystemExit(
        "No Prometheus datasource references were found in the V2 dashboard."
    )

# Machine/database-owned metadata must not be imported.
for key in (
    "uid",
    "resourceVersion",
    "generation",
    "creationTimestamp",
    "annotations",
    "labels",
):
    metadata.pop(key, None)

data.setdefault("spec", {})["editable"] = False

with open(destination, "w") as f:
    json.dump(data, f, indent=2)

print(
    f"Prepared runtime dashboard with "
    f"{replacement_count} Prometheus datasource references."
)
PYV2


# Decide whether this is a CREATE or UPDATE.
EXISTING_HTTP="$(
    curl -sS \
      -u "admin:${ADMIN_PASSWORD}" \
      -o ${TMP_DIR}/existing-v2.json \
      -w '%{http_code}' \
      "http://127.0.0.1:3000/apis/dashboard.grafana.app/v2/namespaces/default/dashboards/${DASH_RESOURCE_NAME}"
)"


if [[ "$EXISTING_HTTP" == "200" ]]; then

    RESOURCE_VERSION="$(
        jq -r '.metadata.resourceVersion // empty' \
          ${TMP_DIR}/existing-v2.json
    )"

    [[ -n "$RESOURCE_VERSION" ]] \
        || fail "Existing V2 dashboard has no resourceVersion."

    jq \
      --arg rv "$RESOURCE_VERSION" \
      '.metadata.resourceVersion = $rv' \
      "$V2_RUNTIME" \
      > "${V2_RUNTIME}.update"

    mv "${V2_RUNTIME}.update" "$V2_RUNTIME"

    DASH_HTTP="$(
        curl -sS \
          -u "admin:${ADMIN_PASSWORD}" \
          -H 'Content-Type: application/json' \
          -H 'Accept: application/json' \
          -X PUT \
          --data-binary @"$V2_RUNTIME" \
          -o ${TMP_DIR}/v2-response.json \
          -w '%{http_code}' \
          "http://127.0.0.1:3000/apis/dashboard.grafana.app/v2/namespaces/default/dashboards/${DASH_RESOURCE_NAME}"
    )"

    [[ "$DASH_HTTP" == "200" ]] \
        || fail "Grafana V2 dashboard update failed (HTTP ${DASH_HTTP})."

elif [[ "$EXISTING_HTTP" == "404" ]]; then

    DASH_HTTP="$(
        curl -sS \
          -u "admin:${ADMIN_PASSWORD}" \
          -H 'Content-Type: application/json' \
          -H 'Accept: application/json' \
          -X POST \
          --data-binary @"$V2_RUNTIME" \
          -o ${TMP_DIR}/v2-response.json \
          -w '%{http_code}' \
          'http://127.0.0.1:3000/apis/dashboard.grafana.app/v2/namespaces/default/dashboards'
    )"

    [[ "$DASH_HTTP" == "201" ]] \
        || fail "Grafana V2 dashboard creation failed (HTTP ${DASH_HTTP})."

else
    fail "Could not determine whether V2 dashboard exists (HTTP ${EXISTING_HTTP})."
fi


# Read it back from Grafana rather than trusting the request.
curl -fsS \
  -u "admin:${ADMIN_PASSWORD}" \
  "http://127.0.0.1:3000/apis/dashboard.grafana.app/v2/namespaces/default/dashboards/${DASH_RESOURCE_NAME}" \
  > ${TMP_DIR}/installed-v2.json \
  || fail "Could not read installed V2 dashboard."


INSTALLED_LAYOUT="$(
    jq -r '.spec.layout.kind // empty' \
      ${TMP_DIR}/installed-v2.json
)"

[[ "$INSTALLED_LAYOUT" == "TabsLayout" ]] \
    || fail "Installed dashboard is not TabsLayout."


INSTALLED_TABS="$(
    jq -r \
      '.spec.layout.spec.tabs[].spec.title' \
      ${TMP_DIR}/installed-v2.json |
    paste -sd '|' -
)"

[[ "$INSTALLED_TABS" == "Dashboard|Guidance" ]] \
    || fail "Installed dashboard does not contain Dashboard and Guidance tabs."


INSTALLED_DS_UIDS="$(
    jq -r '
      .. | objects
      | select(.group? == "prometheus")
      | .datasource.name? // empty
    ' ${TMP_DIR}/installed-v2.json |
    sort -u
)"

[[ "$INSTALLED_DS_UIDS" == "$PROM_UID" ]] \
    || fail "Installed dashboard datasource UID does not match live Prometheus UID."


########################################
# Configure anonymous dashboard access
########################################

# Anonymous Grafana users run with the Viewer organization role.
# V2 dashboards created through the API do not necessarily receive
# dashboard ACL entries automatically, so explicitly grant Viewer
# read-only access to this dashboard.
VIEWER_PERMISSION_HTTP="$(
    curl -sS \
      -u "admin:${ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X POST \
      -o ${TMP_DIR}/viewer-permission.json \
      -w '%{http_code}' \
      "http://127.0.0.1:3000/api/dashboards/uid/${DASH_RESOURCE_NAME}/permissions" \
      --data '{
        "items": [
          {
            "role": "Viewer",
            "permission": 1
          }
        ]
      }'
)"

[[ "$VIEWER_PERMISSION_HTTP" == "200" ]] \
    || fail "Could not grant Viewer read access to GPU Monitoring dashboard."


# Verify the permission Grafana actually stored.
VIEWER_PERMISSION_COUNT="$(
    curl -fsS \
      -u "admin:${ADMIN_PASSWORD}" \
      "http://127.0.0.1:3000/api/dashboards/uid/${DASH_RESOURCE_NAME}/permissions" |
    jq '
      [
        .[]
        | select(
            .role == "Viewer"
            and .permission == 1
          )
      ]
      | length
    '
)" || fail "Could not verify GPU Monitoring dashboard permissions."


[[ "$VIEWER_PERMISSION_COUNT" == "1" ]] \
    || fail "Viewer read permission was not stored correctly."


# Most important verification:
# test the same V2 DTO endpoint that an anonymous browser uses.
ANON_DTO_HTTP="$(
    curl -sS \
      -o ${TMP_DIR}/anonymous-dto.json \
      -w '%{http_code}' \
      "http://127.0.0.1:3000/apis/dashboard.grafana.app/v2/namespaces/default/dashboards/${DASH_RESOURCE_NAME}/dto"
)"

[[ "$ANON_DTO_HTTP" == "200" ]] \
    || fail "Anonymous Viewer cannot read the GPU Monitoring V2 dashboard."


echo "PASS: anonymous Viewer has read-only dashboard access."


# Never guess the browser URL.
# Ask Grafana directly for the dashboard identified by our controlled UID,
# then use the browser path Grafana itself registered.
DASH_LOOKUP="$(
    curl -fsS \
      -u "admin:${ADMIN_PASSWORD}" \
      "http://127.0.0.1:3000/api/dashboards/uid/${DASH_RESOURCE_NAME}"
)" || fail "Could not resolve dashboard through Grafana classic API."


LOOKUP_UID="$(
    printf '%s' "$DASH_LOOKUP" |
    jq -r '.dashboard.uid // empty'
)"

[[ "$LOOKUP_UID" == "$DASH_RESOURCE_NAME" ]] \
    || fail "Grafana dashboard lookup returned an unexpected UID."


DASH_PATH="$(
    printf '%s' "$DASH_LOOKUP" |
    jq -r '.meta.url // empty'
)"


[[ "$DASH_PATH" == /d/* ]] \
    || fail "Grafana returned an invalid dashboard browser URL."


DASH_URL="http://127.0.0.1:3000${DASH_PATH}?from=now-30m&to=now&timezone=browser&refresh=30s&dtab=Dashboard&kiosk&hideLogo=true"


echo "PASS: Grafana V2 dashboard installed and verified."
echo "Dashboard path resolved by Grafana: ${DASH_PATH}"


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
    exec google-chrome --new-window "\$URL"

elif command -v google-chrome-stable >/dev/null 2>&1; then
    exec google-chrome-stable --new-window "\$URL"

elif command -v chromium >/dev/null 2>&1; then
    exec chromium --new-window "\$URL"

elif command -v chromium-browser >/dev/null 2>&1; then
    exec chromium-browser --new-window "\$URL"

else
    echo "ERROR: No supported browser found." >&2
    exit 1
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
# Generate it from the dashboard URL resolved from Grafana.
# Never keep a machine-specific dashboard UID in the browser policy.
mkdir -p /etc/opt/chrome/policies/managed

python3 - "$DASH_URL" \
    /etc/opt/chrome/policies/managed/gpu-monitoring.json <<'PYCHROME'
import json
import sys

url, destination = sys.argv[1:3]

if not url.startswith("http://127.0.0.1:3000/d/"):
    raise SystemExit("Refusing invalid Grafana dashboard URL: " + repr(url))

policy = {
    "RestoreOnStartup": 4,
    "RestoreOnStartupURLs": [url],
    "BackgroundModeEnabled": False,
    "BookmarkBarEnabled": True,
    "ManagedBookmarks": [
        {
            "toplevel_name": "Lab Tools"
        },
        {
            "name": "GPU Monitoring",
            "url": url
        }
    ]
}

with open(destination, "w") as f:
    json.dump(policy, f, indent=2)

print("Chrome policy generated from resolved Grafana dashboard URL.")
PYCHROME

chmod 644 \
    /etc/opt/chrome/policies/managed/gpu-monitoring.json


########################################
# Dashboard edit commands
########################################

cat >/usr/local/bin/gpu-monitor-edit-on <<'EOF'
#!/bin/bash

echo "Dashboard is managed as a Grafana V2 resource."
echo "Use the Grafana admin UI for maintenance:"
echo "http://127.0.0.1:3000/login"
echo
echo "The production installer keeps the deployed dashboard view-only."
EOF

chmod 755 /usr/local/bin/gpu-monitor-edit-on


cat >/usr/local/bin/gpu-monitor-edit-off <<'EOF'
#!/bin/bash

echo "GPU Monitoring dashboard is already deployed view-only."
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
