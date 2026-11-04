"""Exercise setup's public CLI without package or native-system mutations."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class SetupChecks(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]
        self.compiler = os.environ.get('SETUP_TEST_V') or shutil.which('v')
        if not self.compiler:
            self.skipTest('V compiler unavailable')
        self.temporary = tempfile.TemporaryDirectory(prefix='allocator setup with spaces ')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.log = self.work / 'commands.jsonl'
        self.modules = self.work / 'modules'
        setup = self.modules / 'antono2/vulkan/setup.vsh'
        setup.parent.mkdir(parents=True)
        setup.write_text('// Native setup is intercepted by the fixture CLI.\n')
        fake = self.work / 'fake_v.py'
        fake.write_text('import json, os, sys\n'
                        'with open(os.environ["SETUP_COMMAND_LOG"], "a") as log:\n'
                        '    log.write(json.dumps(sys.argv[1:])+"\\n")\n')
        if os.name == 'nt':
            (self.work / 'v.cmd').write_text(f'@echo off\n"{sys.executable}" "{fake}" %*\n')
        else:
            cli = self.work / 'v'
            cli.write_text(f'#!{sys.executable}\n'+fake.read_text())
            cli.chmod(0o755)
        self.env = dict(os.environ, VMODULES=str(self.modules),
                        SETUP_COMMAND_LOG=str(self.log), V_C_ERROR_BUG_REPORT_DISABLED='1')
        self.env['PATH'] = str(self.work)+os.pathsep+os.environ['PATH']

    def run_setup(self, *args, expected=0):
        result = subprocess.run([self.compiler, 'run', str(self.root / 'setup.vsh'), *args],
                                env=self.env, cwd=self.work, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout+result.stderr)
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_install_uses_declared_dependency_versions(self):
        commands = self.run_setup('--install')
        pins = json.loads((self.root / 'compatibility.json').read_text())['modules']
        installs = [args[1] for args in commands if args[0] == 'install']
        self.assertEqual(installs, [f'antono2.vulkan@{pins["vulkan"]}',
                                    f'antono2.memory@{pins["memory"]}', 'antono2.vkmemalloc'])
        self.assertEqual(commands[1], ['run', str(self.modules / 'antono2/vulkan/setup.vsh'), '--install'])
        self.assertEqual(commands[-1], ['test', str(self.root)])

    def test_check_performs_no_installs(self):
        self.assertEqual(self.run_setup('--check'), [
            ['run', str(self.modules / 'antono2/vulkan/setup.vsh'), '--check'],
            ['test', str(self.root)]])

    def test_invalid_option_performs_no_commands(self):
        self.assertEqual(self.run_setup('--unknown', expected=2), [])


if __name__ == '__main__':
    unittest.main()
