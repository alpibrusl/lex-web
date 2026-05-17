# TechEmpower Framework Benchmarks — lex-web

Drop-in artifacts for submitting lex-web to the public TFB
[leaderboard](https://www.techempower.com/benchmarks/). The Dockerfile
builds a self-contained image with Postgres + lex 0.9.5 + lex-web; the
benchmark_config.json declares the five TFB test routes.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the runtime image. Pulls lex toolchain, vendors lex-web sources, installs Postgres, supervises both at boot. |
| `start.sh` | Boots Postgres, provisions the `hello_world` DB and `benchmarkdbuser` role, then exec's the bench server. Invoked by supervisord. |
| `supervisord.conf` | Process supervisor config. |
| `benchmark_config.json` | TFB framework descriptor — routes, ORM, language, etc. |

## Routes

Mapped to `bench/servers/lex_web_bench_db.lex`:

| TFB row | Path |
|---|---|
| plaintext | `/plaintext` |
| json | `/json` |
| single-query (db) | `/db` |
| multiple-queries | `/queries?queries=N` |
| updates | `/updates?queries=N` |

The `/fortunes` row isn't shipped yet — it needs an HTML-template
helper on top of `lex-schema/html.escape` (which landed in
lex-schema 0.9.3+). Tracked in lex-web Issue #3.

## Local smoke test

```sh
docker build -f bench/tfb/Dockerfile -t lex-web:tfb .
docker run --rm -p 8080:8080 lex-web:tfb &
# wait a few seconds for postgres + seed to settle
curl http://localhost:8080/plaintext
curl http://localhost:8080/json
curl http://localhost:8080/db
curl 'http://localhost:8080/queries?queries=20'
curl 'http://localhost:8080/updates?queries=20'
```

## Submitting to TFB upstream

1. Fork `TechEmpower/FrameworkBenchmarks`.
2. Create `frameworks/Lex/lex-web/` and copy:
   - `bench/tfb/Dockerfile` → `Dockerfile`
   - `bench/tfb/start.sh` → `start.sh`
   - `bench/tfb/supervisord.conf` → `supervisord.conf`
   - `bench/tfb/benchmark_config.json` → `benchmark_config.json`
   - lex-web sources, see "Path normalization" below.
3. Adjust `COPY` paths inside the Dockerfile to match wherever TFB
   places lex-web's sources in their tree.
4. Open a framework-PR against TFB. Wait for the next round.

### Path normalization

The current Dockerfile expects to be built from the *root of lex-web*
(it does `COPY lex.toml ./lex.toml`, `COPY src/`, etc.). When you
slot it into TFB's tree, either:

- vendor lex-web at `frameworks/Lex/lex-web/lex-web/` and rebase the
  `COPY` lines onto that subdir, or
- pull lex-web at image-build time via `git clone --depth=1` to keep
  the framework directory thin (TFB's preferred shape for fast-moving
  frameworks).

The git-clone approach is mechanically:

```dockerfile
RUN git clone --depth=1 --branch v0.3.0 https://github.com/alpibrusl/lex-web /opt/lex-web
WORKDIR /opt/lex-web
RUN lex pkg install
```

— replacing the `COPY` block in this Dockerfile.

## Bench-runner integration

For local matrix runs (not the public submission), `bench/run.sh`
already drives the framework against in-memory SQLite by default.
To exercise the Postgres path, run:

```sh
docker run --rm -d --name lex-web-tfb -p 8084:8080 lex-web:tfb
# ...wait, then point the harness at :8084:
BENCH_DB=postgres LEX_DB_PORT=8084 bench/run.sh lex-web-db
docker stop lex-web-tfb
```

The `bench/run.sh` matrix automatically picks up the new `/updates`
row (added in this PR) when targeting `lex-web-db`.
