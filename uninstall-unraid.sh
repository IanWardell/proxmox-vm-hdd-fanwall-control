#!/bin/bash
set -euo pipefail

REMOVE_CONFIG="no"

usage() {
  cat <<'EOF'
Usage: ./uninstall-unraid.sh [--remove-config]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remove-config)
      REMOVE_CONFIG="yes"
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

rm -f /boot/config/custom/hdd_temp_export_virtiofs.sh

if [ "$REMOVE_CONFIG" = "yes" ]; then
  rm -f /boot/config/custom/hdd_temp_export_virtiofs.conf
else
  echo "Keeping /boot/config/custom/hdd_temp_export_virtiofs.conf"
fi

echo "Unraid uninstall complete."
echo "Remove any User Scripts or cron entry separately."
