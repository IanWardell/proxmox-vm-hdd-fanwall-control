# Proxmox VM HDD Fanwall Control

Host-side fan wall control for Proxmox using HDD temperatures exported from an Unraid VM over virtiofs.

This repo is designed for this architecture:

- Proxmox host controls a Supermicro CSE-846 fan wall through sysfs PWM
- Current known control path is `pwm2` on the Proxmox host
- Unraid runs as a VM on that Proxmox host
- Unraid has HBA passthrough and reads HDD temperatures with `smartctl`
- Only `/var/lib/fan-control/vm-unraid-hdd` is shared from host to VM
- Inside Unraid, that share is mounted at `/mnt/proxmox-fan`
- Unraid writes `hdd_temp_status.env`
- Proxmox reads that file locally and applies a safe PWM policy

## Safety properties

- The host never executes VM-written shell code
- The host never sets PWM below the configured minimum
- Missing, stale, invalid, or unreadable VM data forces a safe fallback PWM
- Fallback and recovery events are logged to journald
- Unraid skips standby disks instead of waking them
- If Unraid cannot collect any valid temperatures, it leaves the previous file untouched

## Repo layout

```text
proxmox-vm-hdd-fanwall-control/
├── README.md
├── deploy-proxmox.sh
├── deploy-unraid.sh
├── uninstall-proxmox.sh
├── uninstall-unraid.sh
├── proxmox/
│   ├── etc/
│   │   └── hdd-fanwall-control.cfg
│   ├── systemd/
│   │   ├── hdd-fanwall-control.service
│   │   └── hdd-fanwall-control.timer
│   └── usr-local-sbin/
│       └── hdd_fanwall_control.sh
└── unraid/
    └── boot-config-custom/
        ├── hdd_temp_export_virtiofs.conf
        └── hdd_temp_export_virtiofs.sh
```

## Proxmox setup

1. Create the host directory:

   ```bash
   mkdir -p /var/lib/fan-control/vm-unraid-hdd
   chmod 755 /var/lib/fan-control
   chmod 755 /var/lib/fan-control/vm-unraid-hdd
   ```

2. In Proxmox, create a Directory Mapping that points to:

   ```text
   /var/lib/fan-control/vm-unraid-hdd
   ```

3. Attach that mapping to the Unraid VM as a `virtiofs` device.

4. Make sure `virtiofsd` is installed on the Proxmox host:

   ```bash
   apt install virtiofsd
   ```

5. Review and tune the Proxmox config:

   ```bash
   sed -n '1,200p' /etc/hdd-fanwall-control.cfg
   ```

   Important:

   - `MIN_PWM` must stay at or above your safe floor
   - `SAFE_FALLBACK_PWM=204` is the fallback used when VM data is unavailable
   - Fan curve entries are `PWM_AT_<temp_c>=<pwm>`; add or remove temperature points as needed
   - `HWMON_PATH` defaults to your known working path and the script will try auto-detection if that path becomes invalid

6. Deploy from the repo root:

   ```bash
   ./deploy-proxmox.sh
   ```

   If `/etc/hdd-fanwall-control.cfg` already exists, it is preserved unless you pass `--force-config`.

## Unraid setup

1. Deploy from the repo root:

   ```bash
   ./deploy-unraid.sh
   ```

2. Mount the virtiofs share in Unraid:

   ```bash
   mkdir -p /mnt/proxmox-fan
   mount -t virtiofs vm-unraid-hdd /mnt/proxmox-fan
   ```

3. Add the same mount command to your Unraid startup mechanism.

4. Schedule the exporter every minute with User Scripts or cron:

   ```text
   * * * * * /boot/config/custom/hdd_temp_export_virtiofs.sh >/dev/null 2>&1
   ```

## Validation

### Validate virtiofs wiring

On Unraid:

```bash
echo "probe=1" > /mnt/proxmox-fan/probe.env
```

On Proxmox:

```bash
cat /var/lib/fan-control/vm-unraid-hdd/probe.env
rm -f /var/lib/fan-control/vm-unraid-hdd/probe.env
```

### Validate the Unraid exporter

On Unraid:

```bash
/boot/config/custom/hdd_temp_export_virtiofs.sh
cat /mnt/proxmox-fan/hdd_temp_status.env
```

Expected format is simple `KEY=VALUE` lines with numeric values for the fields the host consumes.

### Validate the Proxmox controller

On Proxmox:

```bash
/usr/local/sbin/hdd_fanwall_control.sh --validate-only
/usr/local/sbin/hdd_fanwall_control.sh
journalctl -t fan-control -t fan-control-virtiofs -n 50 --no-pager
```

## Logging

The host uses these journald tags:

- `fan-control`
- `fan-control-virtiofs`

Useful commands:

```bash
journalctl -t fan-control -n 100 --no-pager
journalctl -t fan-control-virtiofs -n 100 --no-pager
systemctl status hdd-fanwall-control.timer --no-pager
```

