#!/usr/bin/env python3
"""Stage a self-contained GNUstep runtime for the Performance Dashboard AppImage.

Called by scripts/package-stage.sh. Given a stage root that already holds
app/PerformanceDashboard.app and runtime/System (GNUstep resources, bundles, the
Adwaita theme) and runtime/bin (GNUstep tools), it:

  * walks the NEEDED closure of every ELF file under app/ and runtime/,
    copying each shared library into runtime/lib unless it is a host
    library (see HOST_LIBRARIES);
  * strips the staged ELF copies;
  * rewrites RUNPATHs that point outside the stage (build-machine paths) to
    $ORIGIN-relative paths;
  * writes metadata/licenses/host-libraries.txt listing every bundled
    distribution library with its Debian package, and copies those
    packages' copyright files next to it.

Usage: stage-linux-runtime.py <stage-root> <library-dir>...
The library dirs are searched before the host linker cache.
"""
import os
import re
import shutil
import struct
import subprocess
import sys

# Libraries the AppImage takes from the host instead of bundling: the C
# runtime, the display stack, and GTK 4 with everything it shares with the
# desktop (the Adwaita theme uses the host's GTK/GLib).
# Mixing a bundled copy of any of these with the host's is what breaks
# AppImages, so the walk stops at them.
HOST_LIBRARIES = re.compile(r"^(" + "|".join([
    r"ld-linux.*", r"libc\.so.*", r"libm\.so.*", r"libmvec\.so.*", r"libdl\.so.*",
    r"libpthread\.so.*", r"librt\.so.*", r"libresolv\.so.*", r"libutil\.so.*",
    r"libanl\.so.*", r"libnsl\.so.*", r"libcrypt\.so.*", r"libstdc\+\+\.so.*",
    r"libgcc_s\.so.*", r"libatomic\.so.*",
    r"libX.*", r"libxcb.*", r"libxkbcommon.*", r"libwayland-.*", r"libICE\.so.*",
    r"libSM\.so.*", r"libGL.*", r"libEGL.*", r"libOpenGL.*", r"libvulkan.*",
    r"libdrm.*", r"libgbm.*", r"libepoxy.*",
    r"libfontconfig.*", r"libfreetype.*", r"libharfbuzz.*", r"libfribidi.*",
    r"libpango.*", r"libcairo.*", r"libpixman.*", r"libgraphene.*",
    r"libgtk-.*", r"libgdk.*", r"libglib-2.*", r"libgobject-2.*", r"libgio-2.*",
    r"libgmodule-2.*", r"libgthread-2.*",
    r"libz\.so.*", r"libffi\.so.*", r"libpcre2-.*", r"libmount\.so.*",
    r"libblkid\.so.*", r"libselinux\.so.*", r"libexpat\.so.*", r"libbz2\.so.*",
    r"liblzma\.so.*", r"libzstd\.so.*", r"liblz4\.so.*", r"libdbus-1\.so.*",
    r"libsystemd\.so.*", r"libudev\.so.*", r"libcap\.so.*", r"libgcrypt\.so.*",
    r"libgpg-error\.so.*", r"libuuid\.so.*",
]) + r")$")

DT_NEEDED, DT_STRTAB, DT_RPATH, DT_RUNPATH = 1, 5, 15, 29


