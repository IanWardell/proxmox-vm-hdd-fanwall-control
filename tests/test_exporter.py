import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'unraid/boot-config-custom/hdd_temp_export_virtiofs.sh'


class ExporterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.cfg = self.root / 'config'
        values = dict(MOUNT_POINT=str(self.root), OUTPUT_FILE=str(self.root / 'summary'),
                      DETAIL_FILE=str(self.root / 'detail'), LOG_FILE=str(self.root / 'log'),
                      VIRTIOFS_TAG='test', SMART_STANDBY_MODE='yes', ONLY_ROTATIONAL_DISKS='yes',
                      HOT_TEMP_C=42)
        self.cfg.write_text(''.join(f'{k}={shlex.quote(v)}\n' for k, v in
                                   ((k, str(v)) for k, v in values.items())))
        self.env = dict(os.environ, CONFIG_FILE=str(self.cfg), TEST_ROOT=str(self.root),
                        PATH=f'{self.bin}:{os.environ["PATH"]}')
        self.mock('mountpoint', 'exit 0')
        self.mock('lsblk', '''cat <<'EOF'
PATH="/dev/sda" TYPE="disk" RM="0" TRAN="sata" ROTA="1"
PATH="/dev/sdb" TYPE="disk" RM="0" TRAN="" ROTA="1"
PATH="/dev/sdc" TYPE="disk" RM="0" TRAN="sas" ROTA="1"
PATH="/dev/sdd" TYPE="disk" RM="0" TRAN="usb" ROTA="1"
PATH="/dev/sde" TYPE="disk" RM="0" TRAN="sata" ROTA="0"
EOF''')
        self.mock('smartctl', '''printf '%s\\n' "$*" >> "$TEST_ROOT/queries"
disk="${!#}"
cat "$TEST_ROOT/${disk##*/}"''')

    def mock(self, name, body):
        file = self.bin / name
        file.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
        file.chmod(0o755)

    def disk(self, name, temp=None, standby=False, invalid=False):
        content = f'Serial Number: serial-{name}\nDevice Model: test disk\n'
        if standby:
            content += 'Device is in STANDBY mode, exit(2)\n'
        elif not invalid:
            content += f'Current Drive Temperature: {temp} C\n'
        (self.root / name).write_text(content)

    def run_export(self, ok=True):
        result = subprocess.run(['bash', str(SCRIPT)], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr)
        if ok:
            return dict(line.split('=', 1) for line in (self.root / 'summary').read_text().splitlines())

    def test_counts_details_and_standby_safe_queries(self):
        self.disk('sda', 41)
        self.disk('sdb', 43)
        self.disk('sdc', standby=True)
        result = self.run_export()
        self.assertEqual([result[k] for k in ['DISK_COUNT', 'TEMP_COUNT', 'STANDBY_COUNT',
                                              'UNKNOWN_COUNT', 'HOT_DRIVE_COUNT', 'MAX_TEMP_C']],
                         ['3', '2', '1', '0', '1', '43'])
        detail = (self.root / 'detail').read_text()
        self.assertTrue(detail.startswith('serial\tmodel\tdevice\tstate\ttemp_c\n'))
        self.assertIn('/dev/sdb\tactive\t43', detail)
        queries = (self.root / 'queries').read_text().splitlines()
        self.assertEqual(len(queries), 3)
        self.assertTrue(all(q.startswith('-n standby -i -A ') for q in queries))

    def test_all_standby_publishes_fresh_summary(self):
        for disk in ['sda', 'sdb', 'sdc']:
            self.disk(disk, standby=True)
        result = self.run_export()
        self.assertEqual((result['TEMP_COUNT'], result['STANDBY_COUNT'], result['MAX_TEMP_C']),
                         ('0', '3', '0'))

    def test_unknown_and_no_good_temperature_preserves_summary(self):
        self.disk('sda', 41)
        self.disk('sdb', invalid=True)
        self.disk('sdc', standby=True)
        self.assertEqual(self.run_export()['UNKNOWN_COUNT'], '1')
        previous = (self.root / 'summary').read_bytes()
        self.disk('sda', invalid=True)
        self.run_export(ok=False)
        self.assertEqual((self.root / 'summary').read_bytes(), previous)
        self.assertIn('/dev/sda\tunknown\t', (self.root / 'detail').read_text())
        self.assertFalse(list(self.root.glob('*.tmp.*')))


if __name__ == '__main__':
    unittest.main()
