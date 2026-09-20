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
- If Unraid cannot collect valid temperatures, it preserves the previous summary unless all disks are confirmed standby

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
   * * * * * bash /boot/config/custom/hdd_temp_export_virtiofs.sh >/dev/null 2>&1
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
bash /boot/config/custom/hdd_temp_export_virtiofs.sh
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
- No valid disk temperatures in Unraid: preserve the last good summary, except confirmed all-standby publishes fresh telemetry

## Production thermal policy

The checked-in configs are the intended LGNAS CSE-846 production defaults, not
examples. This initial curve is an intermediate setting to validate after the
six-fan push/pull hardware expansion. Disk counts are discovered dynamically.

```text
HDD temperature °C   30  35  37  39  40  42  44  45  47  50  55  60
HDD PWM            100 105 110 120 130 145 160 170 195 225 255 255
CPU temperature °C  50  60  70  80  90  95
CPU PWM            120 140 170 204 235 255
```

`AIO_FANWALL_ENABLE="yes"`: final demand is the **maximum** of independent HDD
and CPU demands. Minimum PWM is 100, maximum is 255. Curve keys are discovered
dynamically, including legacy `PWM_AT_<temp>_PLUS` keys. The first threshold at
or above the temperature wins: **43°C selects `PWM_AT_44=160`**. Above the last
threshold, its PWM applies. Each curve must be nondecreasing, remain inside
MIN/MAX, and use unique temperatures; the HDD curve must reach MAX_PWM.

Each controller retains its own band in `/run/hdd_fanwall_control.state`.
Upward band changes are immediate. The existing `HYSTERESIS_C=2` reduction rule
holds the prior band while temperature is at least that band's temperature
minus 2°C. Hot-drive modifiers are recalculated each sample and do not stack.

The exporter counts measured drives at or above 42°C as hot. Bonuses use
`TEMP_COUNT`, excluding standby and unknown disks:

| Condition | HDD bonus |
| --- | ---: |
| At least 8 hot and at least 70% measured hot | +24 |
| Otherwise at least 4 hot and at least 50% measured hot | +16 |
| Otherwise | 0 |

Four of five measured drives qualifies for +16; four of fourteen does not.
Eight of fourteen gets +16; ten of fourteen gets +24. Bonuses cap at MAX_PWM.
CPU arbitration happens after the HDD bonus.

The CPU input prefers the configured path when it contains a valid reading.
Otherwise it searches hwmon for `CPU_TEMP_HWMON_NAME_REGEX="^coretemp$"` and
`CPU_TEMP_LABEL_REGEX="^Package id 0$"`. Missing, invalid, or ambiguous discovery
is a CPU fault.

| Condition | Decision |
| --- | --- |
| Missing, unreadable, stale (>120s), future or invalid HDD summary | max(204, valid CPU demand) |
| CPU sensor unavailable or invalid | CPU_FALLBACK_PWM=255 |
| All discovered HDDs confirmed standby, none unknown | HDD minimum floor; CPU control remains active |
| Some disks unknown | Warning on unknown-count change |
| At least 50% of discovered disks unknown | HDD telemetry fallback |
| PWM/manual-mode write failure | Nonzero error; no successful state recorded |

No valid temperatures with any unknown disks leaves the exporter's last good
summary untouched; it will expire into fallback. Confirmed all-standby is the
exception and publishes fresh healthy telemetry. The timer remains 20s after
boot, then every 15s with 1s accuracy; input reads time out after 2s.

## Schema v2 and diagnostics

The host explicitly parses VM data and never sources or executes it. This release
requires schema v2, so deploy the exporter first. Missing/duplicate required keys,
noncanonical unsigned integers, invalid timestamps, impossible counts and unknown
schema versions trigger fallback. Counts must account for every discovered disk:
`TEMP_COUNT + STANDBY_COUNT + UNKNOWN_COUNT == DISK_COUNT`; hot count must not
exceed measured count. `HOT_THRESHOLD_C` must be between 10 and 80°C.

```text
SCHEMA_VERSION=2
GENERATED_EPOCH=1789870000
SOURCE_HOST=unraid-pve-LNAS
DISK_COUNT=14
TEMP_COUNT=14
STANDBY_COUNT=0
UNKNOWN_COUNT=0
HOT_THRESHOLD_C=42
HOT_DRIVE_COUNT=5
MAX_TEMP_C=43
```

For all-standby, `TEMP_COUNT=0`, `STANDBY_COUNT=DISK_COUNT`, `UNKNOWN_COUNT=0`,
`HOT_DRIVE_COUNT=0` and `MAX_TEMP_C=0` (a sentinel, not a measured temperature).

