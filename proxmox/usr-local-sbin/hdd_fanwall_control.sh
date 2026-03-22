#!/bin/bash
set -u

source /etc/hdd-fanwall-control.cfg

log() { logger -t "$LOG_TAG" "$1"; }
logv() { logger -t "$VIRTIOFS_TAG" "$1"; }

set_pwm() {
  local val="$1"
  if [ "$val" -lt "$MIN_PWM" ]; then val="$MIN_PWM"; fi
  if [ "$val" -gt "$MAX_PWM" ]; then val="$MAX_PWM"; fi

  echo 1 > "$HWMON_PATH/$PWM_ENABLE_NAME"
  echo "$val" > "$HWMON_PATH/$PWM_NAME"
}

fallback() {
  set_pwm "$SAFE_FALLBACK_PWM"
  log "FALLBACK triggered: $1"
}

if [ ! -f "$INPUT_FILE" ]; then
  logv "missing file"
  fallback "missing file"
  exit
fi

if ! timeout "$READ_TIMEOUT_SECONDS" cat "$INPUT_FILE" >/dev/null 2>&1; then
  logv "read timeout"
  fallback "virtiofs hang"
  exit
fi

source "$INPUT_FILE"

now=$(date +%s)
age=$((now - GENERATED_EPOCH))

if [ "$age" -gt "$MAX_FILE_AGE_SECONDS" ]; then
  logv "stale data"
  fallback "stale data"
  exit
fi

if ! [[ "$MAX_TEMP_C" =~ ^[0-9]+$ ]]; then
  fallback "invalid temp"
  exit
fi

t="$MAX_TEMP_C"

if [ "$t" -le 30 ]; then pwm=$PWM_AT_30
elif [ "$t" -le 32 ]; then pwm=$PWM_AT_32
elif [ "$t" -le 35 ]; then pwm=$PWM_AT_35
elif [ "$t" -le 37 ]; then pwm=$PWM_AT_37
elif [ "$t" -le 39 ]; then pwm=$PWM_AT_39
elif [ "$t" -le 40 ]; then pwm=$PWM_AT_40
elif [ "$t" -le 42 ]; then pwm=$PWM_AT_42
elif [ "$t" -le 43 ]; then pwm=$PWM_AT_43
elif [ "$t" -le 45 ]; then pwm=$PWM_AT_45
else pwm=$PWM_AT_46_PLUS
fi

set_pwm "$pwm"
log "PWM set to $pwm (temp=$t)"