"""Exercise real install/uninstall scripts inside an isolated filesystem namespace."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('bwrap'), 'bubblewrap required for isolated lifecycle tests')
class LifecycleTests(unittest.TestCase):
    def setUp(self):
        probe = subprocess.run(['bwrap', '--unshare-all', '--ro-bind', '/', '/', 'true'],
                               capture_output=True)
        if probe.returncode:
            if os.environ.get('REQUIRE_LIFECYCLE_TESTS'):
                self.fail(probe.stderr.decode())
            self.skipTest('User namespaces unavailable for safe lifecycle tests')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ['etc/systemd/system', 'run', 'sys/class/hwmon/hwmon0',
                     'usr/local/sbin', 'var/tmp', 'boot/config/custom', 'tmp', 'mocks']:
            (self.root / name).mkdir(parents=True)
        self.release = self.root / 'release'
        shutil.copytree(ROOT / 'proxmox', self.release / 'proxmox')
        for name in ['deploy-proxmox.sh', 'uninstall-proxmox.sh', 'uninstall-unraid.sh']:
            shutil.copyfile(ROOT / name, self.release / name)
        self.write('release/proxmox/usr-local-sbin/hdd_fanwall_control.sh',
                   '#!/bin/bash\n[[ "${PREFLIGHT_FAIL:-0}" != 1 ]]\n')
        self.write('usr/local/sbin/hdd_fanwall_control.sh',
                   '#!/bin/bash\necho /sys/class/hwmon/hwmon0\n')
        self.write('etc/hdd-fanwall-control.cfg', 'PWM_NAME=pwm2\nPWM_ENABLE_NAME=pwm2_enable\n')
        for name in ['timer', 'service']:
            self.write(f'etc/systemd/system/hdd-fanwall-control.{name}', 'previous unit\n')
        for name, value in [('pwm2', '120'), ('pwm2_enable', '1')]:
            self.write(f'sys/class/hwmon/hwmon0/{name}', value + '\n')
        self.write('run/hdd_fanwall_control.state', 'previous state\n')
        self.write('run/hdd_fanwall_control.state.lock', '')
        self.mock('systemctl', '''echo "$*" >> /run/events
if [[ "${FAIL_SERVICE:-0}" = 1 && "$*" = 'start hdd-fanwall-control.service' ]]; then exit 1; fi
exit 0
''')
        self.mock('update_cron', 'echo update_cron >> /run/events\n')
        self.mock('crontab', '''if [[ "$1" = -l ]]; then
  cat /run/root.crontab
else
  cp "$1" /run/root.crontab
fi
''')

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def mock(self, name, body):
        self.write('mocks/' + name, '#!/bin/bash\nset -eu\n' + body).chmod(0o755)

    def run_script(self, script, *args, ok=True, **env):
        command = ['bwrap', '--unshare-all', '--uid', '0', '--gid', '0', '--die-with-parent', '--ro-bind', '/', '/',
                   '--dev', '/dev', '--proc', '/proc']
        for name in ['etc', 'run', 'sys', 'usr/local', 'var', 'boot', 'tmp']:
            command += ['--bind', str(self.root / name), '/' + name]
        if Path('/etc/alternatives').is_dir():
            command += ['--ro-bind', '/etc/alternatives', '/etc/alternatives']
        command += ['--ro-bind', str(self.release), '/tmp/release',
                    '--ro-bind', str(self.root / 'mocks'), '/tmp/mocks',
                    '--setenv', 'PATH', '/tmp/mocks:/usr/bin:/bin']
        for key, value in env.items():
            command += ['--setenv', key, str(value)]
        result = subprocess.run(command + ['bash', '/tmp/release/' + script, *args],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_deploy_preflight_does_not_touch_install(self):
        old = (self.root / 'usr/local/sbin/hdd_fanwall_control.sh').read_bytes()
        self.run_script('deploy-proxmox.sh', ok=False, PREFLIGHT_FAIL=1)
        self.assertEqual((self.root / 'usr/local/sbin/hdd_fanwall_control.sh').read_bytes(), old)
        self.assertFalse((self.root / 'run/events').exists())

    def test_deploy_restarts_timer_and_preserves_or_replaces_config(self):
        old = (self.root / 'etc/hdd-fanwall-control.cfg').read_bytes()
        self.run_script('deploy-proxmox.sh')
        self.assertEqual((self.root / 'etc/hdd-fanwall-control.cfg').read_bytes(), old)
        self.run_script('deploy-proxmox.sh', '--force-config')
        self.assertEqual((self.root / 'etc/hdd-fanwall-control.cfg').read_bytes(),
                         (self.release / 'proxmox/etc/hdd-fanwall-control.cfg').read_bytes())
        self.assertTrue(list((self.root / 'etc').glob('hdd-fanwall-control.cfg.bak.*')))
        events = (self.root / 'run/events').read_text()
        self.assertIn('restart hdd-fanwall-control.timer', events)
        self.assertIn('start hdd-fanwall-control.service', events)

    def test_deploy_failure_restores_old_files(self):
        old_script = (self.root / 'usr/local/sbin/hdd_fanwall_control.sh').read_bytes()
        old_config = (self.root / 'etc/hdd-fanwall-control.cfg').read_bytes()
        self.run_script('deploy-proxmox.sh', '--force-config', ok=False, FAIL_SERVICE=1)
        self.assertEqual((self.root / 'usr/local/sbin/hdd_fanwall_control.sh').read_bytes(), old_script)
        self.assertEqual((self.root / 'etc/hdd-fanwall-control.cfg').read_bytes(), old_config)
        self.assertIn('start hdd-fanwall-control.timer', (self.root / 'run/events').read_text())

    def test_proxmox_uninstall_full_speed_and_cleanup(self):
        self.run_script('uninstall-proxmox.sh', '--remove-config')
        self.assertEqual((self.root / 'sys/class/hwmon/hwmon0/pwm2').read_text(), '255\n')
        for name in ['usr/local/sbin/hdd_fanwall_control.sh', 'etc/hdd-fanwall-control.cfg',
                     'run/hdd_fanwall_control.state', 'run/hdd_fanwall_control.state.lock']:
            self.assertFalse((self.root / name).exists())
        self.run_script('uninstall-proxmox.sh', '--remove-config')  # repeat is harmless

    def test_proxmox_uninstall_failed_handoff_retains_controller(self):
        self.mock('cat', 'echo 0\n')
        self.run_script('uninstall-proxmox.sh', ok=False)
        self.assertTrue((self.root / 'usr/local/sbin/hdd_fanwall_control.sh').exists())
        self.assertTrue((self.root / 'etc/systemd/system/hdd-fanwall-control.timer').exists())
        self.assertIn('start hdd-fanwall-control.timer', (self.root / 'run/events').read_text())

    def unraid_fixture(self):
        target = '/boot/config/plugins/user.scripts/scripts/hdd_temp_export_virtiofs/script'
        unrelated = target.replace('hdd_temp_export_virtiofs', 'other')
        schedules = {target: {'script': target, 'frequency': 'custom'},
                     unrelated: {'script': unrelated, 'frequency': 'daily'}}
        for name in ['boot/config/plugins/user.scripts/schedule.json', 'tmp/user.scripts/schedule.json']:
            self.write(name, json.dumps(schedules))
        self.write(target.lstrip('/'), '#!/bin/bash\nbash /boot/config/custom/hdd_temp_export_virtiofs.sh\n')
        self.write(unrelated.lstrip('/'), 'unrelated\n')
        cron = f'* * * * * /usr/local/emhttp/plugins/user.scripts/startCustom.php {target}\n'
        keep = '* * * * * /usr/bin/true\n'
        self.write('boot/config/plugins/user.scripts/customSchedule.cron', cron + keep)
        self.write('run/root.crontab', cron + '* * * * * bash /boot/config/custom/hdd_temp_export_virtiofs.sh\n' + keep)
        self.write('boot/config/custom/hdd_temp_export_virtiofs.sh', 'exporter\n')
        self.write('boot/config/custom/hdd_temp_export_virtiofs.conf',
                   'MOUNT_POINT=/tmp/share\nOUTPUT_FILE=/tmp/share/hdd_temp_status.env\nDETAIL_FILE=/tmp/share/hdd_temp_detail.tsv\n')
        for name in ['hdd_temp_status.env', 'hdd_temp_detail.tsv', '.hdd_temp_export.lock', 'unrelated']:
            self.write('tmp/share/' + name, 'keep or remove\n')
        return target, unrelated, keep

    def test_unraid_uninstall_removes_only_exporter_schedule_and_files(self):
        target, unrelated, keep = self.unraid_fixture()
        self.run_script('uninstall-unraid.sh')
        for name in ['boot/config/plugins/user.scripts/schedule.json', 'tmp/user.scripts/schedule.json']:
            schedule = json.loads((self.root / name).read_text())
            self.assertNotIn(target, schedule)
            self.assertIn(unrelated, schedule)
        self.assertEqual((self.root / 'run/root.crontab').read_text(), keep)
        self.assertEqual((self.root / 'boot/config/plugins/user.scripts/customSchedule.cron').read_text(), keep)
        self.assertFalse((self.root / target.lstrip('/')).exists())
        self.assertTrue((self.root / unrelated.lstrip('/')).exists())
        self.assertTrue((self.root / 'boot/config/custom/hdd_temp_export_virtiofs.conf').exists())
        self.assertEqual(sorted(p.name for p in (self.root / 'tmp/share').iterdir()), ['unrelated'])
        self.run_script('uninstall-unraid.sh', '--remove-config')
        self.assertFalse((self.root / 'boot/config/custom/hdd_temp_export_virtiofs.conf').exists())

    def test_unraid_invalid_schedule_aborts_before_changes(self):
        self.unraid_fixture()
        self.write('tmp/user.scripts/schedule.json', '{broken')
        self.run_script('uninstall-unraid.sh', ok=False)
        self.assertTrue((self.root / 'boot/config/custom/hdd_temp_export_virtiofs.sh').exists())
        self.assertIn('hdd_temp_export_virtiofs', (self.root / 'run/root.crontab').read_text())


if __name__ == '__main__':
    unittest.main()