Unraid also atomically writes `/mnt/proxmox-fan/hdd_temp_detail.tsv` with columns
`serial`, `model`, `device`, `state`, `temp_c`. Identity comes from the same
standby-safe SMART query; unavailable identity is `unknown`. The host control
loop never depends on this diagnostic file. Each summary is also atomically
replaced; the two files are independent snapshots.

```bash
/usr/local/sbin/hdd_fanwall_control.sh --status
/usr/local/sbin/hdd_fanwall_control.sh --dry-run
```

Both calculate the current decision and report input age/counts, HDD base/bonus,
CPU demand, selected source, final request and actual PWM/RPM without writing
PWM, state, or logs. `--status` is a current calculation, not merely the last
applied decision. `--validate-only` and `--print-hwmon-path` remain supported.

Journald `fan-control` records full decisions on PWM/band transitions, fallback
entry/reason change and recovery. Thermal transitions at 50°C (warning), 55°C
(critical) and recovery are logged once per change, as are unknown-disk counts.

## Updating the existing installation

Keep backups of the installed scripts as well as the configs before rollout.
On Unraid, run from the new release checkout:

```bash
bash ./deploy-unraid.sh --force-config
bash /boot/config/custom/hdd_temp_export_virtiofs.sh
cat /mnt/proxmox-fan/hdd_temp_status.env
cat /mnt/proxmox-fan/hdd_temp_detail.tsv
```

Once fresh schema v2 data is present, run on Proxmox as root:

```bash
bash ./deploy-proxmox.sh --force-config
systemctl daemon-reload
systemctl restart hdd-fanwall-control.timer
/usr/local/sbin/hdd_fanwall_control.sh --validate-only
/usr/local/sbin/hdd_fanwall_control.sh --dry-run
systemctl start hdd-fanwall-control.service
/usr/local/sbin/hdd_fanwall_control.sh --status
```

Use `bash` for scripts on Unraid’s noexec boot filesystem.
Both deploy scripts preserve timestamped config backups when `--force-config`
is used. Preserve the existing Unraid schedule and mount. To roll back, restore
the saved scripts/configs together and restart the host timer.

Proxmox deployment validates the selected configuration before changing the
installation. It backs up installed files under `/var/tmp/hdd-fanwall-deploy.*`,
stops the timer during replacement, restarts it and runs the controller once.
Deployment failures restore the previous files and timer state. An incompatible
older configuration is rejected before replacement; use `--force-config` after
reviewing the production defaults.

## Automated and hardware validation

```bash
python3 -m unittest discover -s tests -v
git ls-files '*.sh' | xargs -r -n1 bash -n
git ls-files '*.sh' | xargs -r shellcheck
```

CI runs these checks. Tests use temporary fake sensors and command fixtures,
not live hardware. `CONFIG_FILE`, `STATE_FILE`, and `HWMON_ROOT` are overridable
for the controller; the exporter also accepts a `CONFIG_FILE` override.

After installing the extra fan bank and drives, record per-drive temperature,
maximum temperature, hot count, both PWM demands, final PWM and RPM at 30, 60
and 120 minutes of sustained array activity, ideally a parity check. At roughly
24°C ambient, target typical drives 36–40°C and hottest sustained drives 40–42°C;
43–44°C peaks are acceptable, 50°C warrants investigation, and 55°C requests full
PWM. Separately test CPU load, then combined CPU/array load, checking that final
PWM is the larger demand throughout. These physical thermal/noise targets are
not established by the automated tests.

## Uninstall

On Proxmox:

```bash
bash ./uninstall-proxmox.sh
```

Optional flags:

- `--remove-config`
- `--remove-data-dir`

On Unraid:

```bash
bash ./uninstall-unraid.sh
```

Optional flag:

- `--remove-config`

Proxmox uninstall verifies full manual PWM (255) before removing the controller,
units, state and lock file. It does not guess a hardware automatic-control mode.
If that handoff fails, the controller is retained and a previously active timer
is restarted. Configure a replacement fan controller before reducing fan speed.
`--remove-data-dir` removes only an empty share directory.

Unraid uninstall backs up and removes the exporter’s standard User Scripts
registration, its persistent/cached schedule entries and matching root crontab
commands. It waits for an active export to finish, then removes the exporter,
summary, detail file and lock. Other jobs, the virtiofs mount and logs remain.
Backups are under `/boot/config/custom/fanwall-uninstall.*`; config is retained
unless `--remove-config` is supplied. Custom wrappers with different names must
be removed separately. The host enters telemetry fallback after exporter removal.

Lifecycle tests require Linux user namespaces, Bubblewrap and jq. They run the
actual lifecycle scripts against temporary files with mocked system services;
they never uninstall the live deployment.
