#!/usr/bin/env python3
"""Exercise the real walker in a non-PIE target with an _r_debug COPY."""
import os
from pathlib import Path
import platform
import resource
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
if platform.machine() != 'x86_64':
    print('SKIP x86_64 GCC COPY relocation fixture (native arch-context still runs)')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='pd-loader-debug-') as tmp:
    binary = Path(tmp) / 'copy-target'
    subprocess.run(['gcc', '-D_GNU_SOURCE', '-DGSP_TEST_COPY_RELOC', '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-fno-pie', '-no-pie', '-I' + str(ROOT / 'Runtime/include'), str(ROOT / 'Tests/fixtures/arch-context.c'), '-ldl', '-pthread', '-o', str(binary)], check=True)
    relocations = subprocess.check_output(['readelf', '-rW', str(binary)], text=True)
    assert any('R_X86_64_COPY' in line and '_r_debug' in line for line in relocations.splitlines()), relocations
    output = subprocess.check_output([str(binary)], text=True)
    assert 'counter' in output and 'PASS COPY-relocated r_debug bypass' in output, output
    print(output, end='')
    loader = os.environ.get('PD_GLIBC239_LOADER')
    if loader:
        output = subprocess.check_output([loader, '--library-path', str(Path(loader).parent), str(binary)], text=True)
        assert 'copy=1 loader=0' in output, output
        print('Ubuntu 2.39: ' + output, end='')
        # Negative control: same walker, restore only its old GOT guard.
        old = Path(tmp) / 'old-unwind.c'
        old.write_text((ROOT / 'Runtime/gsp_unwind.c').read_text().replace(
            'return ((volatile struct r_debug *)loader_debug)->r_state != RT_CONSISTENT;',
            'return _r_debug.r_state != RT_CONSISTENT;'))
        fixture = Path(tmp) / 'old-target.c'
        fixture.write_text((ROOT / 'Tests/fixtures/arch-context.c').read_text().replace(
            '../../Runtime/gsp_unwind.c', str(old)))
        negative = Path(tmp) / 'old-copy-target'
        subprocess.run(['gcc', '-D_GNU_SOURCE', '-DGSP_TEST_COPY_RELOC', '-std=gnu11', '-fno-pie', '-no-pie',
                        '-I' + str(ROOT / 'Runtime'), '-I' + str(ROOT / 'Runtime/include'), str(fixture),
                        '-ldl', '-pthread', '-o', str(negative)], check=True)
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        result = subprocess.run([loader, '--library-path', str(Path(loader).parent), str(negative)],
                                text=True, capture_output=True)
        assert result.returncode != 0 and 'gsp_loader_busy' in result.stderr, result
        print('PASS negative control: old GOT guard fails under Ubuntu 2.39')
    else:
        print('SKIP optional Ubuntu 2.39 loader: set PD_GLIBC239_LOADER to a retained loader')
