#!/bin/bash
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/hdd-fanwall-control.cfg}"
STATE_FILE="${STATE_FILE:-/run/hdd_fanwall_control.state}"
HWMON_ROOT="${HWMON_ROOT:-/sys/class/hwmon}"

ACTION="${1:-run}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: missing config file: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

log() {
  logger -t "$LOG_TAG" "$1"
}

is_uint() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]{0,11})$ ]]
}

is_enabled() {
  case "${1:-no}" in
    yes|true|1|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_state() {
  local line key value
  # Diagnostic state fields are populated dynamically below.
  # shellcheck disable=SC2034
  STATE_MODE="" STATE_REASON="" STATE_HDD_BAND="" STATE_HDD_PWM=""
  # shellcheck disable=SC2034
  STATE_CPU_BAND="" STATE_CPU_PWM="" STATE_FINAL_PWM="" STATE_FINAL_SOURCE=""
  # shellcheck disable=SC2034
  STATE_HDD_TEMP="" STATE_CPU_TEMP="" STATE_THERMAL_LEVEL="" STATE_UNKNOWN_COUNT=""
  [ -f "$STATE_FILE" ] || return 0
  while IFS= read -r line; do
    key="${line%%=*}" value="${line#*=}"
    case "$key" in
      STATE_MODE|STATE_REASON|STATE_HDD_BAND|STATE_HDD_PWM|STATE_CPU_BAND|STATE_CPU_PWM|STATE_FINAL_PWM|STATE_FINAL_SOURCE|STATE_HDD_TEMP|STATE_CPU_TEMP|STATE_THERMAL_LEVEL|STATE_UNKNOWN_COUNT)
        [[ "$value" =~ ^[a-zA-Z0-9_]*$ ]] || continue
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$STATE_FILE"
}

