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

# Validate the selected config with the new controller before touching production.
selected_config=/etc/hdd-fanwall-control.cfg
if [ ! -f "$selected_config" ] || [ "$FORCE_CONFIG" = yes ]; then
  selected_config="$BASE_DIR/proxmox/etc/hdd-fanwall-control.cfg"
fi
if ! CONFIG_FILE="$selected_config" bash "$BASE_DIR/proxmox/usr-local-sbin/hdd_fanwall_control.sh" --validate-only; then
  echo "Preflight failed; installed files and timer were not changed." >&2
  echo "For an older config, review the production defaults and use --force-config." >&2
  exit 1
fi

backup_dir="$(mktemp -d /var/tmp/hdd-fanwall-deploy.XXXXXXXX)"
files=(/usr/local/sbin/hdd_fanwall_control.sh /etc/hdd-fanwall-control.cfg
  /etc/systemd/system/hdd-fanwall-control.service /etc/systemd/system/hdd-fanwall-control.timer)
for file in "${files[@]}"; do
  [ ! -f "$file" ] || cp -p "$file" "$backup_dir/"
done
timer_active=no timer_enabled=no
if systemctl is-active --quiet hdd-fanwall-control.timer; then timer_active=yes; fi
if systemctl is-enabled --quiet hdd-fanwall-control.timer; then timer_enabled=yes; fi
rollback() {
  local result=$?
  trap - EXIT
  if [ "$result" -ne 0 ]; then
    echo "Deployment failed; restoring previous files from $backup_dir" >&2
    systemctl stop hdd-fanwall-control.timer hdd-fanwall-control.service || true
    for file in "${files[@]}"; do
      if [ -f "$backup_dir/${file##*/}" ]; then
        cp -p "$backup_dir/${file##*/}" "$file"
      else
        rm -f -- "$file"
      fi
    done
    systemctl daemon-reload
    if [ "$timer_enabled" = yes ]; then
      systemctl enable hdd-fanwall-control.timer
    else
      systemctl disable hdd-fanwall-control.timer || true
    fi
    if [ "$timer_active" = yes ]; then systemctl start hdd-fanwall-control.timer; fi
  fi
  exit "$result"
}
trap rollback EXIT
# Avoid a running controller observing a partially replaced script/config pair.
if [ -f /etc/systemd/system/hdd-fanwall-control.timer ]; then
  systemctl stop hdd-fanwall-control.timer hdd-fanwall-control.service
fi

install -Dm755 "$BASE_DIR/proxmox/usr-local-sbin/hdd_fanwall_control.sh" /usr/local/sbin/hdd_fanwall_control.sh
install -Dm644 "$BASE_DIR/proxmox/systemd/hdd-fanwall-control.service" /etc/systemd/system/hdd-fanwall-control.service
install -Dm644 "$BASE_DIR/proxmox/systemd/hdd-fanwall-control.timer" /etc/systemd/system/hdd-fanwall-control.timer
if [ "$selected_config" != /etc/hdd-fanwall-control.cfg ]; then
  if [ -f /etc/hdd-fanwall-control.cfg ]; then
    cp -a /etc/hdd-fanwall-control.cfg "/etc/hdd-fanwall-control.cfg.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -Dm644 "$selected_config" /etc/hdd-fanwall-control.cfg
fi
install -d -m755 /var/lib/fan-control /var/lib/fan-control/vm-unraid-hdd
systemctl daemon-reload
systemctl enable hdd-fanwall-control.timer
systemctl restart hdd-fanwall-control.timer
systemctl start hdd-fanwall-control.service
trap - EXIT
echo "Proxmox deployment complete. Timer restarted; backup: $backup_dir"
