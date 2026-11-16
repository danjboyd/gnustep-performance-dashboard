#!/usr/bin/env python3
"""Offline shell/make harness fixtures. No compiler, X server or application."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]

class HarnessChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pd-csd-harness-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_real_make_overrides_survive_config_reset_and_nested_make_without_sdk_mutation(self):
        project=self.root/'project'; sdk=self.root/'sdk'; runner=self.root/'runner'; evidence=self.root/'evidence'
        (project/'scripts').mkdir(parents=True)
        shutil.copy2(ROOT/'scripts/csd-test-build.sh',project/'scripts/csd-test-build.sh')
        makefiles=sdk/'System/Library/Makefiles';makefiles.mkdir(parents=True)
        (makefiles/'GNUstep.sh').write_text(f'export GNUSTEP_MAKEFILES={makefiles}\n')
        (makefiles/'common.make').write_text('GNUSTEP_MAKEFILES := /wrong-config-path\nXCTEST_INCLUDE_DIR := /wrong-includes\n')
        (runner/'obj').mkdir(parents=True);(runner/'XCTest/obj').mkdir(parents=True)
        (runner/'obj/xctest').write_text('#!/bin/sh\nexit 0\n');(runner/'obj/xctest').chmod(0o755)
        (runner/'xctest.make').write_text('check:\n\t@test -f "$(GNUSTEP_MAKEFILES)/Auxiliary/xctest.make"\n\t@test "$(XCTEST_INCLUDE_DIR)" = "'+str(runner)+'"\n\t@test "$(XCTEST_LIBRARY_DIR)" = "'+str(runner/'XCTest/obj')+'"\n\t@echo "fixture check PASS"\n')
        (project/'Tests/Unit').mkdir(parents=True)
        (project/'Tests/Unit/GNUmakefile').write_text('include $(GNUSTEP_MAKEFILES)/common.make\ninclude $(GNUSTEP_MAKEFILES)/Auxiliary/xctest.make\n')
        (project/'Tests/run.sh').write_text('set -eu\nmake -s -C "$(dirname "$0")/Unit" check\n')
        snapshot={str(p.relative_to(sdk)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sdk.rglob('*') if p.is_file()}
        command=['bash',str(project/'scripts/csd-test-build.sh'),str(sdk),str(runner),str(evidence)]
        result=subprocess.run(command,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('fixture check PASS',(evidence/'logs/unit.log').read_text())
        self.assertIn('fixture check PASS',(evidence/'logs/headless.log').read_text())
        self.assertIn('GNUSTEP_MAKEFILES=',(evidence/'make-overrides.txt').read_text())
        self.assertEqual(snapshot,{str(p.relative_to(sdk)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sdk.rglob('*') if p.is_file()})
        again=subprocess.run(command,text=True,capture_output=True)
        self.assertNotEqual(again.returncode,0)
        self.assertIn('stale evidence',again.stderr)

    def test_relative_or_whitespace_paths_refuse_before_any_build(self):
        for bad in ['relative','/tmp/has space']:
            r=subprocess.run(['bash',str(ROOT/'scripts/csd-test-build.sh'),bad,'/missing/runner',str(self.root/'out')],capture_output=True,text=True)
            self.assertNotEqual(r.returncode,0)
            self.assertIn('absolute paths without whitespace',r.stderr)

    def test_reserved_or_nonnumeric_displays_refuse_without_starting_xvfb(self):
        for display in [':0',':120',':0120',':foo','151']:
            env=dict(os.environ,PD_PRIVATE_X_DISPLAY=display)
            r=subprocess.run(['bash','-c','. "$1"; pd_start_private_xvfb "$2"','harness',str(ROOT/'scripts/private-xvfb.sh'),str(self.root/'xvfb.log')],env=env,capture_output=True,text=True)
            self.assertNotEqual(r.returncode,0)
            self.assertIn('other than :0/:120',r.stderr)
            self.assertFalse((self.root/'xvfb.log').exists())

    def test_package_and_record_use_shared_pinned_logged_display(self):
        for name in ['package-linux.sh','check-appimage-record.sh']:
            s=(ROOT/'scripts'/name).read_text()
            self.assertIn('pd_start_private_xvfb "$work/xvfb.log"',s)
            self.assertNotIn('Xvfb -displayfd',s)
        source=(ROOT/'scripts/private-xvfb.sh').read_text()
        self.assertIn('PD_PRIVATE_X_DISPLAY:-:151',source)
        self.assertIn('refusing occupied display',source)
        self.assertIn('owned_pid=',source)

    def test_shell_syntax(self):
        for name in ['private-xvfb.sh','csd-test-build.sh','package-linux.sh','check-appimage-record.sh']:
            subprocess.run(['bash','-n',str(ROOT/'scripts'/name)],check=True)

if __name__=='__main__':unittest.main()
