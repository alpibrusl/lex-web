# examples/streaming_api.lex — SSE + signed-cookie demo
#
# Demonstrates two 0.9.2-enabled features:
#
#   1. Server-Sent Events via stream.event_stream
#   2. Signed cookies via crypto.sign / crypto.verify
#
# The /events endpoint materialises 5 SSE frames into a single Str
# body and returns it through the framework. lex-lang 0.9.2 also
# supports truly-lazy streaming via the `BodyStream(Iter[Str])`
# ResponseBody union — see `bench/servers/lex_web_bench_stream.lex`
# for the lazy-pull variant. lex-web's `resp.Response` still has
# `body :: Str`, so any handler that returns through the router
# materialises; bypass the router and return `BodyStream(...)`
# directly at the `net.serve_fn` boundary for true streaming.
#
# Run:
#   lex run --allow-effects io,net,time,crypto,random,sql,fs_read,fs_write,concurrent \
#           examples/streaming_api.lex main
#
# Try it:
#   curl http://localhost:8080/events        # 5 SSE frames in one shot
#   curl -H "Cookie: session=..." /profile   # signed-cookie auth

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.map" as map

import "std.iter" as iter

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/crypto" as wc

import "../src/stream" as stream

# ---- Shared secret (in production: load from environment) --------
fn secret() -> Str {
  "change-me-in-production"
}

# ---- Handlers ----------------------------------------------------
# GET /events — SSE stream of 5 counter ticks as JSON objects.
# In a real app the iterator would tail a database or message queue.
fn events(c :: ctx.Ctx) -> resp.Response {
  let frames := list.map(list.range(0, 5), fn (n :: Int) -> Str {
    stream.sse_event(str.concat("{\"tick\":", str.concat(int.to_str(n), "}")))
  })
  let sr := stream.event_stream(iter.from_list(frames))
  { body: str.join(frames, ""), status: sr.status, headers: sr.headers }
}

# POST /login — issue a signed cookie carrying the username.
fn login(c :: ctx.Ctx) -> resp.Response {
  let username := if str.is_empty(c.body) {
    "guest"
  } else {
    c.body
  }
  let token := wc.sign(secret(), username)
  resp.with_header(resp.json(str.concat("{\"ok\":true,\"user\":\"", str.concat(username, "\"}"))), "set-cookie", str.concat("session=", str.concat(token, "; HttpOnly; SameSite=Strict")))
}

# GET /profile — verify the signed cookie, return the username.
fn profile(c :: ctx.Ctx) -> resp.Response {
  match ctx.cookie(c, "session") {
    None => resp.unauthorized("no session cookie"),
    Some(token) => match wc.verify(secret(), token) {
      Err(reason) => resp.unauthorized(reason),
      Ok(username) => resp.json(str.concat("{\"user\":\"", str.concat(username, "\"}"))),
    },
  }
}

# GET /health — verify webhook signature demo.
# Pass X-Sig: blake2b(secret || "ping") to get 200.
fn health(c :: ctx.Ctx) -> resp.Response {
  let sig := ctx.header_or(c, "x-sig", "")
  if str.is_empty(sig) {
    resp.json("{\"status\":\"ok\"}")
  } else {
    if wc.verify_webhook(secret(), "ping", sig) {
      resp.json("{\"status\":\"ok\",\"sig\":\"valid\"}")
    } else {
      resp.unauthorized("bad webhook signature")
    }
  }
}

# ---- App ---------------------------------------------------------
fn app() -> router.Router {
  (((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/events", events)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "POST", "/login", login)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/profile", profile)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/health", health)
  }
}

fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Unit {
  let __lex_discard_1 := io.print("streaming-api example on :8080  (GET /events  POST /login  GET /profile  GET /health)")
  net.serve_fn(8080, handle)
}

