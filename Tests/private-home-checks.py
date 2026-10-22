#!/usr/bin/env python3
"""Verify the actual helper's CI dispatch and development-home veto."""
from contextlib import redirect_stderr
import io
import os
from pathlib import Path
import runpy
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

helper = Path(__file__).resolve().parents[1] / 'scripts/with-private-home.py'
checks = 0


class Executed(Exception):
    pass


def invoke(home, env, check=False, missing_bwrap=False):
    calls = []

    def direct(file, args, environment):
        calls.append(('direct', args, environment))
        raise Executed()

    def wrapped(file, args):
        calls.append(('bwrap', args, dict(os.environ)))
        if missing_bwrap:
            raise FileNotFoundError('bwrap is unavailable')
        raise Executed()

    with tempfile.TemporaryDirectory() as scratch:
        argv = [str(helper), '--check'] if check else [str(helper), scratch + '/home', '--', '/bin/true']
        log = io.StringIO()
        with patch.dict(os.environ, env, clear=True), patch('pwd.getpwuid', return_value=SimpleNamespace(pw_dir=home)), \
             patch.object(sys, 'argv', argv), patch('os.execvpe', side_effect=direct), \
             patch('os.execvp', side_effect=wrapped), redirect_stderr(log):
            try:
                runpy.run_path(str(helper), run_name='__main__')
            except Executed:
                return calls[0], log.getvalue()
            except SystemExit as error:
                return error.code, log.getvalue()
            except FileNotFoundError:
                return 'missing-bwrap', log.getvalue()
    raise AssertionError('Helper returned without checking or executing')


for flag in ('GITHUB_ACTIONS', 'CI'):
    result, log = invoke('/root', {flag: 'true'})
    assert result[0] == 'direct' and result[1] == ['/bin/true']
    assert result[2]['PD_PRIVATE_HOME_MODE'] == 'ephemeral-ci' and 'no bwrap' in log
    checks += 1
    result, log = invoke('/root', {flag: 'true'}, check=True)
    assert result == 0 and 'existing runner isolation' in log
    checks += 1
    result, log = invoke('/home/danboyd', {flag: 'true', 'PD_PRIVATE_HOME_MODE': 'ephemeral-ci'})
    assert result[0] == 'bwrap' and result[1][0] == 'bwrap' and '/home/danboyd' in result[1]
    checks += 1
    result, log = invoke('/home/danboyd', {flag: 'true'}, check=True)
    assert result == 1 and 'no bwrap' not in log
    checks += 1

for env in ({}, {'CI': 'false'}, {'CI': '1'}, {'GITHUB_ACTIONS': 'false'}):
    result, log = invoke('/root', env)
    assert result[0] == 'bwrap' and 'no bwrap' not in log
    checks += 1
    result, log = invoke('/root', env, check=True)
    assert result == 1
    checks += 1

for home, env in (('/home/danboyd', {'CI': 'true'}), ('/root', {})):
    result, log = invoke(home, env, missing_bwrap=True)
    assert result == 'missing-bwrap' and 'no bwrap' not in log
    checks += 1

# The diagnostic lives separately; when present, its reexec marker must not
# loop in CI or bypass the dev-home veto.
benchmark = helper.with_name('benchmark-trace-load.py')
for home in (('/root', '/home/danboyd') if benchmark.is_file() else ()):
    with tempfile.TemporaryDirectory() as scratch:
        output = Path(scratch) / 'results'
        argv = [str(benchmark), scratch + '/missing.AppImage', scratch + '/input.gstrace', str(output)]
        def reexec(file, args):
            raise Executed()
        with patch.dict(os.environ, {'CI': 'true', 'PD_PRIVATE_HOME_MODE': 'ephemeral-ci'}, clear=True), \
             patch('pwd.getpwuid', return_value=SimpleNamespace(pw_dir=home)), \
             patch.object(sys, 'argv', argv), patch('os.execv', side_effect=reexec):
            try:
                runpy.run_path(str(benchmark), run_name='__main__')
            except Executed:
                assert home == '/home/danboyd' and not output.exists()
            except FileNotFoundError:
                assert home == '/root' and output.exists()
            else:
                raise AssertionError('Expected input validation or protected-home reexec')
        checks += 1

print(f'All {checks} private-home dispatch checks passed.')