write_state() {
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  {
    printf 'STATE_MODE=%s\nSTATE_REASON=%s\n' "$mode" "$reason"
    printf 'STATE_HDD_BAND=%s\nSTATE_HDD_PWM=%s\n' "$hdd_band" "$hdd_pwm"
    printf 'STATE_CPU_BAND=%s\nSTATE_CPU_PWM=%s\n' "$cpu_band" "$cpu_pwm"
    printf 'STATE_FINAL_PWM=%s\nSTATE_FINAL_SOURCE=%s\n' "$final_pwm" "$selected_source"
    printf 'STATE_HDD_TEMP=%s\nSTATE_CPU_TEMP=%s\n' "${parsed_max_temp_c:-}" "$cpu_temp_c"
    printf 'STATE_UNKNOWN_COUNT=%s\n' "${parsed_unknown_count:-}"
    printf 'STATE_THERMAL_LEVEL=%s\n' "$thermal_level"
  } > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

resolve_hwmon_path() {
  local configured="$HWMON_PATH"
  local candidate name
  local matches=()

  if [ -n "$configured" ] \
    && [ -e "$configured/$PWM_ENABLE_NAME" ] \
    && [ -e "$configured/$PWM_NAME" ] \
    && [ -e "$configured/$RPM_NAME" ]; then
    printf '%s\n' "$configured"
    return 0
  fi

  for candidate in "$HWMON_ROOT"/hwmon*; do
    [ -d "$candidate" ] || continue
    [ -e "$candidate/$PWM_ENABLE_NAME" ] || continue
    [ -e "$candidate/$PWM_NAME" ] || continue
    [ -e "$candidate/$RPM_NAME" ] || continue

    if [ -n "$HWMON_NAME_REGEX" ] && [ -r "$candidate/name" ]; then
      name="$(cat "$candidate/name" 2>/dev/null || true)"
      if [[ ! "$name" =~ $HWMON_NAME_REGEX ]]; then
        continue
      fi
    fi

    matches+=("$candidate")
  done

  if [ "${#matches[@]}" -eq 1 ]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  return 1
}

resolve_cpu_input() {
  local candidate label name input raw
  local matches=()
  input="${CPU_TEMP_HWMON_PATH:-}/${CPU_TEMP_INPUT_NAME:-}"
  if raw="$(cat "$input" 2>/dev/null)" && is_uint "$raw" && ((raw <= CPU_TEMP_MAX_VALID_C * 1000)); then
    printf '%s\n' "$input"
    return 0
  fi
  for candidate in "$HWMON_ROOT"/hwmon*; do
    name="$(cat "$candidate/name" 2>/dev/null || true)"
    [[ "$name" =~ ${CPU_TEMP_HWMON_NAME_REGEX:-^coretemp$} ]] || continue
    for label in "$candidate"/temp*_label; do
      name="$(cat "$label" 2>/dev/null || true)"
      [[ "$name" =~ ${CPU_TEMP_LABEL_REGEX:-^Package id 0$} ]] || continue
      input="${label%_label}_input"
      [ -r "$input" ] && matches+=("$input")
    done
  done
  [ "${#matches[@]}" -eq 1 ] || return 1
  printf '%s\n' "${matches[0]}"
}

validate_config_values() {
  local key
  for key in SAFE_FALLBACK_PWM MAX_FILE_AGE_SECONDS READ_TIMEOUT_SECONDS MIN_PWM MAX_PWM \
    HOT_DRIVE_COUNT_BUMP_THRESHOLD HOT_DRIVE_PWM_BUMP VERY_HOT_DRIVE_COUNT_BUMP_THRESHOLD \
    VERY_HOT_DRIVE_PWM_BUMP HOT_DRIVE_PERCENT_THRESHOLD VERY_HOT_DRIVE_PERCENT_THRESHOLD \
    UNKNOWN_DRIVE_PERCENT_FALLBACK CPU_FALLBACK_PWM HYSTERESIS_C; do
    if ! is_uint "${!key:-}"; then
      echo "invalid numeric config: $key=${!key:-}" >&2
      return 1
    fi
  done
  if ((MIN_PWM > MAX_PWM || MAX_PWM > 255 || SAFE_FALLBACK_PWM < MIN_PWM || SAFE_FALLBACK_PWM > MAX_PWM ||
    CPU_FALLBACK_PWM < MIN_PWM || CPU_FALLBACK_PWM > MAX_PWM ||
    HOT_DRIVE_PERCENT_THRESHOLD < 1 || VERY_HOT_DRIVE_PERCENT_THRESHOLD > 100 ||
    VERY_HOT_DRIVE_PERCENT_THRESHOLD < HOT_DRIVE_PERCENT_THRESHOLD ||
    UNKNOWN_DRIVE_PERCENT_FALLBACK < 1 || UNKNOWN_DRIVE_PERCENT_FALLBACK > 100 ||
    READ_TIMEOUT_SECONDS < 1 || HOT_DRIVE_COUNT_BUMP_THRESHOLD < 1 ||
    VERY_HOT_DRIVE_COUNT_BUMP_THRESHOLD <= HOT_DRIVE_COUNT_BUMP_THRESHOLD ||
    VERY_HOT_DRIVE_PWM_BUMP < HOT_DRIVE_PWM_BUMP)); then
    echo "invalid PWM bounds, timeout, or boost thresholds" >&2
    return 1
  fi
  validate_curve_values "PWM_AT_" || return 1
  if is_enabled "${AIO_FANWALL_ENABLE:-no}"; then
    is_uint "${CPU_TEMP_MAX_VALID_C:-}" || return 1
    validate_curve_values "CPU_PWM_AT_" || return 1
  fi
}

validate_curve_values() {
  local prefix="$1" var suffix value point previous_temp=-1 previous_pwm=-1 count=0 reaches_max=no
  while IFS= read -r var; do
    suffix="${var#"$prefix"}"
    value="${!var:-}"
    point="${suffix%_PLUS}"
    if ! is_uint "$point" || ! is_uint "$value" || ((value < MIN_PWM || value > MAX_PWM)); then
      echo "invalid fan curve entry: $var=$value" >&2
      return 1
    fi
  done < <(compgen -A variable "$prefix")
  while read -r point value; do
    if ((point <= previous_temp || value < previous_pwm)); then
      echo "non-monotonic or duplicate fan curve: $prefix" >&2
      return 1
    fi
    previous_temp="$point" previous_pwm="$value"
    count=$((count + 1))
    [ "$value" -ne "$MAX_PWM" ] || reaches_max=yes
  done < <(fan_curve_points "$prefix")
  if ((count == 0)) || { [ "$prefix" = PWM_AT_ ] && [ "$reaches_max" != yes ]; }; then
    echo "missing curve entries or HDD MAX_PWM safety point: $prefix" >&2
    return 1
  fi
}

validate_hwmon_access() {
  local hwmon="$1"

  [ -w "$hwmon/$PWM_ENABLE_NAME" ] || {
    echo "missing or unwritable: $hwmon/$PWM_ENABLE_NAME" >&2
    return 1
  }
  [ -w "$hwmon/$PWM_NAME" ] || {
    echo "missing or unwritable: $hwmon/$PWM_NAME" >&2
    return 1
  }
  [ -e "$hwmon/$RPM_NAME" ] || {
    echo "missing: $hwmon/$RPM_NAME" >&2
    return 1
  }
}

apply_set_pwm() {
  local requested="$1"
  local pwm="$requested"

  is_uint "$pwm" || return 1

  if [ "$pwm" -lt "$MIN_PWM" ]; then
    pwm="$MIN_PWM"
  fi
  if [ "$pwm" -gt "$MAX_PWM" ]; then
    pwm="$MAX_PWM"
  fi

  printf '1\n' > "$ACTIVE_HWMON_PATH/$PWM_ENABLE_NAME" || return 1
  printf '%s\n' "$pwm" > "$ACTIVE_HWMON_PATH/$PWM_NAME" || return 1
  printf '%s\n' "$pwm"
}

read_current_rpm() {
  if [ -r "$ACTIVE_HWMON_PATH/$RPM_NAME" ]; then
    cat "$ACTIVE_HWMON_PATH/$RPM_NAME" 2>/dev/null || true
  fi
}

read_cpu_temp_c() {
  local raw

  local input
  input="$(resolve_cpu_input)" || return 1
  raw="$(cat "$input" 2>/dev/null)" || return 1
  is_uint "$raw" || return 1

  ((raw <= CPU_TEMP_MAX_VALID_C * 1000)) || return 1
  printf '%s\n' $((raw / 1000))
}

read_input_file() {
  local content line key value required
  local -A fields=()
  parsed_disk_count="" parsed_temp_count="" parsed_hot_drive_count="" parsed_standby_count=""
  parsed_hot_threshold_c="" parsed_unknown_count="" parsed_generated_epoch=""
  parsed_max_temp_c="" parsed_schema_version=""
  [ -f "$INPUT_FILE" ] || return 10
  content="$(timeout "$READ_TIMEOUT_SECONDS" cat -- "$INPUT_FILE" 2>/dev/null)" || return 11
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) key="${line%%=*}" value="${line#*=}" ;;
      *) return 12 ;;
    esac
    case "$key" in
      SCHEMA_VERSION|GENERATED_EPOCH|MAX_TEMP_C|HOT_DRIVE_COUNT|DISK_COUNT|TEMP_COUNT|STANDBY_COUNT|UNKNOWN_COUNT|HOT_THRESHOLD_C)
        is_uint "$value" || return 12 ;;
      SOURCE_HOST) [[ "$value" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 12 ;;
      *) continue ;;
    esac
    [ -z "${fields[$key]+present}" ] || return 12
    fields[$key]="$value"
  done <<< "$content"
  for required in SCHEMA_VERSION GENERATED_EPOCH MAX_TEMP_C HOT_DRIVE_COUNT DISK_COUNT TEMP_COUNT STANDBY_COUNT UNKNOWN_COUNT HOT_THRESHOLD_C SOURCE_HOST; do
    [ -n "${fields[$required]:-}" ] || return 12
  done
  [ "${fields[SCHEMA_VERSION]}" = 2 ] || return 12
  for key in "${!fields[@]}"; do
    printf -v "parsed_${key,,}" '%s' "${fields[$key]}"
  done
  ((parsed_disk_count > 0 && parsed_temp_count <= parsed_disk_count &&
    parsed_hot_drive_count <= parsed_temp_count && parsed_standby_count <= parsed_disk_count &&
    parsed_unknown_count <= parsed_disk_count &&
    parsed_temp_count + parsed_standby_count + parsed_unknown_count == parsed_disk_count &&
    parsed_hot_threshold_c >= 10 && parsed_hot_threshold_c <= 80)) || return 12
  if ((parsed_temp_count == 0)); then
    ((parsed_max_temp_c == 0 && parsed_hot_drive_count == 0)) || return 12
  fi
}