## Failure behavior

- Proxmox boots first: the timer starts, sees missing VM data, and applies the fallback PWM
- Unraid boots later: once it starts writing fresh data, the host recovers automatically
- Missing file: fallback
- Stale file: fallback
- Invalid file content: fallback
- virtiofs read timeout: fallback
- No valid disk temperatures in Unraid: the exporter does not replace the last known good file

## Thermal policy defaults

Defaults are intentionally conservative:

- Minimum PWM floor: `120`
- Fallback PWM: `204`
- Max PWM: `255`
- Fan curve entries use `PWM_AT_<temp_c>=<pwm>`, for example `PWM_AT_47=180`
- The controller discovers all `PWM_AT_<temp_c>` entries from the config at runtime
- The controller uses the first configured temperature point that is at or above the current max HDD temperature
- If the max HDD temperature is above the highest configured point, the controller uses the highest configured point
- Hysteresis only delays fan speed reductions; fan speed increases are applied immediately

Default fan curve:

```bash
PWM_AT_30=120
PWM_AT_32=125
PWM_AT_35=128
PWM_AT_37=120
PWM_AT_40=130
PWM_AT_45=160
PWM_AT_47=180
PWM_AT_50=204
PWM_AT_55=235
PWM_AT_60=255
```

You can add, remove, or change points without editing the controller script. For example, adding this line creates a new threshold:

```bash
PWM_AT_52=220
```

### Optional CPU-Aware Control

For AIO plus fan-wall setups, the Proxmox controller can also factor CPU temperature into the same fan wall decision. This is disabled by default.

Enable it in `/etc/hdd-fanwall-control.cfg`:

```bash
AIO_FANWALL_ENABLE="yes"
```

Generic CPU temp settings:

```bash
CPU_TEMP_HWMON_PATH="/sys/class/hwmon/hwmon4"
CPU_TEMP_INPUT_NAME="temp1_input"
CPU_TEMP_MAX_VALID_C=105
```

Find the correct CPU package temperature sensor on your Proxmox host with:

```bash
for f in /sys/class/hwmon/hwmon*/temp*_label; do echo "$f: $(cat "$f" 2>/dev/null)"; done
```

Look for a label such as `Package id 0`, `Tctl`, or `Tdie`. If the label path is:

```text
/sys/class/hwmon/hwmon4/temp1_label: Package id 0
```

then configure:

```bash
CPU_TEMP_HWMON_PATH="/sys/class/hwmon/hwmon4"
CPU_TEMP_INPUT_NAME="temp1_input"
```

To choose a CPU fan curve, identify the CPU model and look up its official max junction temperature from the CPU vendor. On Proxmox:

```bash
lscpu | grep 'Model name'
```

For Intel CPUs, search the Intel ARK/specification page for that model and check `Tjunction`. For AMD CPUs, search the AMD product specification page and check the max operating temperature. Use that value as the upper safety boundary, not as the normal operating target.

Then observe the CPU package temperature at idle and under a real workload:

```bash
watch -n 1 "awk '{printf \"CPU %.1fC\\n\", \$1/1000}' /sys/class/hwmon/hwmon4/temp1_input"
```

Replace `/sys/class/hwmon/hwmon4/temp1_input` with the input path discovered above. Build the `CPU_PWM_AT_<temp_c>` curve from those observations. For example, if the CPU normally idles below `50C`, is acceptable in the `60-75C` range, and should get strong airflow above `80C`, use lower PWM below `60C` and ramp more aggressively above `70C`.

CPU fan curve entries use `CPU_PWM_AT_<temp_c>=<pwm>`:

```bash
CPU_PWM_AT_50=120
CPU_PWM_AT_60=140
CPU_PWM_AT_70=170
CPU_PWM_AT_80=204
CPU_PWM_AT_90=235
CPU_PWM_AT_95=255
```

When CPU-aware control is enabled, the controller calculates both targets and applies the higher PWM:

```text
applied_pwm = max(hdd_curve_pwm, cpu_curve_pwm)
```

If the CPU temperature input is missing, unreadable, or invalid while CPU-aware control is enabled, the controller applies the safe fallback PWM.

These defaults should still be validated against your actual drives, ambient temperature, and chassis airflow.

## Notes

- The host only trusts numeric fields from the VM-written file
- The current export format is intentionally minimal and safe to parse
- Standby disks are skipped with `smartctl -n standby`
- The exporter dynamically rescans disks every run, so it scales as you add drives
- The hardcoded `HWMON_PATH` is still a motherboard-specific assumption; keep an eye on it after BIOS/kernel changes

## Uninstall

On Proxmox:

```bash
./uninstall-proxmox.sh
```

Optional flags:

- `--remove-config`
- `--remove-data-dir`

On Unraid:

```bash
./uninstall-unraid.sh
```

Optional flag:

- `--remove-config`
