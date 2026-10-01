# lex-web — pure router
#
# The route table and dispatcher with nothing else attached: `new`,
# `route`, `dispatch_pure`. Programs that only need this surface
# import THIS module instead of router.lex and run under
# `--allow-effects net` (the `net.serve_fn` bridge) with nothing more:
#
#   import "../src/router_pure" as router
#
#   fn app() -> router.Router {
#     router.route(router.new(), "GET", "/quote/:sym", quote)
#   }
#
# Why a separate module: Lex checks effects per PROGRAM, and the
# runtime refuses to start a program whose compiled functions declare
# an effect the policy hasn't granted — declared, not called. router.lex
# also holds `dispatch` (the middleware-aware dispatcher), whose
# declared row is [io, time, crypto, random, sql, fs_read, fs_write,
# net, concurrent, llm, proc, approval]; importing router.lex for
# `dispatch_pure` therefore demands all twelve effects at runtime
# even though dispatch_pure never touches one. Middleware and
# lex-log (request ids, tracing) are pulled in the same way.
#
# This module imports only pure modules (ctx, response, route_trie,
# stream, lex-schema). Keep it that way: `lex check src/router_pure.lex`
# must print no `required effects:` line, and CI enforces it.
#
# `route_named` + `dispatch_with` serve effectful handlers under the
# narrowest grant: the router stores a name, the caller's resolver carries
# the effect row (#59).
#
# What you give up versus router.lex: middleware (`use_mw`), effectful
# and streaming routes, per-route metadata, OpenAPI export, OAuth2
# schemes. `dispatch_pure` never ran middleware or effectful handlers
# anyway. A `router_pure.Router` is a different type from
# `router.Router`; choose one per app. router.lex builds on the same
# trie (route_trie.lex) and delegates `dispatch_pure` to this module,
# so both tiers route identically.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "lex-schema/validator" as v

import "lex-schema/json_value" as jv

import "./ctx" as ctx

import "./response" as resp

import "./route_trie" as rt

type Router = { trie :: rt.TrieNode }

fn new() -> Router {
  { trie: rt.empty_node() }
}

# Register a pure handler. Later registrations for the same method
# and pattern replace earlier ones.
fn route(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> resp.Response) -> Router {
  { trie: rt.insert(r.trie, str.to_upper(method), split_path(pattern), HPure(handler, None)) }
}

# Register a route by name instead of by closure (#59). The router holds
# no handler, so it carries no effect row: `dispatch_with` hands the
# matched name and context to a resolver the caller supplies, and the
# whole dispatch declares exactly the resolver's row. A service that
# wants a least-privilege grant (say `net,sql`) registers its routes
# here and resolves them with a `[sql]` function, where `router.dispatch`
# would demand all twelve effects.
fn route_named(r :: Router, method :: Str, pattern :: Str, name :: Str) -> Router {
  { trie: rt.insert(r.trie, str.to_upper(method), split_path(pattern), HNamed(name)) }
}

# Match the request and call `resolve(name, ctx)`. Path params are bound
# on the ctx as in `dispatch_pure`. No match is a 404; a route that was
# registered with a closure (`route`) is a 500 here, since its handler is
# not reachable through a name. Middleware does not run: its row is wide.
fn dispatch_with[e](r :: Router, req :: ctx.RawRequest, resolve :: (Str, ctx.Ctx) -> [| e] resp.Response) -> [| e] resp.Response {
  let method := str.to_upper(req.method)
  match rt.lookup(r.trie, method, split_path(req.path)) {
    None => resp.not_found(),
    Some(matched) => {
      let c := ctx.from_request(req, match matched {
        (_, p) => p,
      })
      match matched {
        (HNamed(name), _) => resolve(name, c),
        _ => resp.with_ct(500, "lex-web: dispatch_with only serves routes registered via route_named.", "text/plain"),
      }
    },
  }
}

# Pure dispatcher: honours only HPure routes. HEff / HStream routes
# (only reachable through a table built by router.lex) resolve to a
# synthetic 500 instead of running.
fn dispatch_pure(r :: Router, req :: ctx.RawRequest) -> resp.Response {
  dispatch_trie(r.trie, req)
}

# Shared by router.lex's dispatch_pure so both routers behave alike.
fn dispatch_trie(trie :: rt.TrieNode, req :: ctx.RawRequest) -> resp.Response {
  let method := str.to_upper(req.method)
  let path_segs := split_path(req.path)
  match rt.lookup(trie, method, path_segs) {
    None => resp.not_found(),
    Some(matched) => {
      let body := match matched {
        (b, _) => b,
      }
      let params := match matched {
        (_, p) => p,
      }
      let c := ctx.from_request(req, params)
      match body {
        HPure(h, rm) => apply_response_model(h(c), rm),
        HEff(_, _) => resp.with_ct(500, "lex-web: this route was registered via route_effectful and cannot be invoked from dispatch_pure. Use dispatch with --allow-effects, or restrict the route to a pure handler.", "text/plain"),
        HStream(_, _) => resp.with_ct(500, "lex-web: this route was registered via route_stream and cannot be invoked from dispatch_pure. Use dispatch_outcome and match DStream in your main bridge.", "text/plain"),
        HNamed(_) => resp.with_ct(500, "lex-web: this route was registered via route_named and cannot be invoked from dispatch_pure. Use dispatch_with.", "text/plain"),
      }
    },
  }
}

# Response-model post-processing (#28): validate the handler's JSON
# body against the route's schema and strip undeclared fields. On
# failure the response is replaced with a 500 carrying a fixed message.
fn apply_response_model(response :: resp.Response, rm :: Option[v.Validator]) -> resp.Response {
  match rm {
    None => response,
    Some(validator) => match v.validate_str(validator, response.body) {
      Err(_) => {
        let body := "{\"error\":\"response_model: handler returned data that does not conform to the declared schema\"}"
        { body: body, status: 500, headers: map.set(response.headers, "content-type", "application/json") }
      },
      Ok(j) => { body: jv.stringify(j), status: response.status, headers: response.headers },
    },
  }
}

fn split_path(path :: Str) -> List[Str] {
  list.filter(str.split(path, "/"), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
}

