#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/hdd-fanwall-control.cfg"
STATE_FILE="/run/hdd_fanwall_control.state"

ACTION="${1:-run}"

if [ ! -f "$CONFIG_FILE" ]; then
  logger -t fan-control "ERROR: missing config file: $CONFIG_FILE"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

log() {
  logger -t "$LOG_TAG" "$1"
}

logv() {
  logger -t "$VIRTIOFS_TAG" "$1"
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

state_mode=""
state_reason=""
state_band=""
state_pwm=""
state_temp=""

read_state() {
  state_mode=""
  state_reason=""
  state_band=""
  state_pwm=""
  state_temp=""

  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    state_mode="${STATE_MODE:-}"
    state_reason="${STATE_REASON:-}"
    state_band="${STATE_BAND:-}"
    state_pwm="${STATE_PWM:-}"
    state_temp="${STATE_TEMP:-}"
  fi
}

write_state() {
  local mode="$1"
  local reason="$2"
  local band="$3"
  local pwm="$4"
  local temp="$5"
  local tmp

  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  {
    printf 'STATE_MODE=%q\n' "$mode"
    printf 'STATE_REASON=%q\n' "$reason"
    printf 'STATE_BAND=%q\n' "$band"
    printf 'STATE_PWM=%q\n' "$pwm"
    printf 'STATE_TEMP=%q\n' "$temp"
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

  for candidate in /sys/class/hwmon/hwmon*; do
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

validate_config_values() {
  local key var suffix value curve_count

  for key in SAFE_FALLBACK_PWM MAX_FILE_AGE_SECONDS READ_TIMEOUT_SECONDS MIN_PWM MAX_PWM \
    HOT_DRIVE_COUNT_BUMP_THRESHOLD HOT_DRIVE_PWM_BUMP HYSTERESIS_C; do
    if ! is_uint "${!key:-}"; then
      echo "invalid numeric config: $key=${!key:-}" >&2
      return 1
    fi
  done

  curve_count=0
  for var in $(compgen -A variable PWM_AT_); do
    suffix="${var#PWM_AT_}"
    value="${!var:-}"

    if [[ "$suffix" =~ ^[0-9]+$ ]]; then
      curve_count=$((curve_count + 1))
    elif [[ "$suffix" =~ ^[0-9]+_PLUS$ ]]; then
      curve_count=$((curve_count + 1))
    else
      echo "invalid fan curve key: $var" >&2
      return 1
    fi

    if ! is_uint "$value"; then
      echo "invalid numeric config: $var=$value" >&2
      return 1
    fi
  done

  if [ "$curve_count" -eq 0 ]; then
    echo "no fan curve entries found; define PWM_AT_<temp>=<pwm>" >&2
    return 1
  fi

  if [ "$MIN_PWM" -gt "$MAX_PWM" ]; then
    echo "MIN_PWM is greater than MAX_PWM" >&2
    return 1
  fi

  return 0
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

  printf '1\n' > "$ACTIVE_HWMON_PATH/$PWM_ENABLE_NAME"
  printf '%s\n' "$pwm" > "$ACTIVE_HWMON_PATH/$PWM_NAME"
  printf '%s\n' "$pwm"
}

read_current_rpm() {
  if [ -r "$ACTIVE_HWMON_PATH/$RPM_NAME" ]; then
    cat "$ACTIVE_HWMON_PATH/$RPM_NAME" 2>/dev/null || true
  fi
}

read_input_file() {
  local content line key value

  parsed_generated_epoch=""
  parsed_max_temp_c=""
  parsed_hot_drive_count="0"
  parsed_disk_count="0"
  parsed_source_host=""

  if [ ! -f "$INPUT_FILE" ]; then
    return 10
  fi

  if ! content="$(timeout "$READ_TIMEOUT_SECONDS" cat -- "$INPUT_FILE" 2>/dev/null)"; then
    return 11
  fi

  while IFS= read -r line; do
    case "$line" in
      ''|'#'*)
        continue
        ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        ;;
      *)
        return 12
        ;;
    esac

    case "$key" in
      GENERATED_EPOCH)
        is_uint "$value" || return 12
        parsed_generated_epoch="$value"
        ;;
      MAX_TEMP_C)
        is_uint "$value" || return 12
        parsed_max_temp_c="$value"
        ;;
      HOT_DRIVE_COUNT)
        is_uint "$value" || return 12
        parsed_hot_drive_count="$value"
        ;;
      DISK_COUNT)
        is_uint "$value" || return 12
        parsed_disk_count="$value"
        ;;
      SOURCE_HOST)
        [[ "$value" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 12
        parsed_source_host="$value"
        ;;
      *)
        continue
        ;;
    esac
  done <<< "$content"

  [ -n "$parsed_generated_epoch" ] || return 12
  [ -n "$parsed_max_temp_c" ] || return 12

  return 0
}

