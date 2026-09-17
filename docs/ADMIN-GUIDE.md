# GPU Workstation Monitor — Administrator Guide

This guide contains the common administration, Grafana editing, troubleshooting,
deployment, and Git commands for GPU Workstation Monitor.

Normal workstation users use the dashboard in anonymous, view-only kiosk mode.
Administrator mode should only be enabled when dashboard changes are required.

---

## 1. Enable Grafana Administrator / Edit Mode

Enable administrator editing:

    sudo gpu-monitor-edit-on

Display the locally generated Grafana administrator credentials:

    sudo cat /etc/gpu-monitoring/admin-credentials

Open the Grafana login page:

    google-chrome "http://127.0.0.1:3000/login"

Log in using the displayed administrator credentials.

After completing dashboard/UI changes, disable editing again:

    sudo gpu-monitor-edit-off

This returns the installation to its normal view-only configuration.

---

## 2. Check Monitoring Stack

    cd /opt/gpu-monitoring
    sudo docker compose ps

Expected services:

- grafana
- prometheus
- dcgm-exporter
- node-exporter

---

## 3. Restart Monitoring Services

Restart everything:

    cd /opt/gpu-monitoring
    sudo docker compose restart

Restart only Grafana:

    cd /opt/gpu-monitoring
    sudo docker compose restart grafana

Restart only Prometheus:

    cd /opt/gpu-monitoring
    sudo docker compose restart prometheus

---

## 4. View Container Logs

Grafana:

    cd /opt/gpu-monitoring
    sudo docker compose logs --tail=100 grafana

Grafana live logs:

    cd /opt/gpu-monitoring
    sudo docker compose logs -f grafana

Prometheus:

    cd /opt/gpu-monitoring
    sudo docker compose logs --tail=100 prometheus

DCGM exporter:

    cd /opt/gpu-monitoring
    sudo docker compose logs --tail=100 dcgm-exporter

---

## 5. GPU Guardian

Check status:

    sudo systemctl status gpu-guardian

Check whether it is active:

    sudo systemctl is-active gpu-guardian

Restart Guardian:

    sudo systemctl restart gpu-guardian

View recent logs:

    sudo journalctl -u gpu-guardian -n 100 --no-pager

Follow logs live:

    sudo journalctl -u gpu-guardian -f

---

## 6. System Health Checks

Check NVIDIA GPU:

    nvidia-smi

Check Grafana:

    curl -fsS http://127.0.0.1:3000/api/health | jq .

Check Prometheus:

    curl -fsS http://127.0.0.1:9090/-/healthy

Check ports:

    sudo ss -ltnp | grep -E ':3000 |:9090 '

Check Docker containers:

    sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

---

## 7. Important Locations

Installed application:

    /opt/gpu-monitoring

Deployment source checkout:

    ~/gpu-workstation-monitor

Grafana administrator credentials:

    /etc/gpu-monitoring/admin-credentials

Grafana:

    http://127.0.0.1:3000

Prometheus:

    http://127.0.0.1:9090

GPU Guardian service:

    gpu-guardian

The dashboard URL is resolved automatically by install.sh and opened in
Grafana kiosk mode for normal users.

---

## 8. Development Repository Workflow

The development repository is normally:

    ~/gpu-monitoring-package

Check repository:

    cd ~/gpu-monitoring-package
    git status
    git branch --show-current
    git log -5 --oneline --decorate

Review changes:

    git diff
    git diff --stat
    git diff --check

---

## 9. Validate Before Commit

Run:

    cd ~/gpu-monitoring-package
    bash -n install.sh
    docker compose config >/dev/null
    jq empty grafana/dashboards/gpu-monitoring-dashboard-v2.json
    git diff --check

All commands should complete successfully before committing.

---

## 10. Commit and Push Changes

    cd ~/gpu-monitoring-package
    git status
    git diff --stat
    git diff --check
    git add -A
    git status --short
    git diff --cached --check
    git commit -m "Describe the change"
    git push origin main
    git status
    git log -1 --oneline --decorate

---

## 11. Deploy Latest Version on a Workstation

Use this deployment command:

    cd "$HOME" && \
    rm -rf "$HOME/gpu-workstation-monitor" && \
    git clone https://github.com/iammawaistariq/gpu-workstation-monitor.git "$HOME/gpu-workstation-monitor" && \
    cd "$HOME/gpu-workstation-monitor" && \
    chmod +x install.sh && \
    sudo ./install.sh

This replaces the local source checkout with the latest GitHub version.

The installer manages the actual installation under:

    /opt/gpu-monitoring

---

## 12. Verify Deployment

Check deployed Git commit:

    cd ~/gpu-workstation-monitor
    git log -1 --oneline --decorate

Check monitoring services:

    cd /opt/gpu-monitoring
    sudo docker compose ps

Check Guardian:

    sudo systemctl is-active gpu-guardian

Check Grafana:

    curl -fsS http://127.0.0.1:3000/api/health | jq .

Check Prometheus:

    curl -fsS http://127.0.0.1:9090/-/healthy

Check GPU:

    nvidia-smi

---

## 13. Recommended Workflow for Future Changes

Use GitHub as the source of truth:

    Edit development repository
            |
            v
    Validate changes
            |
            v
    Test locally
            |
            v
    git add / commit / push
            |
            v
    Deploy latest GitHub version
            |
            v
    Verify Grafana + Prometheus + Guardian

Avoid manually maintaining different versions of the application under
/opt/gpu-monitoring on individual workstations.
