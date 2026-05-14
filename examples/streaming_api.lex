# examples/streaming_api.lex — streaming SSE + signed-cookie demo
#
# Demonstrates two 0.9.2-enabled features:
#
#   1. Server-Sent Events via stream.event_stream + iter.unfold
#   2. Signed cookies via crypto.sign / crypto.verify
#
# Run:
#   lex run --allow-effects io,net,time,crypto examples/streaming_api.lex main
#
# Try it:
#   curl http://localhost:8080/events        # SSE stream (first 5 ticks)
#   curl -H "Cookie: session=..." /profile  # signed-cookie auth

import "std.str"  as str
import "std.int"  as int
import "std.map"  as map
import "std.iter" as iter

import "../src/ctx"      as ctx
import "../src/response" as resp
import "../src/router"   as router
import "../src/crypto"   as wc
import "../src/stream"   as stream

# ---- Shared secret (in production: load from environment) --------

fn secret() -> Str { "change-me-in-production" }

# ---- Handlers ----------------------------------------------------

# GET /events — SSE stream of 5 counter ticks as JSON objects.
# In a real app the iterator would tail a database or message queue.
fn events(c :: ctx.Ctx) -> resp.Response {
  let chunks := stream.unfold(0,
    fn (n :: Int) -> Option[(Str, Int)] {
      if n >= 5 { None }
      else {
        let payload := str.concat("{\"tick\":", str.concat(int.to_str(n), "}"))
        Some((payload, n + 1))
      }
    })
  let sr := stream.event_stream(chunks)
  { body: iter.collect_str(sr.body), status: sr.status, headers: sr.headers }
}

# POST /login — issue a signed cookie carrying the username.
fn login(c :: ctx.Ctx) -> resp.Response {
  let username := if str.is_empty(c.body) { "guest" } else { c.body }
  let token    := wc.sign(secret(), username)
  resp.with_header(
    resp.json(str.concat("{\"ok\":true,\"user\":\"", str.concat(username, "\"}"))),
    "set-cookie",
    str.concat("session=", str.concat(token, "; HttpOnly; SameSite=Strict")))
}

# GET /profile — verify the signed cookie, return the username.
fn profile(c :: ctx.Ctx) -> resp.Response {
  match ctx.cookie(c, "session") {
    None        => resp.unauthorized("no session cookie"),
    Some(token) =>
      match wc.verify(secret(), token) {
        Err(reason) => resp.unauthorized(reason),
        Ok(username) =>
          resp.json(str.concat("{\"user\":\"", str.concat(username, "\"}"))),
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
  router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET",  "/events",  events)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "POST", "/login",   login)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET",  "/profile", profile)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET",  "/health",  health)
       }
}

fn handle(req :: ctx.RawRequest) -> [io, time, crypto] resp.Response {
  router.dispatch(app(), req)
}

fn main() -> [net, io, time, crypto] Nil {
  net.serve_fn(8080, handle)
}
