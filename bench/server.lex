# lex-web — benchmark server (TechEmpower-shaped)
#
# Four routes covering the bottom of TFB's matrix. Run this binary
# under wrk to get a rough "where are we" number; compare against
# the public TFB leaderboard (https://www.techempower.com/benchmarks/)
# for any framework you're familiar with as a rough scale.
#
#   GET /plaintext   "Hello, World!"      Content-Type: text/plain
#   GET /json        {"message":"Hello, World!"}
#   GET /db          one random World row
#   GET /queries?queries=N  N random World rows
#
# Rules we follow (relative-comparison only — not a TFB submission):
#
#   * No response caching.
#   * No middleware (logger / request-id / cors) — adding those
#     measures the middleware, not the framework floor.
#   * Each DB endpoint runs the query plan it would in a real app
#     (lex-orm Repo[World] + sql.query).
#   * Plaintext / JSON have no DB access so the framework
#     dispatch + response build is the only thing in the hot path.
#
# Rules we *don't* follow yet (so numbers are lower than the
# public leaderboard for any pipeline-capable framework):
#
#   * HTTP/1.1 pipelining (TFB hits /plaintext with 16 pipelined
#     requests per connection). Needs std.net support.
#   * Postgres. We use SQLite for portability — switch to
#     `conn.open("postgres://...")` for a fair shoot-out.
#
# Run:
#   lex run --allow-effects io,net,time,sql,fs_write \
#           bench/server.lex main
#
# Then in another terminal:
#   bench/run.sh

import "std.net"  as net
import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list
import "std.map"  as map
import "std.sql"  as sql
import "std.random" as random

import "../src/ctx"      as ctx
import "../src/response" as resp
import "../src/router"   as router
import "../src/params"   as params

import "lex-schema/schema"      as s
import "lex-schema/constraints" as c
import "lex-schema/json_value"  as jv
import "lex-schema/error"       as se
import "lex-schema/sdk"         as sdk

import "lex-orm/connection" as conn
import "lex-orm/query"      as q
import "lex-orm/predicate"  as pr
import "lex-orm/error"      as dbe

# ---- World table (the TFB schema) --------------------------------

type World = { id :: Int, randomNumber :: Int }

fn world_schema() -> s.ModelSchema {
  {
    title: "world", description: "",
    fields: [
      s.required_int("id",           [IntPositive]),
      s.required_int("randomNumber", [IntNonNegative]),
    ],
  }
}

fn decode_world(j :: jv.Json) -> Result[World, se.Errors] {
  match jv.j_int("", j, "id", []) {
    Err(e) => Err(e),
    Ok(id) =>
      match jv.j_int("", j, "randomNumber", []) {
        Err(e) => Err(e),
        Ok(n)  => Ok({ id: id, randomNumber: n }),
      },
  }
}

fn world_repo() -> q.Repo[World] { q.for_schema(world_schema(), decode_world) }

fn world_to_json(w :: World) -> Str {
  "{\"id\":" + int.to_str(w.id)
   + ",\"randomNumber\":" + int.to_str(w.randomNumber) + "}"
}

# ---- Routes ------------------------------------------------------

# /plaintext — raw response, no JSON encoding, no DB.
fn plaintext(_c :: ctx.Ctx) -> resp.Response { resp.text("Hello, World!") }

# /json — one-field object encoded per request.
fn json_hello(_c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"message\":\"Hello, World!\"}")
}

# /db — one random World row.
fn db_single(c :: ctx.Ctx, db :: conn.Db) -> [sql, time] resp.Response {
  let id := random_id()
  match q.run_select(
    q.limit(q.where_clause(q.select(world_repo()), pr.eq("id", PInt(id))), 1),
    db
  ) {
    Err(_)    => resp.internal_error(),
    Ok(items) =>
      match list.head(items) {
        None    => resp.not_found(),
        Some(w) => resp.json(world_to_json(w)),
      },
  }
}

