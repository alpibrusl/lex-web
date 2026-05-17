# TechEmpower Framework Benchmarks — lex-web submission
#
# Self-contained image: PostgreSQL + lex toolchain + lex-web sources,
# launched together via supervisord. TFB's harness expects a single
# container per framework binding, port 8080 exposed.
#
# Build:
#   docker build -f bench/tfb/Dockerfile -t lex-web:tfb .
#
# Run locally to sanity-check:
#   docker run --rm -p 8080:8080 lex-web:tfb
#   curl http://localhost:8080/plaintext
#   curl http://localhost:8080/json
#   curl 'http://localhost:8080/db'
#   curl 'http://localhost:8080/queries?queries=20'
#   curl 'http://localhost:8080/updates?queries=20'
#
# Submit:
#   * Clone TechEmpower/FrameworkBenchmarks
#   * Copy bench/tfb/ + bench/servers/lex_web_bench_db.lex into
#     frameworks/Lex/lex-web/
#   * Add bench/tfb/benchmark_config.json (next to this file) to
#     frameworks/Lex/lex-web/benchmark_config.json
#   * Open a framework-PR against TFB

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LEX_VERSION=0.9.5

# ---- System deps + Postgres ---------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        postgresql \
        postgresql-contrib \
        supervisor \
        tini \
    && rm -rf /var/lib/apt/lists/*

# ---- Lex toolchain ------------------------------------------------
# Same install pattern as .github/workflows/lex.yml — pull the
# pre-built release tarball matching lex.toml's pin, drop the binary
# into /usr/local/bin.
RUN curl -fsSL -o /tmp/lex.tgz \
        "https://github.com/alpibrusl/lex-lang/releases/download/v${LEX_VERSION}/lex-v${LEX_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    && tar -xzf /tmp/lex.tgz -C /tmp/ \
    && install -m 0755 "/tmp/lex-v${LEX_VERSION}-x86_64-unknown-linux-gnu/lex" /usr/local/bin/lex \
    && rm -rf /tmp/lex*

# ---- App sources --------------------------------------------------
WORKDIR /opt/lex-web
COPY lex.toml ./lex.toml
COPY src/ ./src/
COPY bench/servers/lex_web_bench_db.lex ./bench/servers/lex_web_bench_db.lex

# Pull lex-schema / lex-crypto / lex-orm via `lex pkg install`.
# This bakes them into the image; the runtime container is fully
# self-contained.
RUN lex pkg install

# ---- Postgres init ------------------------------------------------
# TFB convention: the runner provisions a `hello_world` database
# pre-loaded with the `world` table (10_000 rows). For local
# verification we set it up at boot via the supervisord pre-start
# hook in start.sh. Production TFB runs replace this DB with their
# own provisioner.
COPY bench/tfb/start.sh /opt/lex-web/start.sh
COPY bench/tfb/supervisord.conf /etc/supervisor/conf.d/lex-web.conf
RUN chmod +x /opt/lex-web/start.sh

EXPOSE 8080
ENV BENCH_DB=postgres://benchmarkdbuser:benchmarkdbpass@localhost/hello_world
ENV PORT=8080

# tini handles signal propagation so docker stop terminates the
# whole supervisor tree cleanly.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/lex-web.conf"]
