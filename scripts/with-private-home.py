#!/usr/bin/env python3
"""Run a local package check with a private passwd home, even through AppRun.

Usage: python3 with-private-home.py UNUSED_DIRECTORY [--read INPUT] -- COMMAND...
The project and /tmp remain writable; other host files are read-only. No real
home defaults or user session bus are exposed. Working files are retained.
"""
import argparse
import os
from pathlib import Path
import pwd
import subprocess
import sys

home = pwd.getpwuid(os.getuid()).pw_dir
if sys.argv[1:] == ['--check']:
    private = os.environ.get('PD_PRIVATE_HOME_DIR', '')
    sys.exit(0 if private and private != home and Path(private).is_dir()
             and os.path.samefile(private, home) else 1)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=Path)
parser.add_argument('--read', action='append', type=Path, default=[])
if '--' not in sys.argv:
    parser.error('Separate COMMAND from options with --')
separator = sys.argv.index('--')
args = parser.parse_args(sys.argv[1:separator])
command = sys.argv[separator + 1:]
if not command:
    parser.error('COMMAND is required')
scratch = args.directory.resolve()
scratch.mkdir(mode=0o700, parents=True)  # Never reuse a previous check's home.
for name in ('home', 'run'):
    (scratch / name).mkdir(mode=0o700)
repo = Path(__file__).resolve().parents[1]
try:
    lookup = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--git-common-dir'],
                            text=True, capture_output=True)
except FileNotFoundError:
    lookup = None
original_repo = (repo / lookup.stdout.strip()).resolve().parent if lookup and lookup.returncode == 0 else repo
runtime = f'/run/user/{os.getuid()}'
runtime_exists = Path(runtime).is_dir()
if not runtime_exists:
    runtime = str(scratch / 'run')
wrapped = ['bwrap', '--unshare-user', '--die-with-parent', '--ro-bind', '/', '/', '--bind', '/tmp', '/tmp',
           '--dev-bind', '/dev', '/dev', '--proc', '/proc',
           '--bind', str(scratch / 'home'), home,
           '--bind', str(repo), str(repo),
           '--bind', str(original_repo), str(original_repo),
           '--setenv', 'HOME', home, '--setenv', 'GNUSTEP_HOME', home,
           '--setenv', 'PD_PRIVATE_HOME_DIR', str(scratch / 'home'),
           '--setenv', 'XDG_RUNTIME_DIR', runtime,
           '--setenv', 'XDG_CONFIG_HOME', home + '/.config',
           '--setenv', 'XDG_DATA_HOME', home + '/.local/share',
           '--setenv', 'XDG_CACHE_HOME', home + '/.cache',
           '--setenv', 'DBUS_SESSION_BUS_ADDRESS', 'unix:path=/nonexistent',
           '--chdir', os.getcwd()]
if runtime_exists:
    wrapped += ['--bind', str(scratch / 'run'), runtime]
for path in args.read:
    path = path.resolve(strict=True)
    wrapped += ['--ro-bind', str(path), str(path)]
os.execvp(wrapped[0], wrapped + ['--', *command])
