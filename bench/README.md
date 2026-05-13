# lex-web bench

A small TechEmpower-shaped benchmark so you can answer "**roughly
where are we vs FastAPI / Axum / Express / Phoenix**" without
having to build the full TFB harness.

## First measurement (May 2026)

Ran `bench/floor.lex` (no router, no middleware, no DB — just
`net.serve_fn` dispatching by `req.path`) on a 4-core / 15 GB VM
with the load generator and the server sharing the same machine.
Numbers are constrained — same-box load is real interference —
but they're a starting point.

| Endpoint     | Req/sec | Avg lat | p50    | p99    |
|--------------|---------|---------|--------|--------|
| `/plaintext` | 7,703   | 28.30ms | 28.19ms | 34.69ms |
| `/json`      | 7,544   | 33.38ms | 33.27ms | 41.00ms |

`wrk -t4 -c256 -d15s` after a 5-second warmup; lex 0.9.1, release
build of the lex CLI.

**Read:** dispatch is the bottleneck (p50 ~28ms; real frameworks
land sub-ms on this class of hardware), the distribution is tight
(p99 / p50 ≈ 1.2× — no GC pauses, no lock contention), and JSON
encoding is essentially free (`/json` only 2% slower than
`/plaintext`). For scale, see "Interpreting" below.

## What it measures

Four endpoints planned, one binary, served from `bench/server.lex`.
Only the no-DB pair (`bench/floor.lex`) compiles cleanly today —
the DB-backed bench is blocked on lex-schema / lex-orm / lex-web
type drift between the global `Request`/`Response` and the
package-local records.

| Endpoint | What dominates |
|---|---|
| `GET /plaintext`    | Framework dispatch + response write. Pure I/O ceiling. |
| `GET /json`         | + JSON encoding overhead (one-field object). |
| `GET /db`           | + single random `SELECT` via lex-orm `Repo[World]`. *blocked* |
| `GET /queries?queries=20` | + 20 sequential `SELECT`s. *blocked* |

Schema (for the DB scenarios) is the standard TFB `World` table
(`id INT, randomNumber INT`), seeded with 10,000 rows at startup.
No middleware (logger / cors / request-id) on the routes —
those add real cost in production but measuring them confuses
framework-floor with operator-choice.

## Running

```bash
# Floor bench (works today)
lex run --allow-effects io,net bench/floor.lex main &
wrk -t4 -c256 -d15s http://localhost:8080/plaintext
wrk -t4 -c256 -d15s http://localhost:8080/json
kill %1

# Or use the runner:
bench/run.sh
```

Override defaults with env vars:

```bash
THREADS=8 CONNECTIONS=512 DURATION=30s bench/run.sh
HOST=http://10.0.0.1:8080 bench/run.sh
```

## Interpreting the numbers

Compare to the [public TechEmpower
leaderboard](https://www.techempower.com/benchmarks/). For a rough scale:

| Framework (TFB Round 22, plaintext, mid-tier) | req/sec |
|---|---|
| Drogon, Actix, Vert.x (top of bare-metal)     | 6-8M |
| Axum                                          | ~1.5M |
| Go (stdlib net/http)                          | ~700k |
| Phoenix                                       | ~400k |
| Spring                                        | ~300k |
| Express (Node)                                | ~150k |
| FastAPI (uvicorn)                             | ~120k |
| Flask                                         | ~25k  |
| Django                                        | ~12k  |
| **lex-web (this VM, plaintext)**              | **~7.7k** |

Caveats that make your local numbers *not directly comparable*:

1. **TFB hardware.** Public numbers are bare-metal i7-12700K / 32GB.
   Your laptop is probably slower per core and has fewer cores.
   Multiply local numbers by ~1.5-3x for a fair "if I were on TFB
   hardware" estimate.
2. **HTTP pipelining.** TFB's `/plaintext` test pipelines 16
   requests per connection. lex-web doesn't yet (`std.net`
   limitation). Expect plaintext numbers ~5-10x lower than the
   public figures for any framework that pipelines.
3. **SQLite vs Postgres.** When the DB-backed scenarios un-block,
   they default to in-memory SQLite. TFB uses Postgres. SQLite
   single-thread saturates earlier.
4. **Bytecode VM, no JIT.** Lex compiles to bytecode → VM. The
   plaintext number tells you roughly what the VM dispatch cost
   is; everything else stacks on top. The 28ms p50 for hello-world
   is the smoking gun: VM dispatch dominates.
5. **Load gen co-located.** Real TFB runs the load generator on a
   second box wired with 10 GbE. Our first run had wrk sharing
   the same 4 cores as the server — split the load.

Use these numbers for **relative comparison** (is `/db` 10x slower
than `/plaintext`? then DB-driver overhead dominates, lex-orm
optimisations have headroom). Don't quote them in a release blog
post until we run on TFB hardware with the same Postgres setup
they use.

