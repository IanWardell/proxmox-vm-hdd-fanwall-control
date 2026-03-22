#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE_CONFIG="no"

usage() {
  cat <<'EOF'
Usage: ./deploy-unraid.sh [--force-config]
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

install -Dm755 "$BASE_DIR/unraid/boot-config-custom/hdd_temp_export_virtiofs.sh" /boot/config/custom/hdd_temp_export_virtiofs.sh

if [ ! -f /boot/config/custom/hdd_temp_export_virtiofs.conf ] || [ "$FORCE_CONFIG" = "yes" ]; then
  if [ -f /boot/config/custom/hdd_temp_export_virtiofs.conf ] && [ "$FORCE_CONFIG" = "yes" ]; then
    cp -a /boot/config/custom/hdd_temp_export_virtiofs.conf "/boot/config/custom/hdd_temp_export_virtiofs.conf.bak.$(date +%Y%m%d%H%M%S)"
  fi
  install -Dm644 "$BASE_DIR/unraid/boot-config-custom/hdd_temp_export_virtiofs.conf" /boot/config/custom/hdd_temp_export_virtiofs.conf
else
  echo "Keeping existing /boot/config/custom/hdd_temp_export_virtiofs.conf"
fi

echo "Unraid deployment complete."
echo "Next steps:"
echo "  1. Mount the virtiofs share at /mnt/proxmox-fan"
echo "  2. Add that mount to startup"
echo "  3. Schedule /boot/config/custom/hdd_temp_export_virtiofs.sh every minute"
