# Proxmox HDD VM Fanwall Control

Host-level fan control for Proxmox using HDD temperatures from an Unraid VM via virtiofs, with safe fallbacks and systemd integration.

## Features

- Uses HDD temps from Unraid (smartctl)
- No networking required (virtiofs)
- Safe fallback if data is stale/missing
- Systemd-based control loop
- Config-driven behavior
- Never drops below safe PWM floor

## Architecture

Unraid VM → virtiofs → Proxmox host → fan wall PWM

## Install

### Proxmox
./deploy-proxmox.sh

### Unraid
./deploy-unraid.sh

## Uninstall

./uninstall-proxmox.sh
./uninstall-unraid.sh

## Logs

journalctl -t fan-control
journalctl -t fan-control-virtiofs

## Notes

- Requires virtiofs mapping configured in Proxmox
- Requires smartctl installed in Unraid