fan_curve_points() {
  local prefix="$1"
  local var suffix temp

  for var in $(compgen -A variable "$prefix"); do
    suffix="${var#"$prefix"}"
    if [[ "$suffix" =~ ^([0-9]+)$ ]]; then
      temp="${BASH_REMATCH[1]}"
    elif [[ "$suffix" =~ ^([0-9]+)_PLUS$ ]]; then
      temp="${BASH_REMATCH[1]}"
    else
      continue
    fi

    printf '%s %s\n' "$temp" "${!var}"
  done | sort -n -k1,1
}

choose_curve_point_for_temp() {
  local t="$1"
  local prefix="$2"
  local band_prefix="$3"
  local point_temp point_pwm last_temp="" last_pwm=""

  while read -r point_temp point_pwm; do
    last_temp="$point_temp"
    last_pwm="$point_pwm"

    if [ "$t" -le "$point_temp" ]; then
      printf '%s%s:%s\n' "$band_prefix" "$point_temp" "$point_pwm"
      return
    fi
  done < <(fan_curve_points "$prefix")

  printf '%s%s:%s\n' "$band_prefix" "$last_temp" "$last_pwm"
}

choose_band_and_pwm_with_hysteresis() {
  local t="$1"
  local current_band="$2"
  local prefix="$3"
  local band_prefix="$4"
  local selection target_band target_temp current_temp point_temp current_pwm

  selection="$(choose_curve_point_for_temp "$t" "$prefix" "$band_prefix")"
  target_band="${selection%%:*}"
  target_temp="${target_band#"$band_prefix"}"

  if [[ "$current_band" =~ ^${band_prefix}([0-9]+)$ ]]; then
    current_temp="${BASH_REMATCH[1]}"
    if [ "$target_temp" -lt "$current_temp" ] && [ "$t" -ge $((current_temp - HYSTERESIS_C)) ]; then
      while read -r point_temp current_pwm; do
        if [ "$point_temp" -eq "$current_temp" ]; then
          printf '%s%s:%s\n' "$band_prefix" "$current_temp" "$current_pwm"
          return
        fi
      done < <(fan_curve_points "$prefix")
    fi
  fi

  printf '%s\n' "$selection"
}