## What this bench *isn't*

- Not a TFB submission. The public leaderboard requires a Docker
  harness, the full six scenarios, peer-reviewed PRs to the TFB
  repo. We'd file that once we have crypto + streaming +
  pipelining; right now it would only highlight gaps.
- Not a regression suite. wrk's variance per run is ±5% on
  most hardware; use this for "is the order-of-magnitude what we
  expect" not "did my last commit regress p99 by 8%".
- Not real-world. Most real lex-web apps will spend the time in
  business logic, lex-schema validation, and lex-orm query plans —
  not in the framework's dispatch loop. The bench tells you
  the **floor** the framework imposes, not the typical app's
  bottleneck.

## Future scenarios

The full TFB matrix has two more we'd want before claiming parity:

- **`/updates?queries=N`** — N reads + N writes. Stresses
  Postgres write path, transaction overhead, connection pooling.
- **`/fortunes`** — DB query + HTML template rendering with XSS
  escaping. Stresses lex-schema's HTML escape primitives and
  whatever templating we end up shipping.

Adding them is mechanical (`bench/server.lex` already has the
`World` repo and the random-id helper). The reason they're not
in v1 is the same reason we're not on the public leaderboard: we
need `std.crypto` (lex-lang#382) and HTTP streaming
(lex-lang#375) before the comparisons are honest end-to-end.

## Interpreting the numbers

Compare to the [public TechEmpower
leaderboard](https://www.techempower.com/benchmarks/). For a rough scale:

| Framework (TFB Round 22, plaintext, mid-tier) | req/sec |
|---|---|
| Drogon, Actix, Vert.x (top of bare-metal)     | 6-8M |
| Axum                                          | ~1.5M |
| Go (stdlib net/http)                          | ~700k |
| Phoenix                                       | ~400k |
| Spring                                        | ~300k |
| Express (Node)                                | ~150k |
| FastAPI (uvicorn)                             | ~120k |
| Flask                                         | ~25k  |
| Django                                        | ~12k  |

Caveats that make your local numbers *not directly comparable*:

1. **TFB hardware.** Public numbers are bare-metal i7-12700K / 32GB.
   Your laptop is probably slower per core and has fewer cores.
   Multiply local numbers by ~1.5-3x for a fair "if I were on TFB
   hardware" estimate.
2. **HTTP pipelining.** TFB's `/plaintext` test pipelines 16
   requests per connection. lex-web doesn't yet (`std.net`
   limitation). Expect plaintext numbers ~5-10x lower than the
   public figures for any framework that pipelines.
3. **SQLite vs Postgres.** Our bench runs against in-memory
   SQLite. TFB uses Postgres. SQLite single-thread saturates
   earlier; Postgres scales further with connection pools.
   Swap `conn.connect_sqlite(":memory:")` for
   `conn.open("postgres://…")` in `server.lex` for a fairer
   ORM/DB-driver comparison.
4. **No JIT / no async.** Lex compiles to bytecode → VM. The
   plaintext number tells you roughly what the VM dispatch cost
   is; everything else stacks on top.

Use these numbers for **relative comparison** (is `/db` 10x slower
than `/plaintext`? then DB-driver overhead dominates, lex-orm
optimisations have headroom). Don't quote them in a release blog
post until we run on TFB hardware with the same Postgres setup
they use.

## What this bench *isn't*

- Not a TFB submission. The public leaderboard requires a Docker
  harness, the full six scenarios, peer-reviewed PRs to the TFB
  repo. We'd file that once we have crypto + streaming +
  pipelining; right now it would only highlight gaps.
- Not a regression suite. wrk's variance per run is ±5% on
  most hardware; use this for "is the order-of-magnitude what we
  expect" not "did my last commit regress p99 by 8%".
- Not real-world. Most real lex-web apps will spend the time in
  business logic, lex-schema validation, and lex-orm query plans —
  not in the framework's dispatch loop. The bench tells you
  the **floor** the framework imposes, not the typical app's
  bottleneck.

## Future scenarios

The full TFB matrix has two more we'd want before claiming parity:

- **`/updates?queries=N`** — N reads + N writes. Stresses
  Postgres write path, transaction overhead, connection pooling.
- **`/fortunes`** — DB query + HTML template rendering with XSS
  escaping. Stresses lex-schema's HTML escape primitives and
  whatever templating we end up shipping.

Adding them is mechanical (`bench/server.lex` already has the
`World` repo and the random-id helper). The reason they're not
in v1 is the same reason we're not on the public leaderboard: we
need `std.crypto` (lex-lang#382) and HTTP streaming
(lex-lang#375) before the comparisons are honest end-to-end.
