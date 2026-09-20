"""Hardware-free regression tests using temporary sysfs and telemetry fixtures."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'proxmox/usr-local-sbin/hdd_fanwall_control.sh'
CONFIG = ROOT / 'proxmox/etc/hdd-fanwall-control.cfg'


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.hw = self.root / 'hwmon0'
        self.hw.mkdir()
        for name, value in {'pwm2': '120', 'pwm2_enable': '1', 'fan6_input': '3480',
                            'temp1_input': '40000', 'temp1_label': 'Package id 0',
                            'name': 'coretemp'}.items():
            (self.hw / name).write_text(value + '\n')
        self.cfg = self.root / 'config'
        self.state = self.root / 'state'
        self.telemetry = self.root / 'input'
        self.logs = self.root / 'logs'
        bindir = self.root / 'bin'
        bindir.mkdir()
        logger = bindir / 'logger'
        logger.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$TEST_LOG"\n')
        logger.chmod(0o755)
        self.env = dict(os.environ, CONFIG_FILE=str(self.cfg), STATE_FILE=str(self.state),
                        HWMON_ROOT=str(self.root), TEST_LOG=str(self.logs),
                        PATH=f'{bindir}:{os.environ["PATH"]}')
        self.configure()
        self.input()

    def configure(self, **overrides):
        values = dict(HWMON_PATH=str(self.hw), CPU_TEMP_HWMON_PATH=str(self.hw),
                      INPUT_FILE=str(self.telemetry))
        values.update(overrides)
        self.cfg.write_text(CONFIG.read_text() + '\n' + ''.join(
            f'{k}={shlex.quote(str(v))}\n' for k, v in values.items()))

    def input(self, **overrides):
        values = dict(SCHEMA_VERSION=2, GENERATED_EPOCH=int(time.time()), SOURCE_HOST='test',
                      DISK_COUNT=14, TEMP_COUNT=14, STANDBY_COUNT=0, UNKNOWN_COUNT=0,
                      HOT_THRESHOLD_C=42, HOT_DRIVE_COUNT=0, MAX_TEMP_C=30)
        values.update(overrides)
        self.telemetry.write_text(''.join(f'{k}={v}\n' for k, v in values.items()))

    def cpu(self, temp):
        (self.hw / 'temp1_input').write_text(str(temp * 1000))

    def run_control(self, action='--dry-run', ok=True):
        result = subprocess.run(['bash', str(SCRIPT), action], env=self.env,
                                capture_output=True, text=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)

    def test_curve_selection(self):
        self.configure(AIO_FANWALL_ENABLE='no')
        for temp, pwm in [(30, 100), (35, 105), (36, 110), (43, 160), (44, 160),
                          (45, 170), (47, 195), (50, 225), (55, 255), (65, 255)]:
            with self.subTest(temp=temp):
                self.input(MAX_TEMP_C=temp)
                self.assertEqual(self.run_control()['final_requested_pwm'], str(pwm))

    def test_boost_count_and_percent(self):
        for measured, hot, bump in [(5, 3, 0), (5, 4, 16), (14, 4, 0), (14, 7, 16),
                                     (14, 8, 16), (14, 9, 16), (14, 10, 24),
                                     (14, 14, 24), (8, 8, 24), (20, 14, 24)]:
            with self.subTest(measured=measured, hot=hot):
                self.input(DISK_COUNT=measured, TEMP_COUNT=measured, MAX_TEMP_C=44,
                           HOT_DRIVE_COUNT=hot)
                result = self.run_control()
                self.assertEqual(result['hdd_hot_bump'], str(bump))
                self.assertEqual(result['final_requested_pwm'], str(160 + bump))
        self.input(MAX_TEMP_C=55, HOT_DRIVE_COUNT=14)
        self.assertEqual(self.run_control()['final_requested_pwm'], '255')

    def test_independent_hysteresis_and_arbitration(self):
        self.cpu(69)
        self.input(MAX_TEMP_C=43)
        self.run_control('run')  # CPU wins, but HDD band must survive.
        self.cpu(68)
        self.input(MAX_TEMP_C=42)
        result = self.run_control()
        self.assertEqual((result['hdd_band'], result['cpu_band']), ('hdd_t44', 'cpu_t70'))
        self.assertEqual(result['final_requested_pwm'], '170')
        self.input(MAX_TEMP_C=50)
        self.run_control('run')  # HDD wins, but CPU band must survive.
        self.assertIn('STATE_CPU_BAND=cpu_t70', self.state.read_text())
        self.input(MAX_TEMP_C=41)
        self.cpu(59)
        result = self.run_control()
        self.assertEqual((result['hdd_band'], result['cpu_band']), ('hdd_t42', 'cpu_t60'))
        self.input(MAX_TEMP_C=55)
        self.cpu(95)
        self.assertEqual(self.run_control()['final_requested_pwm'], '255')

    def test_hysteresis_boundary_and_immediate_rise(self):
        self.configure(AIO_FANWALL_ENABLE='no')
        self.input(MAX_TEMP_C=43)
        self.run_control('run')
        self.input(MAX_TEMP_C=42)
        self.assertEqual(self.run_control()['hdd_requested_pwm'], '160')
        self.input(MAX_TEMP_C=41)
        self.assertEqual(self.run_control()['hdd_requested_pwm'], '145')
        self.input(MAX_TEMP_C=45)
        self.assertEqual(self.run_control()['hdd_requested_pwm'], '170')

    def test_all_standby(self):
        self.input(TEMP_COUNT=0, STANDBY_COUNT=14, MAX_TEMP_C=0)
        result = self.run_control()
        self.assertEqual((result['mode'], result['hdd_band'], result['final_requested_pwm']),
                         ('normal', 'standby', '120'))
        self.configure(AIO_FANWALL_ENABLE='no')
        self.assertEqual(self.run_control()['final_requested_pwm'], '100')

    def test_unknown_disks(self):
        self.input(TEMP_COUNT=13, UNKNOWN_COUNT=1)
        self.assertEqual(self.run_control()['mode'], 'normal')
        self.input(TEMP_COUNT=6, UNKNOWN_COUNT=8)
        result = self.run_control()
        self.assertEqual((result['mode'], result['final_requested_pwm']), ('fallback', '204'))
        self.input(TEMP_COUNT=0, STANDBY_COUNT=13, UNKNOWN_COUNT=1, MAX_TEMP_C=0)
        self.assertEqual(self.run_control()['mode'], 'fallback')

    def test_invalid_schema(self):
        for invalid in [dict(HOT_DRIVE_COUNT=15), dict(TEMP_COUNT=15),
                        dict(STANDBY_COUNT=15), dict(UNKNOWN_COUNT=15),
                        dict(UNKNOWN_COUNT=1), dict(SCHEMA_VERSION=3),
                        dict(HOT_THRESHOLD_C=99), dict(MAX_TEMP_C='$(touch /tmp/never)'),
                        dict(TEMP_COUNT='08'), dict(TEMP_COUNT='9' * 30),
                        dict(DISK_COUNT=0), dict(MAX_TEMP_C=81)]:
            with self.subTest(invalid=invalid):
                self.input(**invalid)
                self.assertEqual(self.run_control()['mode'], 'fallback')
        self.input()
        with self.telemetry.open('a') as f:
            f.write('DISK_COUNT=14\n')
        self.assertEqual(self.run_control()['mode'], 'fallback')

    def test_missing_stale_future_and_cpu_priority(self):
        for epoch in [int(time.time()) - 200, int(time.time()) + 200]:
            self.input(GENERATED_EPOCH=epoch)
            self.assertEqual(self.run_control()['final_requested_pwm'], '204')
        self.telemetry.unlink()
        self.assertEqual(self.run_control()['final_requested_pwm'], '204')
        self.cpu(95)
        self.assertEqual(self.run_control()['final_requested_pwm'], '255')
        (self.hw / 'temp1_input').unlink()
        self.assertEqual(self.run_control()['final_requested_pwm'], '255')

    def test_cpu_failure_fallback_and_discovery(self):
        self.configure(CPU_TEMP_HWMON_PATH='/nonexistent')
        self.assertEqual(self.run_control()['mode'], 'normal')
        second = self.root / 'hwmon1'
        second.mkdir()
        for name in ['name', 'temp1_label', 'temp1_input']:
            (second / name).write_text((self.hw / name).read_text())
        self.assertEqual(self.run_control()['final_requested_pwm'], '255')
        self.configure()  # valid explicit input takes precedence over duplicate discovery.
        self.assertEqual(self.run_control()['mode'], 'normal')
        (self.hw / 'temp1_input').write_text('invalid')
        (second / 'temp1_input').unlink()
        self.assertEqual(self.run_control()['mode'], 'fallback')
        self.run_control('run')
        self.assertEqual((self.hw / 'pwm2').read_text().strip(), '255')

    def test_status_and_dry_run_do_not_write(self):
        self.run_control('run')
        before = {p: p.read_bytes() for p in [self.state, self.hw / 'pwm2',
                                             self.hw / 'pwm2_enable', self.logs]}
        self.input(MAX_TEMP_C=55)
        for action in ['--status', '--dry-run']:
            self.assertEqual(self.run_control(action)['final_requested_pwm'], '255')
        for p, content in before.items():
            self.assertEqual(p.read_bytes(), content)

    def test_validation(self):
        self.run_control('--validate-only')
        for overrides in [dict(PWM_AT_40=180), dict(CPU_PWM_AT_70=130),
                          dict(PWM_AT_30=99), dict(PWM_AT_60=256),
                          dict(CPU_PWM_AT_50=90), dict(MIN_PWM=256),
                          dict(PWM_AT_55=250, PWM_AT_60=250), dict(PWM_AT_44_PLUS=160)]:
            with self.subTest(overrides=overrides):
                self.configure(**overrides)
                self.run_control('--validate-only', ok=False)

    def test_transition_logs(self):
        self.input(MAX_TEMP_C=50)
        self.run_control('run')
        first = self.logs.read_text()
        self.assertIn('THERMAL_TRANSITION', first)
        self.run_control('run')
        self.assertEqual(self.logs.read_text(), first)
        self.input(MAX_TEMP_C=55)
        self.run_control('run')
        self.assertIn('thermal_level=critical', self.logs.read_text())
        self.telemetry.unlink()
        self.run_control('run')
        first = self.logs.read_text()
        self.run_control('run')
        self.assertEqual(self.logs.read_text(), first)
        self.input()
        self.run_control('run')
        self.assertIn('RECOVERY', self.logs.read_text())

    def test_read_timeout_and_unknown_warning_transitions(self):
        timeout = self.root / 'bin/timeout'
        timeout.write_text('#!/bin/bash\nexit 124\n')
        timeout.chmod(0o755)
        result = self.run_control()
        self.assertEqual((result['reason'], result['final_requested_pwm']),
                         ('virtiofs_read_timeout', '204'))
        timeout.unlink()
        self.input(TEMP_COUNT=13, UNKNOWN_COUNT=1)
        self.run_control('run')
        before = self.logs.read_text()
        self.assertIn('UNKNOWN_DRIVES', before)
        self.run_control('run')
        self.assertEqual(self.logs.read_text(), before)
        self.input()
        self.run_control('run')
        self.assertIn('previous=1 count=0', self.logs.read_text())

    def test_pwm_write_failure_is_error(self):
        (self.hw / 'pwm2_enable').unlink()
        (self.hw / 'pwm2_enable').mkdir()
        self.run_control('run', ok=False)
        self.assertFalse(self.state.exists())


if __name__ == '__main__':
    unittest.main()