def is_elf(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(4) == b"\x7fELF"
    except OSError:
        return False


def elf_files(root):
    for directory, _, names in os.walk(root):
        for name in names:
            path = os.path.join(directory, name)
            if os.path.isfile(path) and not os.path.islink(path) and is_elf(path):
                yield path


class Elf:
    """Just enough of an ELF64 little-endian reader to edit DT_RUNPATH."""

    def __init__(self, path):
        with open(path, "rb") as handle:
            self.data = bytearray(handle.read())
        if self.data[4] != 2 or self.data[5] != 1:
            raise ValueError(f"{path}: only ELF64 little-endian is supported")
        phoff, = struct.unpack_from("<Q", self.data, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", self.data, 0x36)
        self.loads, self.dynamic = [], None
        for index in range(phnum):
            p_type, _, p_offset, p_vaddr, _, p_filesz = struct.unpack_from(
                "<IIQQQQ", self.data, phoff + index * phentsize)
            if p_type == 1:
                self.loads.append((p_vaddr, p_offset, p_filesz))
            elif p_type == 2:
                self.dynamic = (p_offset, p_filesz)

    def entries(self):
        if self.dynamic is None:
            return []
        offset, size = self.dynamic
        result = []
        for position in range(offset, offset + size, 16):
            tag, value = struct.unpack_from("<qQ", self.data, position)
            if tag == 0:
                break
            result.append((tag, value, position))
        return result

    def file_offset(self, vaddr):
        for start, offset, size in self.loads:
            if start <= vaddr < start + size:
                return offset + vaddr - start
        raise ValueError("address outside PT_LOAD segments")

    def runpath_slot(self):
        """(file offset, current string) of DT_RUNPATH/DT_RPATH, or None."""
        entries = self.entries()
        strtab = next((value for tag, value, _ in entries if tag == DT_STRTAB), None)
        for tag, value, _ in entries:
            if tag in (DT_RPATH, DT_RUNPATH) and strtab is not None:
                start = self.file_offset(strtab) + value
                end = self.data.index(0, start)
                return start, self.data[start:end].decode()
        return None


def set_runpath(path, new_runpath):
    """Overwrite the RUNPATH string in place; it may only get shorter."""
    elf = Elf(path)
    slot = elf.runpath_slot()
    if slot is None:
        return None
    start, old = slot
    encoded = new_runpath.encode()
    if len(encoded) > len(old):
        raise ValueError(f"{path}: new RUNPATH {new_runpath!r} is longer than {old!r}")
    elf.data[start:start + len(old)] = encoded + b"\0" * (len(old) - len(encoded))
    with open(path, "wb") as handle:
        handle.write(elf.data)
    return old


def needed(path):
    output = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    return re.findall(r"\(NEEDED\)\s+Shared library: \[(.+?)\]", output)


def host_linker_cache():
    output = subprocess.run(["/sbin/ldconfig", "-p"], capture_output=True, text=True).stdout
    cache = {}
    for line in output.splitlines():
        match = re.match(r"\s*(\S+) \(([^)]*)\) => (\S+)", line)
        if match and "x86-64" in match.group(2) and match.group(1) not in cache:
            cache[match.group(1)] = match.group(3)
    return cache


def debian_package(path):
    for candidate in (path, os.path.realpath(path)):
        result = subprocess.run(["dpkg", "-S", candidate], capture_output=True, text=True)
        if result.returncode == 0 and ":" in result.stdout:
            return result.stdout.split(":", 1)[0].strip()
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: stage-linux-runtime.py <stage-root> <library-dir>...")
    stage = os.path.abspath(sys.argv[1])
    library_dirs = [os.path.abspath(d) for d in sys.argv[2:]]
    runtime_lib = os.path.join(stage, "runtime", "lib")
    os.makedirs(runtime_lib, exist_ok=True)
    cache = host_linker_cache()

    def resolve(soname):
        for directory in library_dirs:
            candidate = os.path.join(directory, soname)
            if os.path.exists(candidate):
                return candidate, True
        return cache.get(soname), False

    roots = list(elf_files(os.path.join(stage, "app"))) + list(elf_files(os.path.join(stage, "runtime")))
    pending = list(roots)
    bundled, host, missing, distro = {}, set(), set(), {}
    while pending:
        for soname in needed(pending.pop()):
            if soname in bundled or soname in host or soname in missing:
                continue
            if HOST_LIBRARIES.match(soname):
                host.add(soname)
                continue
            source, from_toolchain = resolve(soname)
            if source is None:
                missing.add(soname)
                continue
            target = os.path.join(runtime_lib, soname)
            shutil.copyfile(os.path.realpath(source), target)
            os.chmod(target, 0o755)
            bundled[soname] = source
            if not from_toolchain:
                distro[soname] = source
            pending.append(target)

    if missing:
        sys.exit("stage-linux-runtime: unresolved libraries: " + ", ".join(sorted(missing)))

    for path in list(elf_files(os.path.join(stage, "app"))) + list(elf_files(os.path.join(stage, "runtime"))):
        subprocess.run(["strip", "--strip-unneeded", path], check=True)
        slot = Elf(path).runpath_slot()
        if slot is None or slot[1].startswith("$ORIGIN"):
            continue
        relative = os.path.relpath(runtime_lib, os.path.dirname(path))
        old = set_runpath(path, "$ORIGIN/" + relative)
        print(f"stage-linux-runtime: RUNPATH {os.path.relpath(path, stage)}: {old} -> $ORIGIN/{relative}")

    licenses = os.path.join(stage, "metadata", "licenses")
    copyrights = os.path.join(licenses, "host-libraries")
    os.makedirs(copyrights, exist_ok=True)
    lines = ["Distribution libraries bundled in runtime/lib, with the Debian package",
             "each came from. Their copyright files are in host-libraries/.", ""]
    for soname in sorted(distro):
        package = debian_package(distro[soname]) or "unknown"
        lines.append(f"{soname}\t{package}")
        base = package.split(":")[0]
        copyright_file = f"/usr/share/doc/{base}/copyright"
        if os.path.isfile(copyright_file):
            shutil.copyfile(copyright_file, os.path.join(copyrights, f"{base}.copyright"))
    with open(os.path.join(licenses, "host-libraries.txt"), "w") as handle:
        handle.write("\n".join(lines) + "\n")

    print(f"stage-linux-runtime: bundled {len(bundled)} libraries "
          f"({len(distro)} from the distribution); host-provided: {', '.join(sorted(host))}")


if __name__ == "__main__":
    main()
