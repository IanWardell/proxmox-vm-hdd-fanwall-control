#!/bin/bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/boot/config/custom/hdd_temp_export_virtiofs.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "missing config file: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
DETAIL_FILE="${DETAIL_FILE:-$MOUNT_POINT/hdd_temp_detail.tsv}"
if [[ ! "$HOT_TEMP_C" =~ ^[1-9][0-9]?$ ]] || ((HOT_TEMP_C < 10 || HOT_TEMP_C > 80)); then
  echo "invalid HOT_TEMP_C" >&2
  exit 1
fi

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
  # Pairs preserve empty TRAN values (common with virtio disks).
  lsblk -dnP -o PATH,TYPE,RM,TRAN,ROTA | awk -v rotational="$ONLY_ROTATIONAL_DISKS" '
    {
      delete fields
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        gsub(/"/, "", pair[2])
        fields[pair[1]] = pair[2]
      }
      if (fields["TYPE"] == "disk" && fields["RM"] == "0" && fields["TRAN"] != "usb" &&
          (rotational != "yes" || fields["ROTA"] == "1")) print fields["PATH"]
    }
  '

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
    output="$(smartctl -n standby -i -A "$disk" 2>&1 || true)"
  else
    output="$(smartctl -i -A "$disk" 2>&1 || true)"
  fi

  # Read identity from the same standby-safe query; never issue a second wake-up query.
  disk_serial="$(printf '%s\n' "$output" | awk -F: '/^[[:space:]]*Serial [Nn]umber:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' | tr '\t\r\n' '   ')"
  disk_model="$(printf '%s\n' "$output" | awk -F: '/^[[:space:]]*(Device Model|Model Number|Product):/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' | tr '\t\r\n' '   ')"
  disk_serial="${disk_serial:-unknown}" disk_model="${disk_model:-unknown}"
  disk_state=unknown disk_temp=""
  if echo "$output" | grep -qiE 'STANDBY|standby mode'; then
    disk_state=standby
    return 0
  fi

  if temp="$(printf '%s\n' "$output" | extract_temp_c)" && [[ "$temp" =~ ^[1-8][0-9]$ ]] && ((temp <= 80)); then
    disk_state=active disk_temp="$temp"
    return 0
  fi

  disk_state=unknown
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
unknown_count=0
hot_drive_count=0
max_temp=""

tmp_file="" detail_tmp="$(mktemp "${DETAIL_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "${tmp_file:-}" "${detail_tmp:-}"' EXIT
printf 'serial\tmodel\tdevice\tstate\ttemp_c\n' > "$detail_tmp"
for disk in "${disks[@]}"; do
  disk_count=$((disk_count + 1))

  read_disk_temp "$disk"
  state="$disk_state" temp="$disk_temp"
  printf '%s\t%s\t%s\t%s\t%s\n' "$disk_serial" "$disk_model" "$disk" "$state" "$temp" >> "$detail_tmp"

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
      unknown_count=$((unknown_count + 1))
      ;;
  esac
done

chmod 0644 "$detail_tmp"
mv -f "$detail_tmp" "$DETAIL_FILE"

# All standby is healthy telemetry. Unknown/no temperatures retains last good summary.
if [ "$temp_count" -eq 0 ] && [ "$standby_count" -ne "$disk_count" ]; then
  log_message "ERROR: no valid HDD temperatures collected disks=$disk_count standby=$standby_count"
  exit 1
fi

tmp_file="$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")"
{
  printf 'SCHEMA_VERSION=2\n'
  printf 'TEMP_COUNT=%s\nSTANDBY_COUNT=%s\nUNKNOWN_COUNT=%s\n' "$temp_count" "$standby_count" "$unknown_count"
  printf 'HOT_THRESHOLD_C=%s\n' "$HOT_TEMP_C"
  printf 'GENERATED_EPOCH=%s\n' "$(date +%s)"
  printf 'SOURCE_HOST=%s\n' "$(hostname -s)"
  printf 'DISK_COUNT=%s\n' "$disk_count"
  printf 'HOT_DRIVE_COUNT=%s\n' "$hot_drive_count"
  printf 'MAX_TEMP_C=%s\n' "${max_temp:-0}"
} > "$tmp_file"

chmod 0644 "$tmp_file"
mv -f "$tmp_file" "$OUTPUT_FILE"

log_message "Updated $OUTPUT_FILE disks=$disk_count temps=$temp_count standby=$standby_count max_temp=$max_temp hot_drive_count=$hot_drive_count"
