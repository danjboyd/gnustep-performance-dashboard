# Arlen response headers: measured cost and observability path

Prepared locally for Dan's review; **not sent**. Target source is
`9cfdc5b2d1d58906c9acda3bddc5328c9780351d`; the unchanged API-reference
server executable has SHA256
`9e844bdf9fea1e13d318420d860150709997d8ef826a7879bd91c2b76f4f22c0`.
The initial inspection below used unchanged source. A later isolated local
prototype is recorded at the end; it has not been sent or signed off.

The repeatable local workload issues 900 successful sequential requests,
equally split among `/healthz`, `/api/reference/status` and `/openapi.json`,
on an ephemeral loopback-only listener in a private home. Its CPU-only trace
attributes 234 ms (20.6%) to `ALNSendResponse`, including **135 ms (11.9%)**
under `-[ALNResponse serializedHeaderData]`, with 127 ms charged to that
frame itself. Sample attribution is not an exact method-duration measurement.
The combined CPU/allocations/leaks repeat is separate evidence, not a basis
for a speedup estimate. Both traces finish cleanly with zero drops.

A further unchanged-server inspection returned HTTP 200 for all three paths.
Each response had **19 headers**, including security policy, trace/request
identifiers and `X-Arlen-Response-Write-Ms`. In `ALNResponse.m`, the shared
serialized-header cache accepts only three or four specific simple fields
(Server, Content-Type, Content-Length, optionally Connection), with no extra
values. These observed responses therefore use the generic ordered
NSMutableString/UTF-8 path. There is already a per-response serialized-data
cache. Another generic whole-response cache would not address changing
request identifiers and timing values safely.

There is also a concrete second pass. `ALNSendResponse` serializes headers,
measures that pass, then, when performance logging is enabled, updates the
response-write and total timing headers and serializes again. The setters
invalidate the per-response cache. A debugger counter on the unmodified
method recorded **six entries for the three successful responses**. This is
a call-count check, not a timing benchmark. The first counter attempt hit a
debugger shutdown error and is retained; the successful repeat detached the
debugger before stopping the sample server.

This means the hot path includes the sample's observability contract. Before
choosing a fix, compare identical workloads with performance logging enabled
and disabled, preserving the actual headers and externally measured request
latencies. That comparison has not been run. Eliminating the second pass
would require a deliberate timing-header contract: moving the metric to logs
or changing what the number estimates must not happen silently. No 50% cost
reduction, production bottleneck or response correctness defect is claimed.

A separate hypothesis is direct byte assembly for the generic path, which
would still retain the existing validated header APIs and caches. Any
prototype needs exact byte comparisons for ordinary and repeated headers,
ordering/display case, UTF-8 byte lengths, empty bodies, 304/file responses,
and cache invalidation after every supported mutation. Preserve injection
validation and singleton/repeated-field rules. Repeat the actual sample
workload and retain output/call-count evidence before proposing a patch.

Evidence: the original `out/linux-development-20261029/arlen-profile/`
CPU-only/combined call trees; this v0.1.4 worktree's
`out/arlen-header-inspection/headers.json` and
`out/arlen-header-count-2/{count.gdb,debugger.log,result.json}`.
No server was exposed beyond loopback and no owners were contacted.

Investigated, reproduced and written up with AI assistance (Codex, OpenAI).
Dan must review the exact material under `docs/upstream-policy.md` before any
submission. This draft authorizes no send.

## Isolated prototype and matched 900-request pair

The local prototype commit is
`64c2ec6ab4d32b9cac3acfef969615955ef46c9e`, based on
`9cfdc5b2d1d58906c9acda3bddc5328c9780351d`. Its executable SHA-256 is
`6af117b8c7aeb83614739f88702ec468a9538a70db62335d6aca11eafe013ec6`.
Only the owned profiling clone changed. The generic serializer appends UTF-8
bytes directly to mutable data, preserving status lines, field order, repeated
fields, Unicode lengths, empty values and the existing cache/invalidation path.
It leaves the performance-header double serialization unchanged. New golden
wire tests cover Unicode, empty and repeated fields and mutation after caching.
All 26 ResponseTests and the HeaderLookupContractTests case passed using the
repository's exact vendored XCTest revision
`a84f053e8546bb3e03bb470e2a0a17863ecabd62`.

Both fresh CPU-only captures used the unchanged ea576ea recorder, identical
900-request/three-endpoint workload and 40-second recording limit in separate
private homes. Every request returned HTTP 200, both captures finished cleanly
and neither dropped samples. These are one sequential pair on a loaded host,
not a statistically controlled speedup result.

| Measurement | Baseline | Prototype |
| --- | ---: | ---: |
| Total sampled CPU | 830 ms | 917 ms |
| `ALNSendResponse` inclusive | 169 ms | 208 ms |
| `serializedHeaderData` inclusive | 117 ms | 115 ms |
| `serializedHeaderData` self | 115 ms | 100 ms |
| RSS after 900 requests | 34,340 KiB | 34,280 KiB |

This pair **does not establish an overall performance improvement**. The small
inclusive serializer difference and lower sampled self cost coexist with
higher total CPU and higher response-send cost. The prototype remains a
prepared experiment; it should not be proposed as a proven optimization.
Repeat controlled measurements or investigate the separate double-pass path
before making an upstream performance claim. Local receipts, raw traces and
application call trees are retained under `arlen-profile-goal22/`; no issue,
patch or message has gone to the owners.
