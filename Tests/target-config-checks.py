#!/usr/bin/env python3
"""Inspect actual launched target environments through an extracted CLI wrapper.

Run in a private passwd home. APPDIR must contain the candidate wrapper,
gstrace-bin, runtime libraries and GNUstep.conf; this script never changes it.
"""
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

if len(sys.argv)!=3:
    raise SystemExit('usage: target-config-checks.py APPDIR OUTPUT_DIRECTORY')
repo=Path(__file__).resolve().parents[1]
subprocess.run([sys.executable,str(repo/'scripts/with-private-home.py'),'--check'],check=True)
appdir=Path(sys.argv[1]).resolve()
output=Path(sys.argv[2]).resolve()
output.mkdir(parents=True,exist_ok=True)
root=Path(tempfile.mkdtemp(prefix='target-config-',dir=output))
wrapper=appdir/'usr/runtime/bin/gstrace'
assert wrapper.is_file()
fixture=root/'exitstatus'
subprocess.run(shlex.split(os.environ.get('CC','cc'))+
               ['-O1',str(repo/'Tests/fixtures/exitstatus.c'),'-o',str(fixture)],check=True)
scratch=root/'caller config.conf'
packaged_config=appdir/'usr/runtime/etc/GNUstep/GNUstep.conf'
lines=[]
for line in packaged_config.read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        key,value=line.split('=',1)
        if value.startswith(('./','../')):
            line=key+'='+str((packaged_config.parent/value).resolve())
    lines.append(line)
scratch.write_text('\n'.join(lines)+
                   '\nGNUSTEP_USER_DEFAULTS_DIR='+str(root/'target-defaults')+'\n')
override=root/'explicit.conf'
override.write_bytes(scratch.read_bytes())
host_config=root/'first-host.conf'
host_config.write_bytes(scratch.read_bytes())

def environ(pid):
    return dict(part.split(b'=',1) for part in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0') if b'=' in part)

def owned_target(pid):
    try:
        return Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')[0]==os.fsencode(fixture)
    except OSError:
        return False

results=[]
for mode in ('set','unset','empty','explicit-override','nested-snapshot',
             'host-set','host-unset','host-empty'):
    env={k:v for k,v in os.environ.items() if not k.startswith(('PD_TARGET_','GP_HOST_'))
         and k not in ('APPDIR','APPIMAGE','ARGV0','OWD','GNUSTEP_CONFIG_FILE')}
    env['GSP_AGENT_PATH']=str(appdir/'usr/runtime/lib/libgsperf-agent.so')
    if mode!='unset': env['GNUSTEP_CONFIG_FILE']='' if mode=='empty' else str(scratch)
    if mode=='nested-snapshot':
        env.update(PD_TARGET_GNUSTEP_CONFIG_FILE_SET='1',PD_TARGET_GNUSTEP_CONFIG_FILE=str(scratch),
                   GNUSTEP_CONFIG_FILE=str(appdir/'usr/runtime/etc/GNUstep/GNUstep.conf'))
    if mode.startswith('host-'):
        env.update(GP_HOST_VARS='PATH GNUSTEP_CONFIG_FILE',
                   GP_HOST_UNSET='GNUSTEP_CONFIG_FILE' if mode=='host-unset' else '',
                   GP_HOST_GNUSTEP_CONFIG_FILE=str(host_config) if mode=='host-set' else '',
                   GP_HOST_PWD=str(root))
    trace=root/(mode+'.gstrace')
    options=['--env','GNUSTEP_CONFIG_FILE='+str(override)] if mode=='explicit-override' else []
    command=[str(wrapper),'record','--instrument','time-profiler','--time-limit','2s',
             '--output',str(trace),*options,'--launch',str(fixture),'loop']
    target=0
    error=None
    with (root/(mode+'.log')).open('w') as log:
        process=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT)
        try:
            deadline=time.monotonic()+8
            while time.monotonic()<deadline:
                if process.poll() is not None: raise AssertionError('recorder exited before environment check')
                info=trace/'Info.plist'
                if info.exists():
                    match=re.search(r'TargetPID\s*=\s*<\*I(\d+)>',info.read_text())
                    if match:
                        target=int(match[1])
                        if owned_target(target): break
                time.sleep(.02)
            assert target>1 and owned_target(target),'owned target did not start'
            actual=environ(target)
            expected=None if mode in ('unset','host-unset') else (b'' if mode in ('empty','host-empty')
                     else os.fsencode(host_config if mode=='host-set' else override if mode=='explicit-override' else scratch))
            assert actual.get(b'GNUSTEP_CONFIG_FILE')==expected,(actual.get(b'GNUSTEP_CONFIG_FILE'),expected)
            assert b'PD_TARGET_GNUSTEP_CONFIG_FILE' not in actual
            assert b'PD_TARGET_GNUSTEP_CONFIG_FILE_SET' not in actual
            assert not any(key.startswith(b'GP_HOST_') for key in actual)
            result=dict(case=mode,status='PASS',target_pid=target,
                        config_present=b'GNUSTEP_CONFIG_FILE' in actual,
                        config_value=actual.get(b'GNUSTEP_CONFIG_FILE',b'').decode())
        except (AssertionError,OSError) as caught:
            error=str(caught)
            result=dict(case=mode,status='FAIL',error=error)
        finally:
            forced_cleanup=False
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try: process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    forced_cleanup=True
                    process.kill();process.wait(timeout=3)
            if target>1 and owned_target(target):
                forced_cleanup=True
                os.kill(target,signal.SIGKILL)
            if process.returncode!=0 or forced_cleanup:
                result.update(status='FAIL',error='recorder exit or owned-process cleanup failed',
                              recorder_exit=process.returncode,forced_cleanup=forced_cleanup)
                error=result['error']
    results.append(result)
    print(result['status'],mode, error or '',flush=True)
(root/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print('Evidence:',root)
raise SystemExit(0 if all(x['status']=='PASS' for x in results) else 1)