report_status() {
  printf 'mode=%s\nreason=%s\n' "$mode" "$reason"
  printf 'input_age_seconds=%s\nschema_version=%s\n' "$file_age_seconds" "${parsed_schema_version:-unknown}"
  printf 'disk_count=%s\ntemp_count=%s\nstandby_count=%s\nunknown_count=%s\n' "${parsed_disk_count:-}" "${parsed_temp_count:-}" "${parsed_standby_count:-}" "${parsed_unknown_count:-}"
  printf 'hdd_max_temp_c=%s\nhot_threshold_c=%s\nhot_drive_count=%s\n' "${parsed_max_temp_c:-}" "${parsed_hot_threshold_c:-}" "${parsed_hot_drive_count:-}"
  printf 'hdd_band=%s\nhdd_base_pwm=%s\nhdd_hot_bump=%s\nhdd_requested_pwm=%s\n' "$hdd_band" "$hdd_base_pwm" "$hot_bump" "$hdd_pwm"
  printf 'cpu_temp_c=%s\ncpu_band=%s\ncpu_requested_pwm=%s\n' "$cpu_temp_c" "$cpu_band" "$cpu_pwm"
  printf 'selected_source=%s\nfinal_requested_pwm=%s\nthermal_level=%s\n' "$selected_source" "$final_pwm" "$thermal_level"
  printf 'current_pwm=%s\ncurrent_rpm=%s\n' "$current_pwm" "$(read_current_rpm)"
}

