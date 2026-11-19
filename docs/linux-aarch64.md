# Linux aarch64 headless runtime

The recording agent selects Linux x86_64 or aarch64 signal contexts at
compile time; other architectures fail compilation. On aarch64 it captures
PC, X29 (frame pointer), SP and all 31 general registers. Leak roots include
the thread pointer and glibc static TLS above it, rather than x86_64's TLS
below it. The existing conservative TLS-range estimates remain heuristic.

The frame-pointer fallback uses the AAPCS64 two-word record: previous frame
pointer followed by saved LR. As on x86_64, targets need frame pointers for
this fallback. Pointer-authenticated return addresses and targets omitting
frame records have not been qualified by this change.

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
