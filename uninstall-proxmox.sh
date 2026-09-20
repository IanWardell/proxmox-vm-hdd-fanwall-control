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

# Never guess the driver's automatic-control mode. Leave full cooling on removal.
if [ -f /usr/local/sbin/hdd_fanwall_control.sh ]; then
  active_hwmon="$(bash /usr/local/sbin/hdd_fanwall_control.sh --print-hwmon-path)"
  PWM_ENABLE_NAME=pwm2_enable PWM_NAME=pwm2
  # shellcheck disable=SC1091
  source /etc/hdd-fanwall-control.cfg
  timer_active=no
  if systemctl is-active --quiet hdd-fanwall-control.timer; then timer_active=yes; fi
  restore_timer_on_error() {
    local result=$?
    if [ "$result" -ne 0 ] && [ "$timer_active" = yes ]; then
      systemctl start hdd-fanwall-control.timer
    fi
    exit "$result"
  }
  trap restore_timer_on_error EXIT
  systemctl stop hdd-fanwall-control.timer hdd-fanwall-control.service
  exec 9>/run/hdd_fanwall_control.state.lock
  flock -w 30 9
  printf '1\n' > "$active_hwmon/$PWM_ENABLE_NAME"
  printf '255\n' > "$active_hwmon/$PWM_NAME"
  if [ "$(cat "$active_hwmon/$PWM_ENABLE_NAME")" != 1 ] || [ "$(cat "$active_hwmon/$PWM_NAME")" != 255 ]; then
    echo "Cannot verify full-speed fan handoff; controller retained." >&2
    exit 1
  fi
  trap - EXIT
  echo "Fan control handed off at full PWM (255); configure a replacement controller before reducing it."
fi
if [ -f /etc/systemd/system/hdd-fanwall-control.timer ]; then
  systemctl disable --now hdd-fanwall-control.timer
fi

rm -f /etc/systemd/system/hdd-fanwall-control.timer
rm -f /etc/systemd/system/hdd-fanwall-control.service
rm -f /usr/local/sbin/hdd_fanwall_control.sh
rm -f /run/hdd_fanwall_control.state /run/hdd_fanwall_control.state.lock

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
systemctl reset-failed hdd-fanwall-control.service || true

echo "Proxmox uninstall complete."
