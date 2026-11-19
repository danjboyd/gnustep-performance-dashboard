# Linux aarch64 headless runtime

The recording agent selects Linux x86_64 or aarch64 signal contexts at
compile time; other architectures fail compilation. On aarch64 it captures
PC, X29 (frame pointer), SP and all 31 general registers. Leak roots include
the thread pointer and glibc static TLS above it, rather than x86_64's TLS
below it. `GSP_AARCH64_PTHREAD_DESC_MAX` reserves 4096 bytes below TP for
that descriptor. This is a heuristic, not its ABI size; it may keep roughly
1.7 KiB of stale exited-thread stack scanned as roots. Static TLS estimates
also remain heuristic.

The frame-pointer fallback uses the AAPCS64 two-word record: previous frame
pointer followed by saved LR. As on x86_64, targets need frame pointers for
this fallback. The walker strips instruction PAC bits from frame records and the initial
return address with XPACLRI (HINT #7) on X30. This is signal-safe and becomes
a NOP on CPUs without PAC; it does not mask to an assumed VA width. The native
fixture tests a fake frame with a high PAC bit on CPUs advertising HWCAP_PACA,
and explicitly skips that instruction assertion otherwise. ARM/PAC execution
and targets omitting frame records remain unqualified locally.

Upstream libunwind 1.6.2 does **not** implement AArch64 RA_SIGN_STATE handling:
its DWARF parser recognizes opcode 0x2d only as SPARC GNU_window_save. No PAC
DWARF support is claimed for that version. Stripping returned IPs does not
supply missing unwind rules; PAC DWARF needs a separately verified libunwind
and native coverage. The frame-pointer fallback is independent of those rules.

Every libunwind IP is stripped before emission. On ARM, it must also fall in
the most recent normal-context executable PT_LOAD image snapshot. A mismatch
(or interrupted/overflowed snapshot publication) discards that unwind and
uses frame pointers for the sample. The fixed atomic snapshot has no reader
locks, allocation, loader calls or retry loop in signal context. It refreshes
at startup and each regular image scan; newly loaded code can conservatively
fall back until refreshed. Anonymous JIT mappings are not ELF image ranges.
This is a bounded stale snapshot, not proof that a concurrent unload cannot
occur. Invalid/unavailable image checks are counted and included in the
trace's final unwind diagnostic (visible in `gstrace info`).

libunwind is still loaded dynamically, with no new agent dependency. ARM
uses the local `_ULaarch64_` entry points and room for its 250-word public
cursor. The cursor IP selector is **30**, libunwind's `UNW_REG_IP` alias for
X30, whose accessor returns the current cursor IP. It is deliberately not
the saved-context `UNW_AARCH64_PC` slot (32). See the
[libunwind ARM ABI](https://github.com/libunwind/libunwind/blob/v1.6.2/include/libunwind-aarch64.h)
and [cursor accessor](https://github.com/libunwind/libunwind/blob/v1.6.2/src/mi/Gget_reg.c).
The [AAPCS64 frame record](https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst#the-frame-pointer)
defines the frame chain layout. The helper consumes kernel-provided
`PERF_SAMPLE_CALLCHAIN` addresses; it has no userspace register-number or
instruction decoder dependency. Privileged ARM attachment remains untested.

After sourcing a native GNUstep installation, build and run the headless
suite with:

```sh
make HEADLESS=1 CC=clang
python3 scripts/with-private-home.py /tmp/pd-arm-check-home -- make HEADLESS=1 CC=clang check
```

Use a fresh private-home directory for each local run. `HEADLESS=1` omits
the Dashboard app and sets `SKIP_GUI=1`; it retains framework/unit tests,
CLI recordings and headless image-decoding checks. Only the published
legacy reader invocation is skipped on ARM because that frozen fixture is
an x86_64 binary; native build-ID and reader checks still run. The existing
sampler re-entry fault-injection fixture is also x86_64-specific.

The `linux-arm64` CI job uses `ubuntu-24.04-arm`, builds the same GNUstep SDK
installer as x86_64 with a separate architecture cache key, then runs this
suite without AppImage packaging or a GUI session. Adding the job is not a
claim that it has run: native ARM execution requires a separately approved
push. ARM GUI, packaging and sustained production profiling are not qualified.
