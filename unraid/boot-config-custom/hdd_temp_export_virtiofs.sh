#!/bin/bash

mkdir -p /mnt/proxmox-fan
mount -t virtiofs vm-unraid-hdd /mnt/proxmox-fan 2>/dev/null

tmp="/mnt/proxmox-fan/hdd_temp_status.env.tmp"

echo "GENERATED_EPOCH=$(date +%s)" > "$tmp"

max=0

for d in /dev/sd?; do
  t=$(smartctl -A "$d" 2>/dev/null | awk '/Temperature_Celsius/ {print $NF}' | head -n1)
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    if [ "$t" -gt "$max" ]; then max="$t"; fi
  fi
done

echo "MAX_TEMP_C=$max" >> "$tmp"

mv "$tmp" /mnt/proxmox-fan/hdd_temp_status.env