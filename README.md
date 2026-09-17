# GPU Workstation Monitor

A GPU monitoring and safety system for NVIDIA Linux workstations.

It combines Grafana, Prometheus, NVIDIA DCGM Exporter, Node Exporter,
and an independent GPU Guardian service to provide real-time monitoring,
health detection, and workstation-level GPU safety.

## Features

- Real-time NVIDIA GPU monitoring
- GPU utilization, temperature, VRAM, power, and clock monitoring
- Prometheus-based GPU health rules
- Independent GPU Guardian safety service
- Grafana monitoring dashboard
- Anonymous view-only access for normal users
- Administrator-only dashboard editing
- Grafana kiosk mode
- Automatic startup after reboot
- Automatic Chrome dashboard opening
- Managed Chrome bookmark
- Repeatable deployment across workstations

## Requirements

- Ubuntu / Debian Linux
- NVIDIA GPU
- Working NVIDIA driver (`nvidia-smi`)
- Internet connection during installation
- Graphical desktop recommended for automatic dashboard opening

## Quick Installation

Run:

    cd "$HOME" && \
    rm -rf "$HOME/gpu-workstation-monitor" && \
    git clone https://github.com/iammawaistariq/gpu-workstation-monitor.git "$HOME/gpu-workstation-monitor" && \
    cd "$HOME/gpu-workstation-monitor" && \
    chmod +x install.sh && \
    sudo ./install.sh

The installer automatically configures the required monitoring services,
dashboard, GPU Guardian, access controls, and browser integration.

A reboot is recommended after the first installation.

## Dashboard Access

The dashboard opens automatically through the configured Chrome integration.

Normal workstation users:

- Do not need a Grafana login
- Receive view-only access
- Use the dashboard in Grafana kiosk mode
- Cannot modify dashboard panels or Grafana configuration

Grafana and Prometheus are bound to localhost by default.

## Administrator Access

Enable administrator/edit mode:

    sudo gpu-monitor-edit-on

Display the locally generated administrator credentials:

    sudo cat /etc/gpu-monitoring/admin-credentials

When administration is complete, return the dashboard to normal view-only mode:

    sudo gpu-monitor-edit-off

## Complete Administration Guide

For Grafana administrator login, dashboard UI editing, service management,
health checks, troubleshooting, maintenance, updates, and deployment on
additional workstations, see:

**[Administrator & Maintenance Guide](docs/ADMIN-GUIDE.md)**

## Core Services

| Service | Purpose |
|---|---|
| Grafana | Dashboard and visualization |
| Prometheus | Metrics collection and health rules |
| DCGM Exporter | NVIDIA GPU telemetry |
| Node Exporter | Linux system telemetry |
| GPU Guardian | Independent GPU safety monitoring |

## Service Status

Monitoring stack:

    cd $HOME/gpu-monitoring/runtime
    sudo docker compose ps

GPU Guardian:

    systemctl status gpu-guardian

GPU:

    nvidia-smi

## Important Locations

Installed application:

    $HOME/gpu-monitoring/runtime

Administrator credentials:

    /etc/gpu-monitoring/admin-credentials

Grafana:

    http://127.0.0.1:3000

Prometheus:

    http://127.0.0.1:9090