get_read_input_status() {
  if read_input_file; then
    printf '0\n'
  else
    printf '%s\n' "$?"
  fi
}

fan_curve_points() {
  local var suffix temp

  for var in $(compgen -A variable PWM_AT_); do
    suffix="${var#PWM_AT_}"
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
  local point_temp point_pwm last_temp="" last_pwm=""

  while read -r point_temp point_pwm; do
    last_temp="$point_temp"
    last_pwm="$point_pwm"

    if [ "$t" -le "$point_temp" ]; then
      printf 't%s:%s\n' "$point_temp" "$point_pwm"
      return
    fi
  done < <(fan_curve_points)

  printf 't%s:%s\n' "$last_temp" "$last_pwm"
}

choose_band_and_pwm_with_hysteresis() {
  local t="$1"
  local current_band="$2"
  local selection target_band target_temp current_temp point_temp current_pwm

  selection="$(choose_curve_point_for_temp "$t")"
  target_band="${selection%%:*}"
  target_temp="${target_band#t}"

  if [[ "$current_band" =~ ^t([0-9]+)$ ]]; then
    current_temp="${BASH_REMATCH[1]}"
    if [ "$target_temp" -lt "$current_temp" ] && [ "$t" -ge $((current_temp - HYSTERESIS_C)) ]; then
      while read -r point_temp current_pwm; do
        if [ "$point_temp" -eq "$current_temp" ]; then
          printf 't%s:%s\n' "$current_temp" "$current_pwm"
          return
        fi
      done < <(fan_curve_points)
    fi
  fi

  printf '%s\n' "$selection"
}

enter_fallback() {
  local reason="$1"
  local trigger="$2"
  local applied_pwm rpm

  read_state

  if ! applied_pwm="$(apply_set_pwm "$SAFE_FALLBACK_PWM")"; then
    log "ERROR: fallback write failed reason=$reason trigger=$trigger hwmon_path=$ACTIVE_HWMON_PATH"
    exit 1
  fi

  rpm="$(read_current_rpm)"

  if [ "$state_mode" != "fallback" ] || [ "$state_reason" != "$reason" ] || [ "$state_pwm" != "$applied_pwm" ]; then
    if is_uint "$rpm"; then
      log "ERROR: FALLBACK_APPLIED pwm=$applied_pwm rpm=$rpm reason=$reason trigger=$trigger previous_mode=${state_mode:-none} previous_pwm=${state_pwm:-none} previous_band=${state_band:-none}"
    else
      log "ERROR: FALLBACK_APPLIED pwm=$applied_pwm reason=$reason trigger=$trigger previous_mode=${state_mode:-none} previous_pwm=${state_pwm:-none} previous_band=${state_band:-none}"
    fi
  fi

  write_state "fallback" "$reason" "fallback" "$applied_pwm" ""
  exit 0
}

if ! validate_config_values; then
  log "ERROR: invalid config values in $CONFIG_FILE"
  exit 1
fi

if ! ACTIVE_HWMON_PATH="$(resolve_hwmon_path)"; then
  log "ERROR: unable to resolve hwmon path for $PWM_NAME/$RPM_NAME"
  exit 1
fi

if ! validate_hwmon_access "$ACTIVE_HWMON_PATH"; then
  log "ERROR: hwmon path is not usable: $ACTIVE_HWMON_PATH"
  exit 1
fi

case "$ACTION" in
  --validate-only)
    printf 'config_ok=1\n'
    printf 'hwmon_path=%s\n' "$ACTIVE_HWMON_PATH"
    exit 0
    ;;
  --print-hwmon-path)
    printf '%s\n' "$ACTIVE_HWMON_PATH"
    exit 0
    ;;
  run|'')
    ;;
  *)
    echo "usage: $0 [--validate-only|--print-hwmon-path]" >&2
    exit 2
    ;;
