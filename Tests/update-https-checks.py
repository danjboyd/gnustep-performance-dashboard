#!/usr/bin/env python3
"""Private real-updater HTTPS read gate using an extracted candidate runtime.

Pass a private config and an unused output directory. This does not apply an
update or change a feed. For negative cases, retain server handshake evidence
and review the precise certificate/host error; any arbitrary failure is not
proof of correct TLS rejection. Private errors/CA/host details are not public.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('appdir', type=Path)
parser.add_argument('config', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--expect-failure', action='store_true')
parser.add_argument('--through-apprun', action='store_true',
                    help='Run the adapter at the app entry in a retained private AppDir copy; AppRun is unchanged')
parser.add_argument('--observe-weakened-environment', action='store_true',
                    help='Diagnostic only: observe an explicitly false caller GS_TLS_VERIFY_S; never qualifies TLS')
parser.add_argument('--tls-diagnostics', action='store_true', help='Retain private GSTLS diagnostics')
parser.add_argument('--fixture-ca', type=Path,
                    help='Append a throwaway test CA only to the private AppDir copy, never the candidate or host')
args = parser.parse_args()
subprocess.run([sys.executable, str(ROOT/'scripts/with-private-home.py'), '--check'], check=True)
for key, value in os.environ.items():
    if key.startswith('GS_TLS_VERIFY') and value.lower() in ('no', 'false', '0'):
        if not (args.observe_weakened_environment and key == 'GS_TLS_VERIFY_S'):
            raise SystemExit('TLS verification is disabled in the caller; refusing qualification')
if args.observe_weakened_environment and os.environ.get('GS_TLS_VERIFY_S', '').lower() not in ('no', 'false', '0'):
    raise SystemExit('Diagnostic requires an explicitly false caller GS_TLS_VERIFY_S')
if not args.observe_weakened_environment and 'GS_TLS_VERIFY_S' in os.environ:
    raise SystemExit('Default-policy gate requires GS_TLS_VERIFY_S absent from the caller')
if args.fixture_ca and not args.through_apprun:
    raise SystemExit('--fixture-ca requires a private --through-apprun copy')
config = json.loads(args.config.read_text())
assert config['updates']['feedUrl'].startswith('https://')
if args.output.resolve().is_relative_to(args.appdir.resolve(strict=True)):
    raise SystemExit('Evidence directory must be outside the original candidate AppDir')
args.output.mkdir(parents=True, exist_ok=False)
args.output.chmod(0o700)
core = ROOT/'third_party/gnustep-packager-updater/objc/GPUpdaterCore'
flags = shlex.split(subprocess.check_output(['gnustep-config', '--objc-flags'], text=True))
libs = shlex.split(subprocess.check_output(['gnustep-config', '--base-libs'], text=True))
program = args.output.resolve()/'https-fetch'
subprocess.run(['clang', *flags, '-fobjc-arc', '-I'+str(core/'Headers'),
    str(ROOT/'Tests/fixtures/update-https-fetch.m'), str(core/'libGPUpdaterCore.a'),
    '-o', str(program), *libs], check=True)
appdir = args.appdir.resolve(strict=True)
launch_receipt = {'throughAppRun': False, 'trustStore': 'candidate default'}
if args.through_apprun:
    original_launcher = appdir/'AppRun'
    assert original_launcher.is_file() and not original_launcher.is_symlink()
    assert 'GP_HOST_VARS' in original_launcher.read_text(), 'actual v0.1.10 AppRun required'
    copied = args.output.resolve()/'appdir-copy'
    shutil.copytree(appdir, copied, symlinks=True)
    # Keep the exact generated launcher and runtime; replace only the entry
    # executable in a separate owned copy to observe its launch environment.
    entry = copied/'usr/app/PerformanceDashboard.app/PerformanceDashboard'
    assert entry.is_file() and not entry.is_symlink() and entry.resolve().is_relative_to(copied)
    launch_receipt.update(throughAppRun=True,
        appRunSHA256=hashlib.sha256(original_launcher.read_bytes()).hexdigest(),
        originalAppSHA256=hashlib.sha256(entry.read_bytes()).hexdigest(),
        scope='actual AppRun and runtime, private adapter entry; not GUI updater acceptance')
    shutil.copy2(program, entry)
    assert (copied/'AppRun').read_bytes() == original_launcher.read_bytes()
    appdir = copied
    if args.fixture_ca:
        bundles = list((copied/'usr/runtime').rglob('GSTLS/ca-certificates.crt'))
        assert len(bundles) == 1 and bundles[0].resolve().is_relative_to(copied), 'one owned bundled CA store required'
        ca = args.fixture_ca.resolve(strict=True).read_bytes()
        assert b'-----BEGIN CERTIFICATE-----' in ca and b'PRIVATE KEY' not in ca
        original = bundles[0].read_bytes()
        # Replace a copied symlink rather than writing through it.
        if bundles[0].is_symlink(): bundles[0].unlink()
        bundles[0].write_bytes(original+b'\n'+ca+b'\n')
        launch_receipt.update(trustStore='private copy plus throwaway fixture CA',
            originalCAStoreSHA256=hashlib.sha256(original).hexdigest(),
            fixtureCASHA256=hashlib.sha256(ca).hexdigest(),
            testedCAStoreSHA256=hashlib.sha256(bundles[0].read_bytes()).hexdigest())
runtime = appdir/'usr/runtime'
env = dict(os.environ, LD_LIBRARY_PATH=str(runtime/'lib'),
           GNUSTEP_CONFIG_FILE=str(runtime/'etc/GNUstep/GNUstep.conf'))
# The trust inputs are the candidate's defaults, not a caller-supplied bypass.
for name in ('LD_PRELOAD', 'GS_TLS_CA_FILE', 'SSL_CERT_FILE', 'SSL_CERT_DIR'):
    env.pop(name, None)
if args.through_apprun:
    for name in list(env):
        if name in ('APPDIR', 'APPIMAGE', 'ARGV0', 'OWD') or name.startswith(('GP_HOST_', 'PD_TARGET_')):
            env.pop(name)
if args.tls_diagnostics: env['GS_TLS_DEBUG'] = '1'
result = subprocess.run([str(appdir/'AppRun') if args.through_apprun else str(program),
    str(args.config.resolve()), str(args.output.resolve()/'result.json'),
    str(args.output.resolve()/'maps-private.txt')],
    env=env, capture_output=True, timeout=60)
(args.output/'stderr-private.log').write_bytes(result.stderr)
receipt = json.loads((args.output/'result.json').read_text())
loaded = set()
for line in (args.output/'maps-private.txt').read_text().splitlines():
    fields = line.split(None, 5)
    if len(fields) == 6 and '/libgnustep-base.so' in fields[5]:
        loaded.add(Path(fields[5]).resolve())
assert len(loaded) == 1 and next(iter(loaded)).is_relative_to(runtime), 'candidate Base was not loaded'
receipt.update(exit=result.returncode,
    loadedBaseSHA256=hashlib.sha256(next(iter(loaded)).read_bytes()).hexdigest(),
    adapterSHA256=hashlib.sha256(program.read_bytes()).hexdigest(),
    coreSHA256=hashlib.sha256((core/'libGPUpdaterCore.a').read_bytes()).hexdigest(),
    launch=launch_receipt,
    qualification=('DIAGNOSTIC ONLY: explicitly weakened caller environment; no TLS acceptance claim'
                   if args.observe_weakened_environment else
                   'Pending review of negative-case TLS/server evidence' if args.expect_failure else
                   'Actual updater HTTPS feed read; certificate verification requires negative controls'))
(args.output/'receipt-private.json').write_text(json.dumps(receipt, indent=2)+'\n')
if args.observe_weakened_environment:
    assert result.returncode in (0, 1)
    print('Diagnostic observation retained; do not count as TLS qualification.')
elif args.expect_failure:
    assert result.returncode == 1 and receipt['feedReadSucceeded'] is False
    print('Negative fetch observed; verify private certificate/host error and server evidence before calling the TLS gate passed.')
else:
    assert result.returncode == 0 and receipt['feedReadSucceeded'] is True
    print('Actual updater HTTPS feed read succeeded; no update applied.')
