# GPU Workstation Monitor

A deployable monitoring and safety stack for NVIDIA-powered Linux workstations.

It provides real-time GPU and system monitoring using **Grafana, Prometheus, NVIDIA DCGM Exporter, Node Exporter, and GPU Guardian**.

Designed for AI/ML workstations, research labs, training machines, and shared GPU systems.

---

## Features

- Real-time NVIDIA GPU monitoring
- GPU temperature, utilization, VRAM, clock and power monitoring
- CPU and RAM monitoring
- Overall GPU, CPU, memory and system health scores
- GPU operating-state detection
- Grafana dashboard with dedicated Guidance tab
- Prometheus health and scoring rules
- NVIDIA DCGM Exporter
- Node Exporter
- GPU Guardian safety service
- Automatic startup after reboot
- Anonymous view-only dashboard access
- No login required for normal users
- Administrator-only edit mode
- Automatic Chrome dashboard opening
- Managed Chrome bookmark
- Linux application shortcut
- Docker-based deployment
- Automatic dependency installation
- Installation verification and health checks

---

## GPU Status Detection

The dashboard can report:

- IDLE
- ACTIVE — HEALTHY
- HIGH TEMPERATURE
- REDUCED CLOCK
- VRAM PRESSURE
- VRAM CRITICAL
- POSSIBLE POWER THROTTLING
- POSSIBLE THERMAL THROTTLING
- EMERGENCY

---

## Architecture

    NVIDIA GPU
        |
        +--> DCGM Exporter --------+
                                   |
    Linux System                   |
        |                          |
        +--> Node Exporter --------+--> Prometheus
                                          |
                                          +--> Health Rules
                                          |
                                          +--> Grafana
                                                 |
                                                 +--> Dashboard
                                                 +--> Guidance

    NVIDIA GPU
        |
        +--> GPU Guardian
                |
                +--> Safety monitoring
                +--> Desktop warnings
                +--> Emergency detection

---

## Components

| Component | Purpose |
|---|---|
| Grafana | Monitoring dashboard and visualization |
| Prometheus | Metrics collection and health-rule evaluation |
| DCGM Exporter | NVIDIA GPU telemetry |
| Node Exporter | CPU, RAM and Linux system telemetry |
| GPU Guardian | Independent GPU safety monitor |
| systemd | Automatic Guardian startup and recovery |
| Chrome Policy | Dashboard startup and managed bookmark |

---

## Supported Systems

Currently designed for:

- Ubuntu / Debian Linux
- NVIDIA GPU
- Working NVIDIA proprietary driver with `nvidia-smi`
- x86_64 / amd64 recommended
- Graphical Linux desktop for automatic dashboard opening

The installer verifies that the NVIDIA GPU driver is operational before continuing.

---

## Quick Installation

Clone and install with one command block:

    git clone https://github.com/iammawaistariq/gpu-workstation-monitor.git && \
    cd gpu-workstation-monitor && \
    chmod +x install.sh && \
    sudo ./install.sh

The installer configures the monitoring stack and required dependencies automatically.

A reboot is recommended after the first installation.

---

## Dashboard Access

After installation, the installer resolves the dashboard URL directly from Grafana.

The final dashboard URL is printed at the end of installation and is also configured automatically in the Chrome integration.

The monitoring dashboard opens automatically through the configured Chrome policy.

Normal workstation users do **not** need a Grafana login.

---

## Access Model

Normal users:

- No username or password required
- View-only dashboard
- Cannot edit dashboard panels
- Cannot modify Grafana configuration

Grafana and Prometheus are bound to localhost by default.

---

## Administrator Edit Mode

Temporarily enable dashboard editing:

    sudo gpu-monitor-edit-on

View locally generated administrator credentials:

    sudo cat /etc/gpu-monitoring/admin-credentials

When finished, return to normal locked mode:

    sudo gpu-monitor-edit-off

Administrator credentials are generated locally during installation and are **not stored in this repository**.

---

## GPU Guardian

GPU Guardian runs independently as a system-level service.

Check status:

    systemctl status gpu-guardian

View recent activity:

    sudo tail -50 /var/log/gpu-monitoring/guardian.log

GPU Guardian monitors:

- GPU temperature
- GPU power
- VRAM usage
- Warning state
- Critical state
- Emergency state

Automatic workload termination is currently disabled:

    DRY_RUN=true

This provides a safe default while the protection logic is being validated across different systems.

---

## Docker Services

Check the monitoring stack:

    cd /opt/gpu-monitoring
    sudo docker compose ps

Expected services:

- grafana
- prometheus
- dcgm-exporter
- node-exporter

---

## Automatic Startup

After installation:

- Docker starts automatically
- Monitoring containers restart automatically
- GPU Guardian starts automatically
- Grafana becomes available automatically
- Dashboard opens when a graphical user logs in
- Dashboard opens whenever Chrome is started
- GPU Monitoring remains available through the managed Chrome bookmark

---

## Repository Structure

    gpu-workstation-monitor/
    ├── browser/
    │   ├── gpu-monitoring-autostart.desktop
    │   └── gpu-monitoring.desktop
    │
    ├── grafana/
    │   ├── dashboards/
    │   │   └── gpu-monitoring-dashboard-v2.json
    │   └── provisioning/
    │       └── datasources/
    │           └── prometheus.yml
    │
    ├── guardian/
    │   ├── gpu-guardian.service
    │   └── gpu_guardian_daemon.sh
    │
    ├── prometheus/
    │   ├── prometheus.yml
    │   └── rules/
    │       └── gpu_health_rules.yml
    │
    ├── docker-compose.yml
    ├── install.sh
    ├── .gitignore
    └── README.md

---

## Monitoring Philosophy

High GPU utilization is **not automatically treated as a problem**.

AI training, inference, rendering and other compute-heavy workloads may legitimately use close to **100% GPU utilization**.

The monitoring logic therefore evaluates related conditions together, including:

- GPU temperature
- GPU clock behavior
- Power consumption
- VRAM pressure
- CPU health
- System memory health

For example:

- High utilization + safe temperature + normal clock = healthy workload
- Low clock while idle = normal power saving
- High utilization + low clock + high temperature = possible thermal throttling

---

## Installation Logs

If installation fails, inspect:

    cat /tmp/gpu-monitoring-install.log

The installer performs configuration and service checks before reporting successful installation.

---

## Updating

Pull the latest version:

    git pull

Then rerun:

    sudo ./install.sh

---

## Important Notes

The installer intentionally does **not** automatically replace the NVIDIA display driver.

GPU driver installation may depend on:

- GPU model
- Linux kernel version
- operating-system version
- workstation configuration

The installer instead verifies that `nvidia-smi` is operational before deployment continues.

---

## Author

**Muhammad Awais Tariq**

GitHub: https://github.com/iammawaistariq

---

## Project Status

Active development.

Current focus:

- reliable NVIDIA workstation monitoring
- GPU/system health visualization
- safe view-only deployment
- automated installation
- GPU safety monitoring
- reproducible multi-workstation deployment
