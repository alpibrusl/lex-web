# lex-web example: user-defined middleware (#27)
#
# Demonstrates `mw.custom(name, before, after)` — the framework's
# escape hatch for middleware that isn't in the built-in
# MiddlewareKind enum. Two examples:
#
#   1. `bearer_gate` — pre-handler hook that checks an
#      `Authorization: Bearer <token>` header against a hard-coded
#      allowlist (real apps would call into std.crypto / lex-crypto
#      / a DB; the shape is the same).
#
#   2. `latency_stamp` — post-handler hook that appends an
#      `x-served-by` header so clients can observe which app
#      version answered. Stand-in for telemetry / observability
#      stamping (statsd, OTel, anything in `[net]`).
#
# Run:
#   lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent \
#           examples/middleware_custom.lex main
#
# Try:
#   curl -i http://localhost:8081/public                                                # 200 + x-served-by
#   curl -i http://localhost:8081/admin                                                 # 401, no x-served-by
#   curl -i -H 'Authorization: Bearer s3cret' http://localhost:8081/admin               # 200 + x-served-by

import "std.net" as net

import "std.io" as io

import "std.map" as map

import "std.str" as str

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/middleware" as mw

# ---- Custom middleware #1: bearer-token gate -------------------------
#
# Pre-handler hook. Short-circuits with 401 unless the request
# carries `Authorization: Bearer <token>` where <token> matches
# our hard-coded allowlist. Real apps swap the allowlist for a
# JWT verifier (see `src/auth.lex`) or a DB lookup.
fn require_bearer(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] mw.PreResult {
  match ctx.bearer_token(c) {
    None => Short(resp.unauthorized("missing bearer token")),
    Some(token) => if token == "s3cret" or token == "admin42" {
      Continue(c)
    } else {
      Short(resp.unauthorized("invalid token"))
    },
  }
}

fn bearer_gate_noop_after(_c :: ctx.Ctx, r :: resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  r
}

fn bearer_gate() -> mw.MiddlewareKind {
  mw.custom("bearer-gate", require_bearer, bearer_gate_noop_after)
}

# ---- Custom middleware #2: latency / origin stamp --------------------
#
# Post-handler hook. Stamps `x-served-by: <hostname>` on every
# response. Drop-in shape for observability stamping (request-id
# correlation, tracing, statsd counters, etc.).
fn stamp_noop_before(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] mw.PreResult {
  Continue(c)
}

fn stamp_origin(_c :: ctx.Ctx, r :: resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  resp.with_header(r, "x-served-by", "lex-web-demo")
}

fn latency_stamp() -> mw.MiddlewareKind {
  mw.custom("latency-stamp", stamp_noop_before, stamp_origin)
}

# ---- Handlers --------------------------------------------------------
fn public_handler(_c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"hello\":\"public\"}")
}

fn admin_handler(_c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"hello\":\"admin\"}")
}

# ---- App + dispatch ---------------------------------------------------
#
# Two middlewares in the stack:
#   1. bearer-gate   — runs before every handler; short-circuits
#                      unauthorised /admin requests
#   2. latency-stamp — runs after every handler; stamps the origin
#                      header on every response
#
# bearer-gate's `before` short-circuits BEFORE the handler runs, but
# `run_post` still walks the full middleware list afterwards — so
# even a 401 short-circuit gets the `x-served-by` stamp from
# latency-stamp. Match-order is left-to-right via `use_mw`.
fn app() -> router.Router {
  let r0 := router.new()
  let r1 := router.use_mw(r0, latency_stamp())
  let r2 := router.use_mw(r1, bearer_gate())
  let r3 := router.route(r2, "GET", "/public", public_handler)
  router.route(r3, "GET", "/admin", admin_handler)
}

# Bridge between lex-lang's global `Request`/`Response` (what
# `net.serve_fn` passes/receives) and lex-web's `ctx.RawRequest` /
# `resp.Response`. The structural record on `raw` matches the
# RawRequest shape; `BodyStr` wraps the framework's string body in
# the runtime's `ResponseBody` union (#375).
fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Nil {
  let __lex_discard_1 := io.print("custom-middleware demo on http://localhost:8081")
  let __lex_discard_2 := io.print("  GET /public                    (open)")
  let __lex_discard_3 := io.print("  GET /admin                     (401)")
  let __lex_discard_4 := io.print("  GET /admin -H 'Authorization: Bearer s3cret'   (200)")
  net.serve_fn(8081, handle)
}

