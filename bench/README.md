# lex-web benchmark harness

TechEmpower-style framework benchmark — drives lex-web, FastAPI,
Express, and Axum through the same three endpoints via `wrk`.

See [REPORT.md](REPORT.md) for results and methodology.

## Layout

```
bench/
├── REPORT.md             # results + methodology
├── README.md             # this file
├── run.sh                # driver: start each server, hammer with wrk
├── servers/
│   ├── lex_web_bench.lex      # lex-web app (3 routes)
│   ├── fastapi_bench.py       # FastAPI/uvicorn equivalent
│   ├── express_bench.js       # Node/Express equivalent
│   └── axum_bench/            # axum/hyper/tokio (Cargo project)
└── results/              # wrk output + trials.tsv + summary.tsv
                           # (gitignored — regenerate locally)
```

## One-shot run

```sh
# Pre-requisites once: lex built, axum built, deps installed.
( cd ../lex-lang && cargo build --release -p lex-cli )
( cd bench/servers/axum_bench && cargo build --release )
pip install fastapi 'uvicorn[standard]' httptools
( cd bench/servers && npm install --no-package-lock express@4 )

# Run the whole matrix (~6 min with defaults).
bench/run.sh
```

## Tunables

| Env var       | Default        | Notes                                     |
| ------------- | -------------- | ----------------------------------------- |
| `DURATION`    | `15s`          | wrk -d                                    |
| `CONNECTIONS` | `64`           | wrk -c                                    |
| `THREADS`     | `2`            | wrk -t                                    |
| `WARMUP`      | `3`            | warm-up GETs before trials                |
| `TRIALS`      | `3`            | per-endpoint trials; report median        |
| `TASKSET`     | `taskset -c 0-1` | CPU budget per server (set empty to disable) |
| `LEX_BIN`     | `../lex-lang/target/release/lex` | override lex binary path |

Pick a subset of servers:

```sh
bench/run.sh lex-web fastapi
```
