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

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

plugin=/boot/config/plugins/user.scripts
wrapper="$plugin/scripts/hdd_temp_export_virtiofs"
exporter=/boot/config/custom/hdd_temp_export_virtiofs.sh
config=/boot/config/custom/hdd_temp_export_virtiofs.conf
MOUNT_POINT=/mnt/proxmox-fan
OUTPUT_FILE="$MOUNT_POINT/hdd_temp_status.env"
DETAIL_FILE="$MOUNT_POINT/hdd_temp_detail.tsv"
if [ -f "$config" ]; then
  # shellcheck disable=SC1090
  source "$config"
fi

# Preflight all schedule JSON before changing any jobs. jq ships with Unraid.
for file in "$plugin/schedule.json" /tmp/user.scripts/schedule.json; do
  [ ! -f "$file" ] || jq -e 'type == "object"' "$file" >/dev/null
done
backup_dir="$(mktemp -d /boot/config/custom/fanwall-uninstall.XXXXXXXX)"
have_crontab=no
if crontab -l > "$backup_dir/root.crontab" 2>"$backup_dir/crontab.stderr"; then
  have_crontab=yes
elif ! grep -qi 'no crontab' "$backup_dir/crontab.stderr"; then
  cat "$backup_dir/crontab.stderr" >&2
  exit 1
fi
filter_cron() {
  # Match complete command tokens, never substrings (or comments).
  awk -v exporter="$exporter" -v wrapper="$wrapper" '
    /^[[:space:]]*#/ { print; next }
    {
      remove = 0
      for (i = 1; i <= NF; i++) {
        token = $i
        gsub(/[\047"]/, "", token)
        if (token == exporter || token == wrapper || token == wrapper "/script") remove = 1
      }
      if (!remove) print
    }
  '
}
for file in "$plugin/schedule.json" /tmp/user.scripts/schedule.json; do
  if [ -f "$file" ]; then
    cp -p "$file" "$backup_dir/$(echo "$file" | tr / _ )"
    tmp="$(mktemp "${file}.XXXXXX")"
    jq --arg dir "$wrapper" --arg script "$wrapper/script" --arg exporter "$exporter" '
      with_entries(select(
        .key != $dir and .key != $script and .key != $exporter and
        .value.script != $dir and .value.script != $script and .value.script != $exporter))
    ' "$file" > "$tmp"
    chmod --reference="$file" "$tmp"
    mv -f "$tmp" "$file"
  fi
done
if [ -f "$plugin/customSchedule.cron" ]; then
  cp -p "$plugin/customSchedule.cron" "$backup_dir/"
  tmp="$(mktemp "$plugin/customSchedule.cron.XXXXXX")"
  filter_cron < "$plugin/customSchedule.cron" > "$tmp"
  chmod --reference="$plugin/customSchedule.cron" "$tmp"
  mv -f "$tmp" "$plugin/customSchedule.cron"
fi
if [ -d "$wrapper" ]; then mv "$wrapper" "$backup_dir/user-script"; fi
if command -v update_cron >/dev/null 2>&1; then update_cron; fi
# Also support a directly installed root crontab entry.
if [ "$have_crontab" = yes ]; then
  filter_cron < "$backup_dir/root.crontab" > "$backup_dir/root.filtered"
  crontab "$backup_dir/root.filtered"
fi

# Wait for any current export to finish before removing its files.
if [ -d "$MOUNT_POINT" ]; then
  exec 9>"$MOUNT_POINT/.hdd_temp_export.lock"
  flock -w 30 9
fi
[ ! -f "$exporter" ] || cp -p "$exporter" "$backup_dir/"
rm -f -- "$exporter" "$OUTPUT_FILE" "$DETAIL_FILE"
rm -f -- "$MOUNT_POINT/.hdd_temp_export.lock"
if [ "$REMOVE_CONFIG" = yes ]; then
  [ ! -f "$config" ] || cp -p "$config" "$backup_dir/"
  rm -f -- "$config"
else
  echo "Keeping $config"
fi

echo "Unraid uninstall complete. Exporter schedules and telemetry removed; backup: $backup_dir"
echo "The virtiofs mount, exporter log, and unrelated User Scripts are preserved."
