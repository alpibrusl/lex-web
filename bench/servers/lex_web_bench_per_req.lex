# Variant of lex_web_bench.lex with `app()` rebuilt PER REQUEST inside `handle`.
# Mirrors the bench as it was first committed (before the hoist) so we can
# A/B against the closure-captured version to see if router-build cost is
# actually a hotspot.

import "std.net"  as net
import "std.str"  as str

import "../../src/ctx"      as ctx
import "../../src/response" as resp
import "../../src/router"   as router

fn plaintext(c :: ctx.Ctx) -> resp.Response {
  resp.text("Hello, World!")
}

fn json_hello(c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"message\":\"Hello, World!\"}")
}

fn get_user(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "id") {
    None     => resp.bad_request("missing id"),
    Some(id) =>
      resp.json(str.concat(
        "{\"id\":\"",
        str.concat(id, "\",\"name\":\"Alice\"}"))),
  }
}

fn app() -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/plaintext", plaintext)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/json", json_hello)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/users/:id", get_user)
       }
}

fn handle(req :: Request) -> [io, time, crypto, random] Response {
  let raw := {
    body:    req.body,
    method:  req.method,
    path:    req.path,
    query:   req.query,
    headers: req.headers,
  }
  let r := router.dispatch(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn main() -> [net, io, time, crypto, random] Nil {
  net.serve_fn(8080, handle)
}
