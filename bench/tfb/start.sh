#!/usr/bin/env bash
# Boot Postgres, seed the TFB `hello_world` database, then exec the
# lex-web bench server. Invoked by supervisord (see supervisord.conf).
set -euo pipefail

PGDATA="/var/lib/postgresql/16/main"
PG_USER=benchmarkdbuser
PG_PASS=benchmarkdbpass
PG_DB=hello_world

# Start Postgres as the system postgres user.
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D ${PGDATA} -l /tmp/pg.log start"

# Wait for it.
for _ in {1..30}; do
  if su postgres -c "psql -c 'select 1' >/dev/null 2>&1"; then break; fi
  sleep 0.5
done

# Provision the role + DB if missing. Idempotent — re-runs are safe.
su postgres -c "psql -tAc \"select 1 from pg_roles where rolname='${PG_USER}'\"" | grep -q 1 \
  || su postgres -c "psql -c \"create user ${PG_USER} with password '${PG_PASS}'\""
su postgres -c "psql -tAc \"select 1 from pg_database where datname='${PG_DB}'\"" | grep -q 1 \
  || su postgres -c "createdb -O ${PG_USER} ${PG_DB}"

# The lex-web bench server creates its own `world` table via
# CREATE TABLE IF NOT EXISTS and seeds 10_000 rows at startup.
cd /opt/lex-web
exec lex run \
  --allow-effects io,net,time,crypto,random,sql,fs_read,fs_write,concurrent,env \
  bench/servers/lex_web_bench_db.lex main
