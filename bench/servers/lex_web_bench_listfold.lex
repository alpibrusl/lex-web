# TechEmpower-style framework benchmark for lex-web.
#
# Routes:
#   GET /plaintext      -> "Hello, World!"   (text/plain)
#   GET /json           -> {"message":"Hello, World!"}
#   GET /users/:id      -> {"id":"<id>","name":"Alice"}
#
# Run:
#   lex run --allow-effects io,net,time,crypto \
#           bench/servers/lex_web_bench.lex main
#
# The middleware list is intentionally empty (no logger, no
# request_id) so we measure the framework's raw dispatch cost the
# same way TechEmpower does — every framework in the bench runs
# without observability middleware.

import "std.net" as net

import "std.str" as str

import "../../src/ctx" as ctx

import "../../src/response" as resp

import "../../src/router" as router

fn plaintext(c :: ctx.Ctx) -> resp.Response {
  resp.text("Hello, World!")
}

fn json_hello(c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"message\":\"Hello, World!\"}")
}

fn get_user(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing id"),
    Some(id) => resp.json(str.concat("{\"id\":\"", str.concat(id, "\",\"name\":\"Alice\"}"))),
  }
}

fn app() -> router.Router {
  ((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/plaintext", plaintext)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/json", json_hello)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users/:id", get_user)
  }
}

# Boundary adaptor.
#
# net.serve_fn (lex-lang 0.9.3) expects `(Request) -> Response`, where
# Request = { method, path, query, body, headers } and Response =
# { status, body :: ResponseBody, headers } after #375 (streaming
# bodies). lex-web's Ctx/Response stack predates ResponseBody and uses
# `body :: Str`. Two tiny adaptors at the boundary keep the framework
# unchanged: rebuild the request as a `ctx.RawRequest` literal, and
# wrap the framework's Str body in `BodyStr(...)` on the way out.
#
# The router value `r` is built once in main and captured by the
# closure — building it per request was a measurable hotspot.
fn main() -> [net, io, time, crypto, random] Nil {
  let r := app()
  let h := fn (req :: Request) -> [io, time, crypto, random] Response {
    let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
    let resp_v := router.dispatch_listfold(r, raw)
    { status: resp_v.status, body: BodyStr(resp_v.body), headers: resp_v.headers }
  }
  net.serve_fn(8080, h)
}

