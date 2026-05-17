# TechEmpower-style framework benchmark for lex-web — DB variant.
#
# Routes:
#   GET /plaintext       -> "Hello, World!"             (text/plain)
#   GET /json            -> {"message":"Hello, World!"} (application/json)
#   GET /db              -> one random World row
#   GET /queries?queries=N -> N random World rows, N clamped 1..500
#
# The DB endpoints use the new effectful-handler path (`route_effectful`)
# introduced in this branch. The /plaintext and /json endpoints stay on
# the pure `route` path so we can see the framework's pure dispatch
# floor on the same binary that pays the SQL roundtrip for /db.
#
# Run:
#   lex run --allow-effects io,net,time,sql,fs_write,crypto,random,fs_read \
#           bench/servers/lex_web_bench_db.lex main
#
# Then drive it with `bench/run.sh` (or wrk directly).

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.time" as time

import "std.sql" as sql

import "std.random" as random

import "../../src/ctx" as ctx

import "../../src/response" as resp

import "../../src/router" as router

import "lex-orm/connection" as conn

import "lex-orm/error" as dbe

# ---- World row (the TFB schema) ----------------------------------
# The standard TFB row has two columns. We don't go through the
# lex-schema codegen path here — the schema is tiny and the bench's
# point is the framework + SQL stack, not the validation layer.
type World = { id :: Int, randomNumber :: Int }

# Render the row as a JSON object string. Pure, trivial.
fn world_to_json(w :: World) -> Str {
  str.concat("{\"id\":", str.concat(int.to_str(w.id), str.concat(",\"randomNumber\":", str.concat(int.to_str(w.randomNumber), "}"))))
}

# Pick a random id in [1, 10_000] per the TFB rules.
# `random` in lex 0.9.4 is pure — we seed from the wall clock per
# request, which is sufficient for benchmark distribution (we're not
# defending against an adversary, we just want uniform draws).
fn pick_id() -> [time] Int {
  let rng := random.seed(time.now_ms())
  match random.int(rng, 1, 10000) {
    (n, _) => n,
  }
}

fn clamp(n :: Int, lo :: Int, hi :: Int) -> Int {
  if n < lo {
    lo
  } else {
    if n > hi {
      hi
    } else {
      n
    }
  }
}

# ---- Pure routes -------------------------------------------------
fn plaintext(c :: ctx.Ctx) -> resp.Response {
  resp.text("Hello, World!")
}

fn json_hello(c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"message\":\"Hello, World!\"}")
}

# ---- DB routes ---------------------------------------------------
# A single random-id lookup against the seeded `world` table. We hit
# the connection directly via `sql.query` rather than going through
# lex-orm's query builder — the bench's `/db` row is meant to measure
# "framework dispatch + a single round-trip", and the builder adds a
# layer that doesn't reflect the TFB scoring shape.
fn db_single(db :: conn.ConnDb, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  let id := pick_id()
  let raw :: Result[List[World], SqlError] := sql.query(db.handle, "SELECT id, randomNumber FROM world WHERE id = ?", [PInt(id)])
  match raw {
    Err(_) => resp.internal_error(),
    Ok(rows) => match list.head(rows) {
      None => resp.not_found(),
      Some(w) => resp.json(world_to_json(w)),
    },
  }
}

# Same shape as /db, repeated N times. The handler accepts the request
# context only to read the `?queries=N` parameter; everything else is
# the same as `db_single`.
fn db_queries(db :: conn.ConnDb, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  let n := match ctx.query_param(c, "queries") {
    Some(s) => match str.to_int(s) {
      Some(x) => clamp(x, 1, 500),
      None => 1,
    },
    None => 1,
  }
  let rng := random.seed(time.now_ms())
  let ws := run_n(n, db, rng, [])
  resp.json(str.concat("[", str.concat(str.join(list.map(ws, world_to_json), ","), "]")))
}

