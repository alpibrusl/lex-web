# lex-web — route table and dispatcher
#
# v0.2 keeps the v0.1 surface (new / route / handler_json / use_mw /
# dispatch / dispatch_pure) and adds two FastAPI-style features:
#
#   1. RouteMeta — per-route tags, summary, description, default
#      success status. Used by openapi.export_openapi to enrich
#      operation objects; `attach_meta` is also called by sub_router
#      when mounting a grouped router.
#   2. The lookup itself is unchanged: a flat List[RouteRecord]
#      scanned in registration order. A trie keyed on path segments
#      will replace this in v0.3 for applications with large route
#      counts; the public surface stays stable.
#
# Path pattern syntax:
#   /users/:id        — `:name` binds one non-empty segment
#   /files/*rest      — `*name` binds all remaining segments
#
# Middleware is stored as a List[MiddlewareKind] applied in
# registration order at every dispatch. See middleware.lex for
# the available kinds.
#
# Effects: dispatch is [io, time] when the middleware stack
# includes MwLogger / MwRequestId. dispatch_pure is effect-free.

import "std.str"  as str
import "std.list" as list
import "std.map"  as map
import "std.io"   as io

import "./ctx"        as ctx
import "./response"   as resp
import "./middleware" as mw

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
type RouteMeta = {
  tags        :: List[Str],
  summary     :: Str,
  description :: Str,
  status      :: Int,
}

fn empty_meta() -> RouteMeta {
  { tags: [], summary: "", description: "", status: 0 }
}

# ---- Types -------------------------------------------------------

type RouteRecord = {
  method    :: Str,
  pattern   :: Str,
  segments  :: List[Str],
  handler   :: (ctx.Ctx) -> resp.Response,
  validator :: Option[v.Validator],
  meta      :: RouteMeta,
}

type Router = {
  routes     :: List[RouteRecord],
  middleware :: List[mw.MiddlewareKind],
}

# ---- Construction ------------------------------------------------

fn new() -> Router { { routes: [], middleware: [] } }

fn route(
  r       :: Router,
  method  :: Str,
  pattern :: Str,
  handler :: (ctx.Ctx) -> resp.Response
) -> Router {
  add_record(r, method, pattern, handler, None, empty_meta())
}

# Register a route with an attached lex-schema Validator.
# The validator is used at runtime by body.json_body() and at
# startup by openapi.export_openapi() to emit request-body schemas.
fn handler_json(
  r         :: Router,
  method    :: Str,
  pattern   :: Str,
  validator :: v.Validator,
  handler   :: (ctx.Ctx) -> resp.Response
) -> Router {
  add_record(r, method, pattern, handler, Some(validator), empty_meta())
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
  handler   :: (ctx.Ctx) -> resp.Response,
  validator :: Option[v.Validator],
  meta      :: RouteMeta
) -> Router {
  let rec := {
    method:    str.to_upper(method),
    pattern:   pattern,
    segments:  split_path(pattern),
    handler:   handler,
    validator: validator,
    meta:      meta,
  }
  { routes: list.concat(r.routes, [rec]), middleware: r.middleware }
}

# ---- Metadata attachment -----------------------------------------

# Replace the metadata of the route with the given (method, pattern).
# Used by sub_router.mount; useful directly when annotating a route
# after registration.
#
#   router.attach_meta(r, "POST", "/users",
#     { tags: ["users"], summary: "Create user",
#       description: "", status: 201 })
fn attach_meta(
  r       :: Router,
  method  :: Str,
  pattern :: Str,
  meta    :: RouteMeta
) -> Router {
  let m := str.to_upper(method)
  let updated := list.map(r.routes,
    fn (rec :: RouteRecord) -> RouteRecord {
      if rec.method == m and rec.pattern == pattern {
        { method: rec.method, pattern: rec.pattern, segments: rec.segments,
          handler: rec.handler, validator: rec.validator, meta: meta }
      } else { rec }
    })
  { routes: updated, middleware: r.middleware }
}

# Convenience: register + attach in one call.
fn route_with_meta(
  r       :: Router,
  method  :: Str,
  pattern :: Str,
  handler :: (ctx.Ctx) -> resp.Response,
  meta    :: RouteMeta
) -> Router {
  add_record(r, method, pattern, handler, None, meta)
}

fn handler_json_with_meta(
  r         :: Router,
  method    :: Str,
  pattern   :: Str,
  validator :: v.Validator,
  handler   :: (ctx.Ctx) -> resp.Response,
  meta      :: RouteMeta
) -> Router {
  add_record(r, method, pattern, handler, Some(validator), meta)
}

# ---- Dispatch ----------------------------------------------------

# Full dispatch: runs the middleware stack. Effect is [io, time] due
# to MwLogger writing to stdout and MwRequestId reading the clock.
# Use dispatch_pure in tests.
fn dispatch(r :: Router, req :: ctx.RawRequest) -> [io, time] resp.Response {
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
) -> [io, time] resp.Response {
  match mw.run_pre(mws, c) {
    Short(early) => mw.run_post(mws, c, early),
    Continue(c2) => {
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
