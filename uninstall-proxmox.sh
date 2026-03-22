#!/bin/bash
set -euo pipefail

REMOVE_CONFIG="no"
REMOVE_DATA_DIR="no"

usage() {
  cat <<'EOF'
Usage: ./uninstall-proxmox.sh [--remove-config] [--remove-data-dir]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remove-config)
      REMOVE_CONFIG="yes"
      shift
      ;;
    --remove-data-dir)
      REMOVE_DATA_DIR="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

systemctl disable --now hdd-fanwall-control.timer || true
systemctl stop hdd-fanwall-control.service || true

rm -f /etc/systemd/system/hdd-fanwall-control.timer
rm -f /etc/systemd/system/hdd-fanwall-control.service
rm -f /usr/local/sbin/hdd_fanwall_control.sh
rm -f /run/hdd_fanwall_control.state

if [ "$REMOVE_CONFIG" = "yes" ]; then
  rm -f /etc/hdd-fanwall-control.cfg
else
  echo "Keeping /etc/hdd-fanwall-control.cfg"
fi

if [ "$REMOVE_DATA_DIR" = "yes" ]; then
  if [ -d /var/lib/fan-control/vm-unraid-hdd ] && [ -z "$(ls -A /var/lib/fan-control/vm-unraid-hdd 2>/dev/null)" ]; then
    rmdir /var/lib/fan-control/vm-unraid-hdd
    echo "Removed empty /var/lib/fan-control/vm-unraid-hdd"
  else
    echo "Keeping /var/lib/fan-control/vm-unraid-hdd"
  fi
fi

systemctl daemon-reload
systemctl reset-failed || true

echo "Proxmox uninstall complete."