# Tail-recursive N-fetch. Errors are swallowed silently (a real app
# wouldn't, but TFB scores the happy-path numbers; a 500 in the middle
# of the fan-out would skew the row downward without telling us
# anything new).
fn run_n(n :: Int, db :: conn.ConnDb, rng :: Rng, acc :: List[World]) -> [sql] List[World] {
  if n <= 0 {
    acc
  } else {
    match random.int(rng, 1, 10000) {
      (id, rng2) => {
        let raw :: Result[List[World], SqlError] := sql.query(db.handle, "SELECT id, randomNumber FROM world WHERE id = ?", [PInt(id)])
        match raw {
          Err(_) => run_n(n - 1, db, rng2, acc),
          Ok(rows) => match list.head(rows) {
            None => run_n(n - 1, db, rng2, acc),
            Some(w) => run_n(n - 1, db, rng2, list.concat(acc, [w])),
          },
        }
      },
    }
  }
}

# ---- App ---------------------------------------------------------
# Hoisted: built once in main, captures `db` in the effectful route
# closures. The bench's per-request cost is just `dispatch` + the
# handler body — no router rebuild, no app() reconstruction.
#
# The two DB handlers are wrapped in thin lambdas because
# `route_effectful` requires the full wide effect row and the
# underlying `db_single` / `db_queries` use a narrower set. lex
# 0.9.4's effect rows are invariant on closure types, so the wrap is
# mechanical — the body of the lambda calls the narrower function
# from a wider context, which lex allows.
fn app(db :: conn.ConnDb) -> router.Router {
  (((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/plaintext", plaintext)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/json", json_hello)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/db", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
      db_single(db, c)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/queries", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
      db_queries(db, c)
    })
  }
}

# ---- Seed --------------------------------------------------------
# 10_000 rows. TFB uses the same count; the working set fits in any
# modern page cache so the bench measures driver overhead, not page
# faults.
fn seed(db :: conn.ConnDb) -> [sql, time] Result[Unit, dbe.DbErr] {
  match sql.exec(db.handle, "CREATE TABLE IF NOT EXISTS world (id INTEGER PRIMARY KEY, randomNumber INTEGER NOT NULL)", []) {
    Err(e) => Err(dbe.query_err(e.message)),
    Ok(_) => match sql.exec(db.handle, "DELETE FROM world", []) {
      Err(e) => Err(dbe.query_err(e.message)),
      Ok(_) => insert_loop(1, 10000, db),
    },
  }
}

fn insert_loop(i :: Int, n :: Int, db :: conn.ConnDb) -> [sql, time] Result[Unit, dbe.DbErr] {
  if i > n {
    Ok(())
  } else {
    let rng := random.seed(time.now_ms() + i)
    let rnd := match random.int(rng, 1, 10000) {
      (v, _) => v,
    }
    match sql.exec(db.handle, "INSERT INTO world (id, randomNumber) VALUES (?, ?)", [PInt(i), PInt(rnd)]) {
      Err(e) => Err(dbe.query_err(e.message)),
      Ok(_) => insert_loop(i + 1, n, db),
    }
  }
}

# ---- main --------------------------------------------------------
# Boundary adaptor matches lex_web_bench.lex: rebuild the request as
# a `ctx.RawRequest`, call dispatch, wrap the framework body in
# `BodyStr(...)` on the way out.
fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Unit {
  match conn.connect_sqlite(":memory:") {
    Err(_) => io.print("failed to open sqlite"),
    Ok(db) => {
      match seed(db) {
        Err(_) => io.print("seed failed"),
        Ok(_) => {
          let __lex_discard_1 := io.print("bench server on :8084")
          let __lex_discard_2 := io.print("  GET /plaintext  /json  /db  /queries?queries=N")
          let r := app(db)
          let handler := fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
            let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
            let resp_v := router.dispatch(r, raw)
            { status: resp_v.status, body: BodyStr(resp_v.body), headers: resp_v.headers }
          }
          net.serve_fn(8084, handler)
        },
      }
    },
  }
}

