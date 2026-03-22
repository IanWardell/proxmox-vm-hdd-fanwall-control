#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

install -Dm755 "$BASE_DIR/unraid/boot-config-custom/hdd_temp_export_virtiofs.sh" /boot/config/custom/hdd_temp_export_virtiofs.sh
install -Dm644 "$BASE_DIR/unraid/boot-config-custom/hdd_temp_export_virtiofs.conf" /boot/config/custom/hdd_temp_export_virtiofs.conf

echo "Unraid deployment complete."
echo "Add to cron or User Scripts to run every minute."