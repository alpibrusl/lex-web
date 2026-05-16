# lex-web — route table and dispatcher
#
# Public surface: new, route, route_effectful, handler_json,
# handler_json_effectful, use_mw, dispatch, dispatch_pure.
#
#   route / handler_json
#     accept a pure (Ctx) -> Response handler. The 95% case — pages
#     that read from `c`, build a response, return. Stays pure all
#     the way through; `dispatch_pure` is a faithful effect-free
#     dispatcher for tests.
#
#   route_effectful / handler_json_effectful
#     accept a (Ctx) -> [io, time, crypto, random, sql, fs_read,
#     fs_write, net] Response handler. Use these when the handler
#     needs to query a database, read a file, call out, or otherwise
#     do anything beyond consuming the Ctx. The effect row is fixed-
#     and-wide because Lex 0.9.4 doesn't support effect-row variables
#     on closures stored in record fields; narrow the body, not the
#     declaration.
#
# The trie (route_trie.lex) stores routes as a `HandlerBody` variant
# (HPure | HEff) at terminal nodes; `dispatch` matches the variant
# and pays the wider effect row regardless. `dispatch_pure` honours
# only HPure routes — HEff routes resolve to a synthetic 500
# Response from inside dispatch_pure (the pure dispatcher can't run
# them; tests should not register effectful routes against
# dispatch_pure).
#
# v0.2 also surfaces FastAPI-style per-route metadata
# (RouteMeta — tags / summary / description / default status) via
# `route_with_meta`, `handler_json_with_meta`, `route_effectful_with_meta`,
# `handler_json_effectful_with_meta`, and `attach_meta`. The router
# never inspects RouteMeta; `openapi.export_openapi` does.
#
# Path pattern syntax:
#   /users/:id        — `:name` binds one non-empty segment
#   /files/*rest      — `*name` binds all remaining segments
#
# Middleware composes left-to-right via `use_mw`; the stack runs
# pre / post around every dispatch. See middleware.lex for kinds.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "./ctx" as ctx

import "./response" as resp

import "./middleware" as mw

import "./route_trie" as rt

import "lex-schema/validator" as v

# ---- Per-route metadata -----------------------------------------
# Optional descriptors that ride along on each route. The router
# never inspects them; they exist for openapi.export_openapi (and
# any future introspection tool).
#
#   tags         — OpenAPI tags for grouping in Swagger UI
#   summary      — short title shown in the operation list
#   description  — long-form Markdown for the operation
#   status       — default success status (0 = leave unset, use 200)
type RouteMeta = { tags :: List[Str], summary :: Str, description :: Str, status :: Int }

fn empty_meta() -> RouteMeta {
  { tags: [], summary: "", description: "", status: 0 }
}

# ---- Types -------------------------------------------------------
# `body` carries the handler as a tagged union (rt.HandlerBody);
# the rest of the record is unchanged from v0.2.
type RouteRecord = { method :: Str, pattern :: Str, segments :: List[Str], body :: rt.HandlerBody, validator :: Option[v.Validator], meta :: RouteMeta }

type Router = { routes :: List[RouteRecord], middleware :: List[mw.MiddlewareKind], trie :: rt.TrieNode }

# ---- Construction ------------------------------------------------
fn new() -> Router {
  { routes: [], middleware: [], trie: rt.empty_node() }
}

# Rebuild the trie from a list of records. O(N) where N = route count;
# only paid at route registration, not at dispatch.
fn compile_trie(records :: List[RouteRecord]) -> rt.TrieNode {
  rt.compile(list.map(records, fn (rec :: RouteRecord) -> (Str, List[Str], rt.HandlerBody) {
    (rec.method, rec.segments, rec.body)
  }))
}

# Register a pure handler. Handler must be `(Ctx) -> Response` —
# no effects allowed. Use this for the 95% case.
fn route(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> resp.Response) -> Router {
  add_record(r, method, pattern, HPure(handler), None, empty_meta())
}

# Register an effectful handler. Handler must declare its effects
# from the fixed-wide set [io, time, crypto, random, sql, fs_read,
# fs_write, net]. Narrow the handler *body*, not the declaration.
fn route_effectful(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net] resp.Response) -> Router {
  add_record(r, method, pattern, HEff(handler), None, empty_meta())
}

# Register a pure route with an attached lex-schema Validator. The
# validator is used at runtime by body.json_body() and at startup by
# openapi.export_openapi() to emit request-body schemas.
fn handler_json(r :: Router, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> resp.Response) -> Router {
  add_record(r, method, pattern, HPure(handler), Some(validator), empty_meta())
}

# Effectful variant of handler_json.
fn handler_json_effectful(r :: Router, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net] resp.Response) -> Router {
  add_record(r, method, pattern, HEff(handler), Some(validator), empty_meta())
}

# Add a middleware to the stack. Middlewares run in registration
# order, outermost first (like Express `app.use`).
fn use_mw(r :: Router, kind :: mw.MiddlewareKind) -> Router {
  { routes: r.routes, middleware: list.concat(r.middleware, [kind]), trie: r.trie }
}

# Workhorse: takes a HandlerBody directly. The public helpers above
# wrap raw closures into HPure / HEff before calling.
fn add_record(r :: Router, method :: Str, pattern :: Str, body :: rt.HandlerBody, validator :: Option[v.Validator], meta :: RouteMeta) -> Router {
  let rec := { method: str.to_upper(method), pattern: pattern, segments: split_path(pattern), body: body, validator: validator, meta: meta }
  let new_routes := list.concat(r.routes, [rec])
  { routes: new_routes, middleware: r.middleware, trie: compile_trie(new_routes) }
}

