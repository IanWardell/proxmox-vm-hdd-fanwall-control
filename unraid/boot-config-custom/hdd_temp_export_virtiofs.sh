#!/bin/bash
set -euo pipefail

CONFIG_FILE="/boot/config/custom/hdd_temp_export_virtiofs.conf"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "missing config file: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

log_message() {
  local message="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s %s\n' "$timestamp" "$message" >> "$LOG_FILE"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log_message "ERROR: required command not found: $1"
    exit 1
  }
}

ensure_mount() {
  mkdir -p "$MOUNT_POINT"

  if mountpoint -q "$MOUNT_POINT"; then
    return 0
  fi

  if mount -t virtiofs "$VIRTIOFS_TAG" "$MOUNT_POINT"; then
    log_message "Mounted virtiofs tag=$VIRTIOFS_TAG at $MOUNT_POINT"
    return 0
  fi

  log_message "ERROR: failed to mount virtiofs tag=$VIRTIOFS_TAG at $MOUNT_POINT"
  return 1
}

discover_disks() {
  if [ "$ONLY_ROTATIONAL_DISKS" = "yes" ]; then
    lsblk -dn -o PATH,TYPE,RM,TRAN,ROTA | awk '
      $2 == "disk" &&
      $3 == "0" &&
      $4 != "usb" &&
      $5 == "1" {
        print $1
      }
    '
  else
    lsblk -dn -o PATH,TYPE,RM,TRAN | awk '
      $2 == "disk" &&
      $3 == "0" &&
      $4 != "usb" {
        print $1
      }
    '
  fi
}

extract_temp_c() {
  awk '
    /Current Drive Temperature:/ || /Current Temperature:/ {
      if (match($0, /[0-9]+/)) {
        print substr($0, RSTART, RLENGTH)
        exit
      }
    }
    /Temperature_Celsius|Temperature_Internal|Airflow_Temperature_Cel|Drive_Temperature/ {
      raw = ""
      for (i = 10; i <= NF; i++) {
        raw = raw (raw ? OFS : "") $i
      }
      if (raw == "") {
        raw = $0
      }
      if (match(raw, /[0-9]+/)) {
        print substr(raw, RSTART, RLENGTH)
        exit
      }
    }
  '
}

read_disk_temp() {
  local disk="$1"
  local output
  local temp

  if [ "$SMART_STANDBY_MODE" = "yes" ]; then
    output="$(smartctl -n standby -A "$disk" 2>&1 || true)"
  else
    output="$(smartctl -A "$disk" 2>&1 || true)"
  fi

  if echo "$output" | grep -qiE 'STANDBY|standby mode'; then
    printf 'standby:\n'
    return 0
  fi

  if temp="$(printf '%s\n' "$output" | extract_temp_c)" && [[ "$temp" =~ ^[0-9]+$ ]]; then
    printf 'active:%s\n' "$temp"
    return 0
  fi

  printf 'unknown:\n'
  return 0
}

require_command smartctl
require_command lsblk
require_command mountpoint
require_command flock
require_command mktemp

ensure_mount

lock_file="$MOUNT_POINT/.hdd_temp_export.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  log_message "Another exporter instance is already running"
  exit 0
fi

mapfile -t disks < <(discover_disks)

if [ "${#disks[@]}" -eq 0 ]; then
  log_message "ERROR: no candidate disks discovered"
  exit 1
fi

disk_count=0
temp_count=0
standby_count=0
hot_drive_count=0
max_temp=""

for disk in "${disks[@]}"; do
  [ -b "$disk" ] || continue
  disk_count=$((disk_count + 1))

  result="$(read_disk_temp "$disk")"
  state="${result%%:*}"
  temp="${result#*:}"

  case "$state" in
    standby)
      standby_count=$((standby_count + 1))
      ;;
    active)
      temp_count=$((temp_count + 1))
      if [ -z "$max_temp" ] || [ "$temp" -gt "$max_temp" ]; then
        max_temp="$temp"
      fi
      if [ "$temp" -ge "$HOT_TEMP_C" ]; then
        hot_drive_count=$((hot_drive_count + 1))
      fi
      ;;
    *)
      ;;
  esac
done

if [ "$temp_count" -eq 0 ] || [ -z "$max_temp" ]; then
  log_message "ERROR: no valid HDD temperatures collected disks=$disk_count standby=$standby_count"
  exit 1
fi

tmp_file="$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")"
{
  printf 'GENERATED_EPOCH=%s\n' "$(date +%s)"
  printf 'SOURCE_HOST=%s\n' "$(hostname -s)"
  printf 'DISK_COUNT=%s\n' "$disk_count"
  printf 'HOT_DRIVE_COUNT=%s\n' "$hot_drive_count"
  printf 'MAX_TEMP_C=%s\n' "$max_temp"
} > "$tmp_file"

mv -f "$tmp_file" "$OUTPUT_FILE"
chmod 0644 "$OUTPUT_FILE"

log_message "Updated $OUTPUT_FILE disks=$disk_count temps=$temp_count standby=$standby_count max_temp=$max_temp hot_drive_count=$hot_drive_count"
