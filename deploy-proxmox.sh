#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE_CONFIG="no"

usage() {
  cat <<'EOF'
Usage: ./deploy-proxmox.sh [--force-config]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force-config)
      FORCE_CONFIG="yes"
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

install -Dm755 "$BASE_DIR/proxmox/usr-local-sbin/hdd_fanwall_control.sh" /usr/local/sbin/hdd_fanwall_control.sh
install -Dm644 "$BASE_DIR/proxmox/systemd/hdd-fanwall-control.service" /etc/systemd/system/hdd-fanwall-control.service
install -Dm644 "$BASE_DIR/proxmox/systemd/hdd-fanwall-control.timer" /etc/systemd/system/hdd-fanwall-control.timer

if [ ! -f /etc/hdd-fanwall-control.cfg ] || [ "$FORCE_CONFIG" = "yes" ]; then
  if [ -f /etc/hdd-fanwall-control.cfg ] && [ "$FORCE_CONFIG" = "yes" ]; then
    cp -a /etc/hdd-fanwall-control.cfg "/etc/hdd-fanwall-control.cfg.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -Dm644 "$BASE_DIR/proxmox/etc/hdd-fanwall-control.cfg" /etc/hdd-fanwall-control.cfg
else
  echo "Keeping existing /etc/hdd-fanwall-control.cfg"
fi

mkdir -p /var/lib/fan-control/vm-unraid-hdd
chmod 755 /var/lib/fan-control
chmod 755 /var/lib/fan-control/vm-unraid-hdd

systemctl daemon-reload

if /usr/local/sbin/hdd_fanwall_control.sh --validate-only >/dev/null; then
  systemctl enable --now hdd-fanwall-control.timer
  echo "Proxmox deployment complete. Timer enabled."
else
  echo "Files installed, but validation failed. Timer was not enabled." >&2
  echo "Run /usr/local/sbin/hdd_fanwall_control.sh --validate-only after fixing config or hwmon path." >&2
  exit 1
fi
