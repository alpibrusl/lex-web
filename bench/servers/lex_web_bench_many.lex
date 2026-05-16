# lex-web framework microbenchmark — N-route scaling.
#
# Same shape as lex_web_bench.lex but registers 20 routes. The
# benchmark route is `/users/:id`, which under the previous
# list.fold dispatcher would scan every preceding route before
# matching. With the trie dispatcher (route_trie.lex) the cost
# becomes O(path-depth) regardless of how many other routes are
# registered.
#
# Compare against lex_web_bench.lex (3 routes) to read the
# scaling penalty of list.fold vs trie at realistic route counts.

import "std.net" as net

import "std.str" as str

import "../../src/ctx" as ctx

import "../../src/response" as resp

import "../../src/router" as router

fn h(c :: ctx.Ctx) -> resp.Response {
  resp.text("Hello, World!")
}

fn h_json(c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"message\":\"Hello, World!\"}")
}

fn h_user(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing id"),
    Some(id) => resp.json(str.concat("{\"id\":\"", str.concat(id, "\",\"name\":\"Alice\"}"))),
  }
}

# Register 20 static routes followed by the param/plaintext/json
# routes we actually hit. With list.fold this means `/users/:id` and
# `/plaintext` traversals iterate ~20 misses before matching.
fn app() -> router.Router {
  ((((((((((((((((((((((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r00", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r01", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r02", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r03", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r04", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r05", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r06", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r07", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r08", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r09", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r10", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r11", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r12", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r13", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r14", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r15", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r16", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r17", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r18", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/r19", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/plaintext", h)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/json", h_json)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users/:id", h_user)
  }
}

fn main() -> [net, io, time, crypto, random] Nil {
  let r := app()
  let handler := fn (req :: Request) -> [io, time, crypto, random] Response {
    let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
    let resp_v := router.dispatch(r, raw)
    { status: resp_v.status, body: BodyStr(resp_v.body), headers: resp_v.headers }
  }
  net.serve_fn(8080, handler)
}

