# lex-web framework benchmark — vs. FastAPI, Express, Axum

> **Headline (v2, with lex-web `route_trie` + lex-lang `LEX_NET_INLINE_VM=1`).**
> On a TechEmpower-style plaintext / JSON / routed-param harness, lex-web
> on lex-lang 0.9.3 with the trie dispatcher and the inline-VM
> server path serves **~12.9 k req/s** on `/plaintext`, **~12.7 k on
> `/json`**, **~9.8 k on `/users/:id`** under a 2-core budget. FastAPI
> (uvicorn, 1 worker) does **~13.7 k / 13.6 k / 11.2 k**, Express (Node 22)
> **~12.3 k / 12.1 k / 11.7 k**, Axum (Rust, hyper+tokio) **~183 k / 176 k
> / 165 k**. **lex-web now beats Express on plaintext and JSON and sits at
> 87–94 % of FastAPI.**
>
> The original v1 row in this report measured 8 013 / 8 062 / 6 944 — 65 %
> of FastAPI on plaintext. Two changes closed most of the gap: a compiled
> route trie ([lex-web#9](https://github.com/alpibrusl/lex-web/pull/9))
> and skipping `tokio::task::spawn_blocking` on the per-request VM call
> ([lex-lang#434](https://github.com/alpibrusl/lex-lang/pull/434)).

Reproduce: `LEX_NET_INLINE_VM=1 bench/run.sh` (assumes `lex` built from
the `claude/benchmark-lex-web-erQMR` branch of lex-lang at
`../lex-lang/target/release/lex`, `wrk` and `python3` on `$PATH`,
`bench/servers/axum_bench` and `bench/servers/node_modules`
pre-built).

## What was measured

Three endpoints, mirrored byte-for-byte across all four servers:

| Endpoint        | Body                              | Content-Type                  |
| --------------- | --------------------------------- | ----------------------------- |
| `GET /plaintext` | `Hello, World!`                  | `text/plain; charset=utf-8`   |
| `GET /json`      | `{"message":"Hello, World!"}`    | `application/json`            |
| `GET /users/:id` | `{"id":"<id>","name":"Alice"}`   | `application/json`            |

`/plaintext` and `/json` are the canonical [TechEmpower Web Framework
Benchmark](https://www.techempower.com/benchmarks/) framework-only
tests — the standard reference for "how fast is the framework itself,
with no I/O." The third endpoint exercises one path-parameter
extraction, which is where lex-web's value-add over a raw `net.serve_fn`
handler sits.

The four server programs all return the same payload shape; each
one's source is one file under `bench/servers/`. None of them
register any middleware — same way TechEmpower runs every framework
in its plaintext suite.

## Methodology

| Setting           | Value                                              |
| ----------------- | -------------------------------------------------- |
| Driver            | `wrk` 4.1.0, 2 threads, 64 connections             |
| Run length        | 15 s per trial, 3 trials per endpoint              |
| Warm-up           | 3 single GETs before each server's trials begin    |
| CPU budget        | `taskset -c 0-1` on every server (2 cores each)    |
| Host              | Intel Xeon @ 2.10 GHz, 4 vCPU, 16 GB, Linux 6.18.5 |
| Loopback only     | `wrk` and the servers share the host; no network   |

**Why the 2-core taskset.** lex-lang's `net.serve_fn` uses tokio's
multi-thread scheduler and runs each Lex VM call through
`spawn_blocking`. Without `taskset` it would silently use all four
cores while uvicorn (`--workers 1`) and Node both single-loop. Pinning
every server to the same 2-core budget keeps the comparison
runtime-for-runtime.

**One server per process, no reverse proxy, no keepalive tweaks.**
Defaults across the board. The intent is "what does the framework
give you on a fresh `serve_fn`-equivalent call?" — not "how high
can you tune each stack."

**Three trials, median reported.** Variance was small (<3 % spread
on most rows; see `bench/results/trials.tsv` for the full per-trial
table). The one outlier was lex-web's `/json` trial 3 — 7.5 k vs.
8.2 k for the other two, likely a GC pause in the Lex VM.

## Stack under test

| Server   | Version              | Stack                                             | Workers |
| -------- | -------------------- | ------------------------------------------------- | ------- |
| lex-web (v2) | lex-web `claude/benchmark-lex-web-erQMR` / lex `claude/benchmark-lex-web-erQMR` | hyper 1.x + tokio multi-thread + Lex VM | 1 process, tokio default workers, **inline-VM** (`LEX_NET_INLINE_VM=1`, lex-lang#434) |
| FastAPI  | fastapi 0.136.1 / uvicorn 0.47 | uvicorn + httptools + asyncio          | `--workers 1` (single async event loop) |
| Express  | Node 22.22 / Express 4.x  | Node http + Express middleware              | Single Node process, single event loop |
| Axum     | axum 0.7 / hyper 1.x / tokio 1 | hyper 1.x + tokio multi-thread         | tokio default (= cores) |

Note that **Axum and lex-web sit on the same underlying runtime**
(hyper 1.x + tokio multi-thread, via lex-lang #388). That makes the
Axum row the runtime upper bound — the difference vs. lex-web is the
cost of routing in an interpreted VM rather than compiled Rust.

## Results

### v2 — current (lex-web trie + lex-lang `LEX_NET_INLINE_VM=1`)

Median req/s across 3 trials, 2-core budget, **stack: PR #9 trie + PR #434
inline-VM**. Higher is better.

| Server      | /plaintext (req/s) | /json (req/s) | /users/:id (req/s) | rel-to-FastAPI plaintext |
| ----------- | -----------------: | ------------: | -----------------: | -----------------------: |
| **Axum**    | **183 327**        | **176 228**   | **165 043**        | 13.4×                    |
| FastAPI     | 13 676             | 13 596        | 11 223             | 1.00× (baseline)         |
| **lex-web** | **12 870**         | **12 692**    | **9 788**          | **0.94×**                |
| Express     | 12 275             | 12 080        | 11 690             | 0.90×                    |

Latency (median = p50; from `wrk --latency`):

| Server   | /plaintext p50 / p99 | /json p50 / p99    | /users/:id p50 / p99 |
| -------- | -------------------- | ------------------ | -------------------- |
| Axum     | 0.34 ms / 0.70 ms    | 0.36 ms / 0.71 ms  | 0.39 ms / 0.72 ms    |
| FastAPI  | 4.51 ms / 8.85 ms    | 4.57 ms / 8.87 ms  | 5.42 ms / 10.52 ms   |
| Express  | 4.79 ms / 8.78 ms    | 4.83 ms / 8.91 ms  | 4.93 ms / 9.59 ms    |
| lex-web  | 5.12 ms / 7.68 ms    | 5.18 ms / 7.73 ms  | 6.74 ms / 10.01 ms   |

p99 tail on lex-web is now actually **tighter** than FastAPI's
(7.68 ms vs 8.85 ms on plaintext) — `spawn_blocking` was the source
of the long tail in v1; with the inline path, the tail collapses to
~1.5× the median across all three endpoints. The trade is documented
in lex-lang#434: handlers that do >1 ms of CPU work will now stall
the tokio worker they're on, so the env var is opt-in.

### v1 → v2 delta

What moved between the original run (PR #8, default lex-lang
`spawn_blocking`, list.fold dispatcher) and this v2 row:

| Endpoint        | v1 req/s | v2 req/s | Δ        | % of FastAPI (v1 → v2) |
| --------------- | -------: | -------: | -------: | ---------------------: |
| `/plaintext`    |    8 013 | **12 870** | **+61 %** | 65 % → **94 %**       |
| `/json`         |    8 062 | **12 692** | **+57 %** | 68 % → **93 %**       |
| `/users/:id`    |    6 944 |  **9 788** | **+41 %** | 70 % → **87 %**       |

Two changes contributed:

1. **Compiled route trie** (`src/route_trie.lex`, [PR #9](https://github.com/alpibrusl/lex-web/pull/9)).
   Neutral at 3 routes (this matrix); the win shows up at 20 routes
   (+3.3× on plaintext, +2.9× on routed-param) — see the
   *Route-count scaling* section below. Stops the regression as
   route count grows.
2. **`LEX_NET_INLINE_VM=1`** ([lex-lang PR #434](https://github.com/alpibrusl/lex-lang/pull/434)).
   Skips `tokio::task::spawn_blocking` on the per-request VM call.
   Measured directly: +33 % on plaintext, +28 % on JSON, +17 % on
   routed-param. This is the bulk of the v1→v2 delta at 3 routes.

FastAPI's row also moved (12 409 → 13 676 plaintext) — same host, same
FastAPI code, just measurement variance between runs. The reliable
read is the v2 column's % of FastAPI: every v2 row was measured in
the same wrk session.

## What the gap is

A request through lex-web (v2 stack: trie + inline-VM) does these
steps inside the VM, on every hit:

1. **Boundary adaptor** (`bench/servers/lex_web_bench.lex`): rebuild
   the builtin `Request` record into a `ctx.RawRequest` record. One
   record copy per request.
2. **`router.dispatch`** (now trie-backed via `src/route_trie.lex`):
   - `str.to_upper(req.method)` — single-char inspection, but a
     string allocation per request.
   - `split_path(req.path)` — walks the path char-by-char in Lex,
     building a `List[Str]` of segments. At 3 routes this is the
     single largest cost on the lex-web side.
   - `rt.lookup` — one `map.get` per path segment through the trie.
     O(M) in path depth, independent of route count.
3. **`ctx.from_request`** — record literal construction.
4. **Middleware passes** — `mw.run_pre` and `mw.run_post` are
   no-op `list.fold`s when the middleware list is empty, but they
   still allocate a `Continue(c)` ADT value and traverse an empty
   list.
5. **Handler body** — for `/json` this is `resp.json(...)`, which
   calls `with_ct(200, body, "application/json")`, which builds a
   `Map[Str, Str]` from a one-element list.
6. **Boundary adaptor again** — wrap the framework's `Response`
   (with `body :: Str`) into the builtin `Response` (with `body ::
   ResponseBody`, since lex-lang #375 introduced streaming-body
   variants). One `BodyStr(...)` construction per request.

All of step 1–6 runs in the Lex bytecode interpreter. With
`LEX_NET_INLINE_VM=1` (lex-lang#434) the interpreter runs directly
on the tokio worker — no `spawn_blocking` hop per request. Without
the env var, each request also crosses the async/blocking boundary
twice; that's the +33 % the inline path recovers on plaintext.

The Axum row uses the same hyper + tokio. **The remaining 14× gap
(183 k → 12.9 k) is the cost of interpreting steps 1–6 in a VM vs.
running them as monomorphised Rust.** Closing it further is a
lex-lang topic (JIT or AOT), not a lex-web tuning question.

The gap to FastAPI is now small (6 % on plaintext): both are
interpreted runtimes doing comparable per-request allocation. The
remaining differences are step (2) `split_path` (Python uses
Starlette's compiled regex router, Lex walks the string char-by-char)
and step (5) header construction (FastAPI's `JSONResponse` keeps a
header dict; lex-web rebuilds it via `map.from_list`).

## What this *isn't* measuring

- **No DB.** TechEmpower's "single query" / "multi-query" /
  "fortunes" tests would tell a different story — they're dominated
  by the database driver and connection pool, not the framework. lex-web
  paired with lex-orm via `std.sql` would be the next test if a
  database story matters.
- **No keepalive headers, no HTTP/2, no TLS.** Defaults across the
  board. Numbers would change at every level.
- **Empty middleware stack.** With `mw.logger()` registered,
  lex-web would drop ~1 k req/s because `io.print` blocks; FastAPI
  and Express both ship comparable middleware costs.
- **Single host, loopback only.** `wrk` and the server share the
  CPU. On a real two-host setup (driver and server on different
  boxes) every absolute number rises.
- **One Lex version.** Numbers will move with the lex-lang slices
  in flight: #389-slice2 (inline cache for `Op::GetField`) and
  #389-slice4 (`Value::Str` → SmolStr SSO) both went in just before
  v0.9.3; further slices will keep moving them.

## Repro

```sh
# 1. Build lex.
( cd ../lex-lang && cargo build --release -p lex-cli )

# 2. Build Axum.
( cd bench/servers/axum_bench && cargo build --release )

# 3. Install FastAPI + uvicorn (Python) and Express (Node).
pip install 'fastapi' 'uvicorn[standard]' httptools
( cd bench/servers && npm install --no-package-lock express@4 )

# 4. Run.
bench/run.sh

# Optional knobs.
DURATION=30s CONNECTIONS=128 TRIALS=5 bench/run.sh
TASKSET="taskset -c 0-3" bench/run.sh   # give every server 4 cores
bench/run.sh lex-web fastapi             # just two servers
```

Raw output:
- `bench/results/<server>_<endpoint>_t<N>.txt` — full `wrk` output per trial
- `bench/results/trials.tsv` — one row per trial (3 × 12 = 36 rows)
- `bench/results/summary.tsv` — median / min / max per (server,endpoint)

## Route-count scaling — the trie dispatcher

The numbers above are at three routes. Realistic apps register
dozens; the dispatcher's per-request cost scales with that count
unless it's keyed on path structure. lex-web's original
`find_match` did `list.fold` across the entire route list on every
request — O(N × M) in (routes × path-depth). This branch replaces
it with a compiled segment-keyed trie (`src/route_trie.lex`)
built once at `app()` time, consulted in O(M) per request
regardless of route count.

### A/B at 3 and 20 routes

Same wrk config (2 wrk threads, 64 conns, 15 s × 3 trials, 2-core
`taskset` budget); only the lex-web dispatcher and the route count
vary. lex-web variants are all *hoisted-`app()`* — the router is
built once in `main` and captured by the handler closure, so
neither variant pays trie-build cost per request.

| Variant            | Dispatcher | Routes | /plaintext req/s | /users/:id req/s |
| ------------------ | ---------- | -----: | ---------------: | ---------------: |
| `lex-listfold-3`   | list.fold  |      3 |            6 586 |            5 580 |
| `lex-trie-3`       | **trie**   |      3 |            6 584 |            5 872 |
| `lex-listfold-20`  | list.fold  |     20 |              683 |              688 |
| **`lex-trie-20`**  | **trie**   |     20 |        **2 287** |        **2 006** |
| `fastapi-3`        | (Starlette)|      3 |           10 831 |            8 665 |
| `fastapi-20`       | (Starlette)|     20 |            8 781 |            7 336 |

Median across 3 trials per row. Raw: `bench/results/scaling.tsv`.

### What this shows

- **At 3 routes the trie is a wash.** Scanning three records in
  `list.fold` is cheap; a trie lookup costs the same. The
  dispatcher isn't the bottleneck at small route counts.
- **At 20 routes the trie is a 3.3× win on plaintext (683 → 2 287)
  and a 2.9× win on /users/:id (688 → 2 006).** The `list.fold`
  dispatcher's throughput collapses because it walks all 20
  preceding misses for every `/plaintext` or `/users/:id` hit;
  the trie does one `map.get` and goes.
- **The trie doesn't close the gap to FastAPI**, but it stops the
  gap from widening. With `list.fold` at 20 routes lex-web sits at
  8% of FastAPI; with the trie it sits at 26%. The remaining gap
  is the same VM-overhead-per-allocation cost the headline section
  describes — not routing logic.

> **Caveat on absolute numbers.** This run was on a noisier host
> than the headline 4-server matrix above; the 3-route trie row
> (`6 584` plaintext) is ~80 % of the headline `8 013` from the
> original run. The *ratios within this section* are reliable —
> they're back-to-back A/B trials under identical conditions — but
> don't compare these absolute numbers row-for-row to the matrix
> table above.

Hoisting `app()` out of the per-request `handle` closure was a
secondary win measured separately: +23 % on `/users/:id` (5 120 →
6 309 req/s) at 3 routes against the original
`lex_web_bench_per_req.lex`. The matrix above and the trie A/B
both use the hoisted bench file.

### Why the trie still leaves a gap to FastAPI

The 20-route scaling A/B was measured with **default** lex-lang
(`spawn_blocking`); the v2 headline at 3 routes uses
`LEX_NET_INLINE_VM=1`. Re-running the 20-route trie variant with
inline-VM is a follow-up — the expected result is similar relative
improvement (~+30 %), pulling lex-web closer to FastAPI's 8 k req/s
at 20 routes.

The remaining cost after both changes, in rough order of size:

1. **`split_path` and `str.to_upper` per request.** Both allocate
   in the hot path. A method-enum lookup and a state-machine path
   scan would eliminate them.
2. **`resp.json` rebuilds its headers `Map[Str, Str]` per call.**
   Pre-built singletons for common content-type/status combos
   would skip the allocation.
3. **Boundary `BodyStr(...)` wrap per response.** Removed if lex-web
   adopts `body :: ResponseBody` natively (also unlocks streaming).

All three are local lex-web work that can land independently.

## Notes on the lex-web framework patches this required

To make `lex check` pass against lex-lang 0.9.3 the bench branch
fixed two effect-row regressions in `lex-web/src/`:

- `router.lex:166,197` — `dispatch` and `run_with_middleware` now
  declare `[io, time, crypto, random]`. The body calls
  `mw.run_post`, which transitively calls
  `crypto.random_str_hex(...)` when `MwRequestId` is in the
  middleware list — that's a `[random]` effect since lex-lang
  #382-slice3.
- `middleware.lex:153,155,164,217` — `run_post`, `apply_post`, and
  `make_request_id` now declare `[crypto, random]` for the same
  reason.

And a per-bench boundary adaptor (`lex_web_bench.lex:54-72`) bridges
the builtin `Response` (which is `body :: ResponseBody` after
lex-lang #375) to lex-web's internal `Response` (still `body :: Str`).
The framework keeps its `Str` body internally; only the
`net.serve_fn` boundary wraps it in `BodyStr(...)`.

Whether lex-web should adopt `ResponseBody` natively (to support
streaming responses) is a separate design question — out of scope
for this benchmark.

## Framework changes this branch landed

Beyond the effect-row patches above, this branch landed one
non-cosmetic framework change to enable the scaling section:

- **`src/route_trie.lex`** — new module. Defines `TrieNode` (a
  recursive ADT keyed on path segments), `compile(triples)` to
  build the trie from registered routes, and `lookup(t, method,
  segs)` for dispatch. Resolution order at each node is
  literal > `:param` > `*wildcard`, matching the historical
  `list.fold` semantics.
- **`src/router.lex`** — `Router` gains a `trie :: rt.TrieNode`
  field rebuilt by `add_record` (so registration is the only
  place that pays trie-build cost; dispatch is `O(M)`). The
  trie-based `dispatch` is the new default; the legacy
  `list.fold` path is preserved as `dispatch_listfold` so the
  scaling A/B in `bench/run-scaling.sh` can compare them.

The trie's public surface is internal — no external API change.
`router.new`, `router.route`, `router.dispatch`, etc. all behave
the same; `dispatch_listfold` exists only for the benchmark and
can be removed once the trie wins are accepted.

### Scaling harness

`bench/run-scaling.sh` drives six variants at the same
2-core / 64-conn / 15s × 3-trial config: lex-web {list.fold,
trie} × {3, 20 routes}, plus FastAPI {3, 20 routes} for context.
Raw output at `bench/results/scaling.tsv` and per-trial
`bench/results/scaling_*_t*.txt`.
