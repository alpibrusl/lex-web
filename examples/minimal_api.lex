# lex-web example — minimal pure service
#
# router_pure.new + route + dispatch_pure, ctx.path_param and resp.json,
# bridged to net.serve_fn. No middleware, no effectful routes, so the
# only authority this needs is `net`. It imports router_pure rather
# than router: the runtime checks every function a program declares,
# and router.lex declares the wide dispatch row (see router_pure.lex).
#
#   lex run --allow-effects net examples/minimal_api.lex main
#
# Try:
#   curl http://localhost:8083/quote/lex

import "std.net" as net

import "std.str" as str

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router_pure" as router

fn quote(c :: ctx.Ctx) -> resp.Response {
  let sym := match ctx.path_param(c, "sym") {
    Some(s) => s,
    None => "",
  }
  resp.json(str.concat("{\"symbol\":\"", str.concat(sym, "\",\"price\":42}")))
}

fn app() -> router.Router {
  router.route(router.new(), "GET", "/quote/:sym", quote)
}

fn handle(req :: Request) -> Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch_pure(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn main() -> [net] Nil {
  net.serve_fn(8083, handle)
}

