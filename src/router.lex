# lex-web — route table and dispatcher
#
# v0.1 uses a flat List[RouteRecord] scanned in registration order.
# A trie keyed on path segments will replace this in v0.2 for
# applications with large route counts; the public surface
# (new / route / handler_json / use_mw / dispatch) is stable.
#
# Path pattern syntax:
#   /users/:id        — `:name` binds one non-empty segment
#   /files/*rest      — `*name` binds all remaining segments
#
# Middleware is stored as a List[MiddlewareKind] applied in
# registration order at every dispatch. See middleware.lex for
# the available kinds.
#
# Effects: dispatch is [io] when the middleware stack includes
# MwLogger. dispatch_pure is effect-free and intended for tests.

import "std.str"  as str
import "std.list" as list
import "std.map"  as map
import "std.io"   as io

import "./ctx"        as ctx
import "./response"   as resp
import "./middleware" as mw

import "lex-schema/validator" as v

# ---- Types -------------------------------------------------------

type RouteRecord = {
  method    :: Str,
  pattern   :: Str,
  segments  :: List[Str],
  handler   :: Fn(ctx.Ctx) -> resp.Response,
  validator :: Option[v.Validator],
}

type Router = {
  routes:     List[RouteRecord],
  middleware: List[mw.MiddlewareKind],
}

# ---- Construction ------------------------------------------------

fn new() -> Router { { routes: [], middleware: [] } }

fn route(
  r       :: Router,
  method  :: Str,
  pattern :: Str,
  handler :: Fn(ctx.Ctx) -> resp.Response
) -> Router {
  add_record(r, method, pattern, handler, None)
}

# Register a route with an attached lex-schema Validator.
# The validator is used at runtime by body.json_body() and at
# startup by openapi.export_openapi() to emit request-body schemas.
fn handler_json(
  r         :: Router,
  method    :: Str,
  pattern   :: Str,
  validator :: v.Validator,
  handler   :: Fn(ctx.Ctx) -> resp.Response
) -> Router {
  add_record(r, method, pattern, handler, Some(validator))
}

# Add a middleware to the stack. Middlewares run in registration
# order, outermost first (like Express `app.use`).
fn use_mw(r :: Router, kind :: mw.MiddlewareKind) -> Router {
  { routes: r.routes, middleware: list.concat(r.middleware, [kind]) }
}

fn add_record(
  r         :: Router,
  method    :: Str,
  pattern   :: Str,
  handler   :: Fn(ctx.Ctx) -> resp.Response,
  validator :: Option[v.Validator]
) -> Router {
  let rec := {
    method:    str.to_upper(method),
    pattern:   pattern,
    segments:  split_path(pattern),
    handler:   handler,
    validator: validator,
  }
  { routes: list.concat(r.routes, [rec]), middleware: r.middleware }
}

# ---- Dispatch ----------------------------------------------------

# Full dispatch: runs the middleware stack. Effect is [io] due to
# MwLogger writing to stdout. Use dispatch_pure in tests.
fn dispatch(r :: Router, req :: ctx.RawRequest) -> [io] resp.Response {
  let method    := str.to_upper(req.method)
  let path_segs := split_path(req.path)
  match find_match(r.routes, method, path_segs) {
    None          => resp.not_found(),
    Some(matched) => {
      let record := match matched { (rec, _) => rec }
      let params := match matched { (_, p)   => p   }
      run_with_middleware(
        r.middleware, record, ctx.from_request(req, params))
    },
  }
}

# Pure dispatch: skips all middleware, runs the matched handler
# directly. Intended for unit tests; not for production use.
fn dispatch_pure(r :: Router, req :: ctx.RawRequest) -> resp.Response {
  let method    := str.to_upper(req.method)
  let path_segs := split_path(req.path)
  match find_match(r.routes, method, path_segs) {
    None          => resp.not_found(),
    Some(matched) => {
      let record := match matched { (rec, _) => rec }
      let params := match matched { (_, p)   => p   }
      record.handler(ctx.from_request(req, params))
    },
  }
}

# Apply pre-middleware, run the handler, apply post-middleware.
fn run_with_middleware(
  mws    :: List[mw.MiddlewareKind],
  record :: RouteRecord,
  c      :: ctx.Ctx
) -> [io] resp.Response {
  match mw.run_pre(mws, c) {
    mw.Short(early) => mw.run_post(mws, c, early),
    mw.Continue(c2) => {
      let raw_resp := record.handler(c2)
      mw.run_post(mws, c2, raw_resp)
    },
  }
}

# ---- Route matching ----------------------------------------------

fn find_match(
  routes    :: List[RouteRecord],
  method    :: Str,
  path_segs :: List[Str]
) -> Option[(RouteRecord, Map[Str, Str])] {
  list.fold(routes, None,
    fn (
      acc :: Option[(RouteRecord, Map[Str, Str])],
      rec :: RouteRecord
    ) -> Option[(RouteRecord, Map[Str, Str])] {
      match acc {
        Some(_) => acc,
        None    =>
          if rec.method != method { None }
          else {
            match match_segments(rec.segments, path_segs, map.new()) {
              None         => None,
              Some(params) => Some((rec, params)),
            }
          },
      }
    })
}

# Recursive segment-by-segment match returning extracted path
# params on success or None on mismatch.
fn match_segments(
  pattern   :: List[Str],
  actual    :: List[Str],
  params    :: Map[Str, Str]
) -> Option[Map[Str, Str]] {
  match list.head(pattern) {
    None =>
      if list.len(actual) == 0 { Some(params) } else { None },
    Some(p_seg) => {
      let rest_p := list.tail(pattern)
      if str.starts_with(p_seg, "*") {
        let name     := str.slice(p_seg, 1, str.len(p_seg))
        let rest_str := str.join(actual, "/")
        Some(map.set(params, name, rest_str))
      } else {
        match list.head(actual) {
          None        => None,
          Some(a_seg) => {
            let rest_a := list.tail(actual)
            if str.starts_with(p_seg, ":") {
              let name := str.slice(p_seg, 1, str.len(p_seg))
              match_segments(rest_p, rest_a, map.set(params, name, a_seg))
            } else {
              if p_seg == a_seg { match_segments(rest_p, rest_a, params) }
              else { None }
            }
          },
        }
      }
    },
  }
}

# Split on "/" and drop empty strings from leading/trailing slashes.
fn split_path(path :: Str) -> List[Str] {
  list.filter(str.split(path, "/"),
    fn (s :: Str) -> Bool { not str.is_empty(s) })
}
