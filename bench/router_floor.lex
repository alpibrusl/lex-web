# lex-web — bench through the lex-web router (no DB, no middleware)
#
# Routes through router.dispatch_pure so we measure the router
# lookup + dispatch cost on top of net.serve_fn. Comparing this
# to floor.lex isolates the router overhead.
#
# Run:
#   lex run --allow-effects io,net bench/router_floor.lex main

import "std.net" as net
import "std.io"  as io
import "std.map" as map

import "../src/ctx"      as ctx
import "../src/response" as resp
import "../src/router"   as router

fn plaintext(_c :: ctx.Ctx) -> resp.Response { resp.text("Hello, World!") }

fn json_hello(_c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"message\":\"Hello, World!\"}")
}

fn app() -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/plaintext", plaintext)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/json", json_hello)
       }
}

# Adapt: global Request → ctx.RawRequest, resp.Response → global Response.
# Both directions are pure record-shape rebuilds so the typechecker
# sees nominal types correctly.
fn handle(req :: Request) -> Response {
  let raw :: ctx.RawRequest := {
    method:  req.method,
    path:    req.path,
    query:   req.query,
    body:    req.body,
    headers: req.headers,
  }
  let r := router.dispatch_pure(app(), raw)
  { status: r.status, body: r.body, headers: r.headers }
}

fn main() -> [net, io] Nil {
  let _ := io.print("router-bench on :8080 — /plaintext, /json")
  net.serve_fn(8080, handle)
}
