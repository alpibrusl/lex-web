# lex-web bench

A small TechEmpower-shaped benchmark so you can answer "**roughly
where are we vs FastAPI / Axum / Express / Phoenix**" without
having to build the full TFB harness.

## What it measures

Four endpoints, one binary, served from `bench/server.lex`:

| Endpoint | What dominates |
|---|---|
| `GET /plaintext`    | Framework dispatch + response write. Pure I/O ceiling. |
| `GET /json`         | + JSON encoding overhead (one-field object). |
| `GET /db`           | + single random `SELECT` via lex-orm `Repo[World]`. |
| `GET /queries?queries=20` | + 20 sequential `SELECT`s. Stresses connection reuse. |

Schema is the standard TFB `World` table (`id INT, randomNumber INT`),
seeded with 10,000 rows at startup. No middleware (logger / cors /
request-id) on the routes — those add real cost in production but
measuring them confuses framework-floor with operator-choice.

## Running

```bash
# Terminal 1 — boot the server
lex run --allow-effects io,net,time,sql,fs_write bench/server.lex main

# Terminal 2 — fire wrk at it
bench/run.sh
```

Override defaults with env vars:

```bash
THREADS=8 CONNECTIONS=512 DURATION=30s bench/run.sh
HOST=http://10.0.0.1:8080 bench/run.sh
```

Output is a one-row-per-endpoint table:

```
endpoint                          req/sec     mean lat        p50        p99
------------------------------------------------------------------------------
/plaintext                          XXXXX        X.XXms     X.XXms     X.XXms
/json                               XXXXX        X.XXms     X.XXms     X.XXms
/db (1 query)                       XXXXX        X.XXms     X.XXms     X.XXms
/queries (20 q/req)                 XXXXX        X.XXms     X.XXms     X.XXms
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