# /queries?queries=N — N random World rows, N clamped 1..500 per TFB rules.
fn db_queries(c :: ctx.Ctx, db :: conn.Db) -> [sql, time] resp.Response {
  let n := clamp(
    match params.query_int(c, "queries", Some(1), []) {
      Ok(x) => x, Err(_) => 1
    }, 1, 500)
  let ws := run_n(n, db, [])
  resp.json("[" + str.join(list.map(ws, world_to_json), ",") + "]")
}

fn run_n(n :: Int, db :: conn.Db, acc :: List[World]) -> [sql, time] List[World] {
  if n <= 0 { acc }
  else {
    let id := random_id()
    match q.run_select(
      q.limit(q.where_clause(q.select(world_repo()), pr.eq("id", PInt(id))), 1),
      db
    ) {
      Err(_) => run_n(n - 1, db, acc),
      Ok(xs) =>
        match list.head(xs) {
          None    => run_n(n - 1, db, acc),
          Some(w) => run_n(n - 1, db, list.concat(acc, [w])),
        },
    }
  }
}

fn random_id() -> [time] Int {
  # 1..10_000 per TFB. random.int_in_range(low, high) gives us the
  # uniform distribution we want; seeded by the runtime clock.
  random.int_in_range(1, 10_000)
}

fn clamp(n :: Int, lo :: Int, hi :: Int) -> Int {
  if n < lo { lo } else { if n > hi { hi } else { n } }
}

# ---- Seed --------------------------------------------------------

# Seed 10_000 World rows. TFB uses 10k; we match so the working
# set fits any modern page cache and DB-driver overhead, not page
# faults, dominates.
fn seed(db :: conn.Db) -> [sql, time] Result[Unit, dbe.DbErr] {
  let ddl := sdk.to_sql_ddl(world_schema(), DialectSqlite)
  match sql.exec(db.handle, ddl, []) {
    Err(e) => Err(DbQueryFailed(e)),
    Ok(_)  =>
      match sql.exec(db.handle, "DELETE FROM \"world\"", []) {
        Err(e) => Err(DbQueryFailed(e)),
        Ok(_)  => insert_loop(1, 10_000, db),
      },
  }
}

fn insert_loop(i :: Int, n :: Int, db :: conn.Db) -> [sql, time] Result[Unit, dbe.DbErr] {
  if i > n { Ok(()) }
  else {
    let stmt := "INSERT INTO \"world\" (\"id\", \"randomNumber\") VALUES (?, ?)"
    match sql.exec(db.handle, stmt, [PInt(i), PInt(random.int_in_range(1, 10_000))]) {
      Err(e) => Err(DbQueryFailed(e)),
      Ok(_)  => insert_loop(i + 1, n, db),
    }
  }
}

# ---- App ---------------------------------------------------------

fn app(db :: conn.Db) -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/plaintext", plaintext)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/json", json_hello)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/db",
           fn (c :: ctx.Ctx) -> [sql, time] resp.Response { db_single(c, db) })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/queries",
           fn (c :: ctx.Ctx) -> [sql, time] resp.Response { db_queries(c, db) })
       }
  # Note: no middleware. Real apps add cors / logger / request-id;
  # the bench measures the *framework floor*, not those.
}

fn main() -> [net, io, time, sql, fs_write] Nil {
  match conn.connect_sqlite(":memory:") {
    Err(_) => io.print("failed to open sqlite"),
    Ok(db) => {
      match seed(db) {
        Err(_) => io.print("seed failed"),
        Ok(_)  => {
          let _ := io.print("bench server on :8080")
          let _ := io.print("  GET /plaintext  /json  /db  /queries?queries=N")
          net.serve_fn(8080,
            fn (req :: ctx.RawRequest) -> [io, time, sql] resp.Response {
              router.dispatch(app(db), req)
            })
        },
      }
    },
  }
}