finish_decision() {
  local event details previous_pwm
  current_pwm="$(cat "$ACTIVE_HWMON_PATH/$PWM_NAME" 2>/dev/null || true)"
  if [ "$ACTION" = --status ] || [ "$ACTION" = --dry-run ]; then
    report_status
    exit 0
  fi
  previous_pwm="$current_pwm"
  if ! final_pwm="$(apply_set_pwm "$final_pwm")"; then
    log "ERROR: pwm write failed mode=$mode reason=$reason hwmon_path=$ACTIVE_HWMON_PATH"
    exit 1
  fi
  current_pwm="$(cat "$ACTIVE_HWMON_PATH/$PWM_NAME" 2>/dev/null || true)"
  details="$(report_status | tr '\n' ' ')"
  event=""
  if [ "$mode" = fallback ]; then
    if [ "$STATE_MODE" != fallback ] || [ "$STATE_REASON" != "$reason" ] || [ "$previous_pwm" != "$final_pwm" ]; then
      event=FALLBACK_APPLIED
    fi
  elif [ "$STATE_MODE" = fallback ]; then
    event=RECOVERY
  elif [ "$STATE_FINAL_PWM" != "$final_pwm" ] || [ "$previous_pwm" != "$final_pwm" ] ||
    [ "$STATE_HDD_BAND" != "$hdd_band" ] || [ "$STATE_CPU_BAND" != "$cpu_band" ]; then
    event=PWM_SET
  fi
  [ -z "$event" ] || log "$event $details"
  if [ "$mode" = normal ] && [ "$STATE_THERMAL_LEVEL" != "$thermal_level" ]; then
    if [ "$thermal_level" != normal ] || [ -n "$STATE_THERMAL_LEVEL" ]; then
      log "THERMAL_TRANSITION previous=${STATE_THERMAL_LEVEL:-unknown} $details"
    fi
  fi
  if [ "${parsed_unknown_count:-}" != "$STATE_UNKNOWN_COUNT" ] && [ -n "${parsed_unknown_count:-}" ]; then
    if ((parsed_unknown_count > 0)) || [[ "$STATE_UNKNOWN_COUNT" =~ ^[1-9][0-9]*$ ]]; then
      log "UNKNOWN_DRIVES previous=${STATE_UNKNOWN_COUNT:-unknown} count=$parsed_unknown_count disk_count=$parsed_disk_count mode=$mode"
    fi
  fi
  write_state
  exit 0
}

enter_fallback() {
  mode=fallback reason="$1" selected_source=fallback final_pwm="$SAFE_FALLBACK_PWM"
  if [ "$reason" = cpu_temp_read_failed ]; then
    final_pwm="$CPU_FALLBACK_PWM"
    cpu_band="$STATE_CPU_BAND"
  elif [ -n "$cpu_pwm" ] && ((cpu_pwm > final_pwm)); then
    final_pwm="$cpu_pwm" selected_source=cpu
  fi
  # HDD faults do not discard an independently valid CPU demand.
  hdd_band="$STATE_HDD_BAND"
  thermal_level="$STATE_THERMAL_LEVEL"
  finish_decision
}

case "$ACTION" in
  run|--validate-only|--print-hwmon-path|--status|--dry-run) ;;
  *) echo "usage: $0 [--validate-only|--print-hwmon-path|--status|--dry-run]" >&2; exit 2 ;;
esac
if ! validate_config_values; then
  echo "ERROR: invalid config values in $CONFIG_FILE" >&2
  exit 1
fi
if ! ACTIVE_HWMON_PATH="$(resolve_hwmon_path)"; then
  echo "ERROR: unable to resolve hwmon path for $PWM_NAME/$RPM_NAME" >&2
  exit 1
fi
if [ "$ACTION" = --print-hwmon-path ]; then
  printf '%s\n' "$ACTIVE_HWMON_PATH"
  exit 0
fi
if [ "$ACTION" != --status ] && [ "$ACTION" != --dry-run ]; then
  validate_hwmon_access "$ACTIVE_HWMON_PATH" || exit 1
fi
if [ "$ACTION" = --validate-only ]; then
  if is_enabled "${AIO_FANWALL_ENABLE:-no}"; then
    read_cpu_temp_c >/dev/null || { echo "CPU sensor unavailable or invalid" >&2; exit 1; }
  fi
  printf 'config_ok=1\nhwmon_path=%s\n' "$ACTIVE_HWMON_PATH"
  exit 0