# ---- Metadata attachment -----------------------------------------
fn attach_meta(r :: Router, method :: Str, pattern :: Str, meta :: RouteMeta) -> Router {
  let m := str.to_upper(method)
  let updated := list.map(r.routes, fn (rec :: RouteRecord) -> RouteRecord {
    if rec.method == m and rec.pattern == pattern {
      { method: rec.method, pattern: rec.pattern, segments: rec.segments, body: rec.body, validator: rec.validator, meta: meta }
    } else {
      rec
    }
  })
  { routes: updated, middleware: r.middleware, trie: r.trie }
}

fn route_with_meta(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> resp.Response, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HPure(handler), None, meta)
}

fn route_effectful_with_meta(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net] resp.Response, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HEff(handler), None, meta)
}

fn handler_json_with_meta(r :: Router, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> resp.Response, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HPure(handler), Some(validator), meta)
}

fn handler_json_effectful_with_meta(r :: Router, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net] resp.Response, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HEff(handler), Some(validator), meta)
}

# ---- Dispatch ----------------------------------------------------
# dispatch carries the union effect row of any HEff handler plus
# the middleware stack's [io, time, crypto, random]. HPure routes
# under this dispatcher pay the wider effect row in the call site's
# declaration but don't actually invoke the wider effects.
fn dispatch(r :: Router, req :: ctx.RawRequest) -> [io, time, crypto, random, sql, fs_read, fs_write, net] resp.Response {
  let method := str.to_upper(req.method)
  let path_segs := split_path(req.path)
  match rt.lookup(r.trie, method, path_segs) {
    None => resp.not_found(),
    Some(matched) => {
      let body := match matched {
        (b, _) => b,
      }
      let params := match matched {
        (_, p) => p,
      }
      run_with_middleware_h(r.middleware, body, ctx.from_request(req, params))
    },
  }
}

# Pure dispatcher: honours only HPure routes. HEff routes return
# a synthetic 500 — tests that need effectful handlers should run
# under dispatch + the appropriate --allow-effects gate.
fn dispatch_pure(r :: Router, req :: ctx.RawRequest) -> resp.Response {
  let method := str.to_upper(req.method)
  let path_segs := split_path(req.path)
  match rt.lookup(r.trie, method, path_segs) {
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
        HPure(h) => h(c),
        HEff(_) => resp.internal_error(),
      }
    },
  }
}

# Legacy list.fold dispatcher kept alongside the trie-based `dispatch`
# for the bench/servers/lex_web_bench_many_listfold.lex A/B variant.
# Behaviourally identical (modulo the trie's literal-first specificity);
# the only difference is route lookup cost (O(N × M) here vs O(M) via
# the trie). Not used by sub_router / openapi / the public README
# examples — those go through dispatch.
fn dispatch_listfold(r :: Router, req :: ctx.RawRequest) -> [io, time, crypto, random, sql, fs_read, fs_write, net] resp.Response {
  let method := str.to_upper(req.method)
  let path_segs := split_path(req.path)
  match find_match(r.routes, method, path_segs) {
    None => resp.not_found(),
    Some(matched) => {
      let record := match matched {
        (rec, _) => rec,
      }
      let params := match matched {
        (_, p) => p,
      }
      run_with_middleware(r.middleware, record, ctx.from_request(req, params))
    },
  }
}

fn run_with_middleware(mws :: List[mw.MiddlewareKind], record :: RouteRecord, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net] resp.Response {
  run_with_middleware_h(mws, record.body, c)
}

# Trie-driven dispatch path: we only have the body variant, not
# the full RouteRecord. run_with_middleware_h is the workhorse;
# run_with_middleware stays as a thin shim for the list.fold path.
fn run_with_middleware_h(mws :: List[mw.MiddlewareKind], body :: rt.HandlerBody, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net] resp.Response {
  match mw.run_pre(mws, c) {
    Short(early) => mw.run_post(mws, c, early),
    Continue(c2) => {
      let raw_resp := match body {
        HPure(h) => h(c2),
        HEff(h) => h(c2),
      }
      mw.run_post(mws, c2, raw_resp)
    },
  }
}

# ---- Route matching ----------------------------------------------
fn find_match(routes :: List[RouteRecord], method :: Str, path_segs :: List[Str]) -> Option[(RouteRecord, Map[Str, Str])] {
  list.fold(routes, None, fn (acc :: Option[(RouteRecord, Map[Str, Str])], rec :: RouteRecord) -> Option[(RouteRecord, Map[Str, Str])] {
    match acc {
      Some(_) => acc,
      None => if rec.method != method {
        None
      } else {
        match match_segments(rec.segments, path_segs, map.new()) {
          None => None,
          Some(params) => Some((rec, params)),
        }
      },
    }
  })
}

fn match_segments(pattern :: List[Str], actual :: List[Str], params :: Map[Str, Str]) -> Option[Map[Str, Str]] {
  match list.head(pattern) {
    None => if list.len(actual) == 0 {
      Some(params)
    } else {
      None
    },
    Some(p_seg) => {
      let rest_p := list.tail(pattern)
      if str.starts_with(p_seg, "*") {
        let name := str.slice(p_seg, 1, str.len(p_seg))
        let rest_str := str.join(actual, "/")
        Some(map.set(params, name, rest_str))
      } else {
        match list.head(actual) {
          None => None,
          Some(a_seg) => {
            let rest_a := list.tail(actual)
            if str.starts_with(p_seg, ":") {
              let name := str.slice(p_seg, 1, str.len(p_seg))
              match_segments(rest_p, rest_a, map.set(params, name, a_seg))
            } else {
              if p_seg == a_seg {
                match_segments(rest_p, rest_a, params)
              } else {
                None
              }
            }
          },
        }
      }
    },
  }
}

fn split_path(path :: Str) -> List[Str] {
  list.filter(str.split(path, "/"), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
}

