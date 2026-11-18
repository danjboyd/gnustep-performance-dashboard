#!/usr/bin/env python3
"""Pinned published v0.1.7 reader fixture for the normal Linux regression suite.

The first run caches the public AppImage; later runs need no network. Set
PD_LEGACY_APPIMAGE to an existing copy for offline validation. Never executes
its runtime or application: unsquashfs extracts the hash-checked payload.
"""
import hashlib
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NAME = 'PerformanceDashboard-0.1.7-x86_64.AppImage'
SHA256 = 'be3a2122b57bb2ba25dac4d69be558588393398d931e848d368c3618260f0557'
URL = 'https://github.com/danjboyd/gnustep-performance-dashboard/releases/download/v0.1.7/' + NAME


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def image():
    configured = os.environ.get('PD_LEGACY_APPIMAGE')
    path = Path(configured) if configured else ROOT / 'out/compatibility/v0.1.7' / NAME
    if not path.exists():
        if configured:
            raise ValueError('PD_LEGACY_APPIMAGE does not exist')
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path.parent) as temporary:
            with urllib.request.urlopen(URL, timeout=120) as source:
                shutil.copyfileobj(source, temporary)
            temporary.flush()
            if digest(Path(temporary.name)) != SHA256:
                raise ValueError('published legacy AppImage SHA256 mismatch')
            try:
                os.link(temporary.name, path)  # Never replace a concurrent cache entry.
            except FileExistsError:
                pass
    if digest(path) != SHA256:
        raise ValueError('published legacy AppImage SHA256 mismatch')
    return path.resolve()


def prepare(directory):
    spec = importlib.util.spec_from_file_location('legacy_extract', ROOT / '.github/scripts/custom-signing-adapter.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.extract_payload(image(), directory)
    runtime = directory / 'squashfs-root/usr/runtime'
    wrapper = directory / 'gstrace-v017'
    wrapper.write_text('#!/bin/sh\nexport LD_LIBRARY_PATH=' + shlex.quote(str(runtime / 'lib'))
                       + '\nexec ' + shlex.quote(str(runtime / 'bin/gstrace')) + ' "$@"\n')
    wrapper.chmod(0o755)
    version = subprocess.check_output([str(wrapper), 'version'], text=True)
    if version.strip() != 'gstrace 0.1.7':
        raise ValueError('published legacy reader version mismatch')
    return wrapper


if __name__ == '__main__':
    print(image())