fi

# Serialize applying runs; diagnostic actions remain entirely read-only.
if [ "$ACTION" = run ]; then
  exec 9>"${STATE_FILE}.lock"
  flock -n 9 || exit 0
fi
read_state
mode=normal reason="" file_age_seconds="" hdd_band="" hdd_base_pwm="" hot_bump=0 hdd_pwm=""
cpu_temp_c="" cpu_band="" cpu_pwm="" selected_source=hdd thermal_level=normal
# Resolve CPU demand first, even if VM telemetry is missing or stale.
if is_enabled "${AIO_FANWALL_ENABLE:-no}"; then
  cpu_temp_c="$(read_cpu_temp_c)" || enter_fallback cpu_temp_read_failed
  selection="$(choose_band_and_pwm_with_hysteresis "$cpu_temp_c" "$STATE_CPU_BAND" CPU_PWM_AT_ cpu_t)"
  cpu_band="${selection%%:*}" cpu_pwm="${selection##*:}"
fi
read_input_status=0
read_input_file || read_input_status="$?"
case "$read_input_status" in
  0) ;;
  10) enter_fallback input_file_missing ;;
  11) enter_fallback virtiofs_read_timeout ;;
  *) enter_fallback invalid_input_file ;;
esac
file_age_seconds=$(($(date +%s) - parsed_generated_epoch))
if ((file_age_seconds < 0 || file_age_seconds > MAX_FILE_AGE_SECONDS)); then
  enter_fallback stale_input_file
fi
if ((parsed_unknown_count * 100 >= parsed_disk_count * UNKNOWN_DRIVE_PERCENT_FALLBACK)); then
  enter_fallback too_many_unknown_disks
fi
if ((parsed_temp_count == 0)); then
  if ((parsed_standby_count != parsed_disk_count || parsed_unknown_count != 0)); then
    enter_fallback no_valid_hdd_temperatures
  fi
  hdd_band=standby hdd_base_pwm="$MIN_PWM" hdd_pwm="$MIN_PWM" final_pwm="$MIN_PWM"
  if [ -n "$cpu_pwm" ] && ((cpu_pwm >= final_pwm)); then
    final_pwm="$cpu_pwm" selected_source=cpu
  fi
  finish_decision
fi
if ((parsed_max_temp_c < 10 || parsed_max_temp_c > 80)); then
  enter_fallback invalid_max_temp
fi
selection="$(choose_band_and_pwm_with_hysteresis "$parsed_max_temp_c" "$STATE_HDD_BAND" PWM_AT_ hdd_t)"
hdd_band="${selection%%:*}" hdd_base_pwm="${selection##*:}"
if ((parsed_hot_drive_count >= VERY_HOT_DRIVE_COUNT_BUMP_THRESHOLD &&
  parsed_hot_drive_count * 100 >= parsed_temp_count * VERY_HOT_DRIVE_PERCENT_THRESHOLD)); then
  hot_bump="$VERY_HOT_DRIVE_PWM_BUMP"
elif ((parsed_hot_drive_count >= HOT_DRIVE_COUNT_BUMP_THRESHOLD &&
  parsed_hot_drive_count * 100 >= parsed_temp_count * HOT_DRIVE_PERCENT_THRESHOLD)); then
  hot_bump="$HOT_DRIVE_PWM_BUMP"
fi
hdd_pwm=$((hdd_base_pwm + hot_bump))
((hdd_pwm <= MAX_PWM)) || hdd_pwm="$MAX_PWM"
((hdd_pwm >= MIN_PWM)) || hdd_pwm="$MIN_PWM"
final_pwm="$hdd_pwm"
if [ -n "$cpu_pwm" ] && ((cpu_pwm > final_pwm)); then
  final_pwm="$cpu_pwm" selected_source=cpu
fi
if ((parsed_max_temp_c >= 55)); then
  thermal_level=critical
elif ((parsed_max_temp_c >= 50)); then
  thermal_level=warning
fi
finish_decision
