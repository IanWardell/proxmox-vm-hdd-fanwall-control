#!/bin/bash
set -euo pipefail

systemctl disable --now hdd-fanwall-control.timer || true

rm -f /etc/systemd/system/hdd-fanwall-control.timer
rm -f /etc/systemd/system/hdd-fanwall-control.service
rm -f /usr/local/sbin/hdd_fanwall_control.sh

systemctl daemon-reload

echo "Proxmox uninstall complete."