esac

read_state

read_input_status="0"
read_input_file || read_input_status="$?"

case "$read_input_status" in
  0)
    ;;
  10)
    logv "virtiofs input file missing path=$INPUT_FILE"
    enter_fallback "input_file_missing" "path=$INPUT_FILE"
    ;;
  11)
    logv "virtiofs read timeout path=$INPUT_FILE timeout_seconds=$READ_TIMEOUT_SECONDS"
    enter_fallback "virtiofs_read_timeout" "path=$INPUT_FILE timeout_seconds=$READ_TIMEOUT_SECONDS"
    ;;
  *)
    logv "invalid input content path=$INPUT_FILE"
    enter_fallback "invalid_input_file" "path=$INPUT_FILE"
    ;;
esac

now_epoch="$(date +%s)"
file_age_seconds=$((now_epoch - parsed_generated_epoch))

if [ "$file_age_seconds" -lt 0 ] || [ "$file_age_seconds" -gt "$MAX_FILE_AGE_SECONDS" ]; then
  logv "stale or future data age_seconds=$file_age_seconds max_allowed=$MAX_FILE_AGE_SECONDS path=$INPUT_FILE"
  enter_fallback "stale_input_file" "age_seconds=$file_age_seconds max_allowed=$MAX_FILE_AGE_SECONDS source_host=${parsed_source_host:-unknown}"
fi

if [ "$parsed_max_temp_c" -lt 10 ] || [ "$parsed_max_temp_c" -gt 80 ]; then
  logv "invalid max temp value=$parsed_max_temp_c path=$INPUT_FILE"
  enter_fallback "invalid_max_temp" "max_temp=$parsed_max_temp_c source_host=${parsed_source_host:-unknown}"
fi

selection="$(choose_band_and_pwm_with_hysteresis "$parsed_max_temp_c" "$state_band")"
target_band="${selection%%:*}"
target_pwm="${selection##*:}"

if [ "$parsed_hot_drive_count" -ge "$HOT_DRIVE_COUNT_BUMP_THRESHOLD" ]; then
  target_pwm=$((target_pwm + HOT_DRIVE_PWM_BUMP))
fi
if [ "$target_pwm" -gt "$MAX_PWM" ]; then
  target_pwm="$MAX_PWM"
fi

if ! applied_pwm="$(apply_set_pwm "$target_pwm")"; then
  log "ERROR: pwm write failed requested=$target_pwm hwmon_path=$ACTIVE_HWMON_PATH"
  exit 1
fi

write_state "normal" "max_temp=$parsed_max_temp_c" "$target_band" "$applied_pwm" "$parsed_max_temp_c"

rpm="$(read_current_rpm)"

if [ "$state_mode" = "fallback" ]; then
  if is_uint "$rpm"; then
    log "RECOVERY pwm=$applied_pwm rpm=$rpm band=$target_band max_temp=$parsed_max_temp_c hot_drive_count=$parsed_hot_drive_count disk_count=$parsed_disk_count source_host=${parsed_source_host:-unknown} previous_reason=${state_reason:-fallback}"
  else
    log "RECOVERY pwm=$applied_pwm band=$target_band max_temp=$parsed_max_temp_c hot_drive_count=$parsed_hot_drive_count disk_count=$parsed_disk_count source_host=${parsed_source_host:-unknown} previous_reason=${state_reason:-fallback}"
  fi
elif [ "$state_pwm" != "$applied_pwm" ] || [ "$state_band" != "$target_band" ]; then
  if is_uint "$rpm"; then
    log "PWM_SET pwm=$applied_pwm rpm=$rpm band=$target_band max_temp=$parsed_max_temp_c hot_drive_count=$parsed_hot_drive_count disk_count=$parsed_disk_count source_host=${parsed_source_host:-unknown}"
  else
    log "PWM_SET pwm=$applied_pwm band=$target_band max_temp=$parsed_max_temp_c hot_drive_count=$parsed_hot_drive_count disk_count=$parsed_disk_count source_host=${parsed_source_host:-unknown}"
  fi
fi
