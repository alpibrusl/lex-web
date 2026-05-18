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
#     fs_write, net, concurrent] Response handler. Use these when
#     the handler needs to query a database, read a file, call out,
#     drive a `conc.tell` to a registered actor (e.g. the WS
#     outbound bridge from lex-lang 0.9.5's `serve_ws_fn_actor`),
#     or otherwise do anything beyond consuming the Ctx. The effect
#     row is fixed-and-wide because Lex 0.9.4+ doesn't support
#     effect-row variables on closures stored in record fields;
#     narrow the body, not the declaration.
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

import "lex-schema/json_value" as jv

import "./stream" as stream

# ---- Per-route metadata -----------------------------------------
# Optional descriptors that ride along on each route. The router
# never inspects them; they exist for openapi.export_openapi (and
# any future introspection tool).
#
#   tags           — OpenAPI tags for grouping in Swagger UI
#   summary        — short title shown in the operation list
#   description    — long-form Markdown for the operation
#   status         — default success status (0 = leave unset, use 200)
#   response_model — optional lex-schema Validator applied to the
#                    handler's response body before sending (#28).
#                    Validates the JSON conforms to the schema AND
#                    strips fields not declared in the schema — the
#                    "filter internal fields like password_hash from
#                    a User response" pattern FastAPI's
#                    `response_model=` exposes. On validation
#                    failure the framework replaces the response with
#                    a 500. None = no response-side processing.
type RouteMeta = { tags :: List[Str], summary :: Str, description :: Str, status :: Int, response_model :: Option[v.Validator] }

fn empty_meta() -> RouteMeta {
  { tags: [], summary: "", description: "", status: 0, response_model: None }
}

# Convenience builder for the common "I just want a response_model"
# case. `meta.empty_meta() |> with_response_model(v)` keeps the
# `attach_meta(...)` call site one line.
fn with_response_model(m :: RouteMeta, validator :: v.Validator) -> RouteMeta {
  { tags: m.tags, summary: m.summary, description: m.description, status: m.status, response_model: Some(validator) }
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
  add_record(r, method, pattern, HPure(handler, None), None, empty_meta())
}

# Register an effectful handler. Handler must declare its effects
# from the fixed-wide set [io, time, crypto, random, sql, fs_read,
# fs_write, net, concurrent]. Narrow the handler *body*, not the
# declaration. `concurrent` is in the set so handlers can drive
# the WS outbound bridge actors registered by serve_ws_fn_actor
# (lex-lang 0.9.5) via conc.lookup + conc.tell.
fn route_effectful(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response) -> Router {
  add_record(r, method, pattern, HEff(handler, None), None, empty_meta())
}

# Register a pure route with an attached lex-schema Validator. The
# validator is used at runtime by body.json_body() and at startup by
# openapi.export_openapi() to emit request-body schemas.
fn handler_json(r :: Router, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> resp.Response) -> Router {
  add_record(r, method, pattern, HPure(handler, None), Some(validator), empty_meta())
}

# Effectful variant of handler_json.
fn handler_json_effectful(r :: Router, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response) -> Router {
  add_record(r, method, pattern, HEff(handler, None), Some(validator), empty_meta())
}

# Register a streaming handler (#29). Handler returns a
# `stream.StreamResponse` whose body is a lazy `Iter[Str]`; the
# router threads it through `dispatch_outcome` and the calling
# bridge wraps it in `BodyStream(...)` for `net.serve_fn`.
#
# Plain `dispatch` (and `dispatch_pure`) don't support streaming
# routes — they 500 with a clear hint. Use `dispatch_outcome` in
# your `main` bridge to pick up streaming routes.
#
# Streaming routes inherit the same wide HEff effect row as
# `route_effectful` so handlers can pull from a database, an
# actor, or the file system to source chunks. Narrow the body,
# not the type.
fn route_stream(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] stream.StreamResponse) -> Router {
  add_record(r, method, pattern, HStream(handler, None), None, empty_meta())
}

# Streaming + RouteMeta. Use when you want OpenAPI metadata
# (tags / summary / description) on a stream route. response_model
# is accepted for symmetry but NOT enforced on stream routes in
# v1 — see route_trie.lex for the rationale.
fn route_stream_with_meta(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] stream.StreamResponse, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HStream(handler, meta.response_model), None, meta)
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
# Update the meta for an existing route. Also re-bundles
# `meta.response_model` into the route's HandlerBody so the trie
# (which dispatch consults on the hot path) stays in sync, then
# rebuilds the trie from the updated record list.
fn attach_meta(r :: Router, method :: Str, pattern :: Str, meta :: RouteMeta) -> Router {
  let m := str.to_upper(method)
  let updated := list.map(r.routes, fn (rec :: RouteRecord) -> RouteRecord {
    if rec.method == m and rec.pattern == pattern {
      let new_body := match rec.body {
        HPure(h, _) => HPure(h, meta.response_model),
        HEff(h, _) => HEff(h, meta.response_model),
        HStream(h, _) => HStream(h, meta.response_model),
      }
      { method: rec.method, pattern: rec.pattern, segments: rec.segments, body: new_body, validator: rec.validator, meta: meta }
    } else {
      rec
    }
  })
  { routes: updated, middleware: r.middleware, trie: compile_trie(updated) }
}

fn route_with_meta(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> resp.Response, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HPure(handler, meta.response_model), None, meta)
}

fn route_effectful_with_meta(r :: Router, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HEff(handler, meta.response_model), None, meta)
}

fn handler_json_with_meta(r :: Router, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> resp.Response, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HPure(handler, meta.response_model), Some(validator), meta)
}

fn handler_json_effectful_with_meta(r :: Router, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response, meta :: RouteMeta) -> Router {
  add_record(r, method, pattern, HEff(handler, meta.response_model), Some(validator), meta)
}

# ---- Dispatch ----------------------------------------------------
# dispatch carries the union effect row of any HEff handler plus
# the middleware stack's [io, time, crypto, random]. HPure routes
# under this dispatcher pay the wider effect row in the call site's
# declaration but don't actually invoke the wider effects.
fn dispatch(r :: Router, req :: ctx.RawRequest) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
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
        HPure(h, rm) => apply_response_model(h(c), rm),
        HEff(_, _) => resp.with_ct(500, "lex-web: this route was registered via route_effectful and cannot be invoked from dispatch_pure. Use dispatch with --allow-effects, or restrict the route to a pure handler.", "text/plain"),
        HStream(_, _) => resp.with_ct(500, "lex-web: this route was registered via route_stream and cannot be invoked from dispatch_pure. Use dispatch_outcome and match DStream in your main bridge.", "text/plain"),
      }
    },
  }
}

# ---- dispatch_outcome (#29) --------------------------------------
#
# Stream-aware dispatcher. Returns `DispatchOutcome` — a sum that
# encodes both the plain `resp.Response` case and the streaming
# `stream.StreamResponse` case so callers' `main` bridge can pick
# the right `BodyStr` / `BodyStream` wrapping for `net.serve_fn`:
#
#   fn handle(req :: Request) -> [HEff] Response {
#     let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
#     match router.dispatch_outcome(app(), raw) {
#       DPlain(r)  => { status: r.status, body: BodyStr(r.body),    headers: r.headers },
#       DStream(s) => { status: s.status, body: BodyStream(s.body), headers: s.headers },
#     }
#   }
#
# `dispatch` continues to be the right call when an app has no
# streaming routes — its return type is simpler. Mix-and-match
# apps want `dispatch_outcome`.
type DispatchOutcome = DPlain(resp.Response) | DStream(stream.StreamResponse)

fn dispatch_outcome(r :: Router, req :: ctx.RawRequest) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] DispatchOutcome {
  let method := str.to_upper(req.method)
  let path_segs := split_path(req.path)
  match rt.lookup(r.trie, method, path_segs) {
    None => DPlain(resp.not_found()),
    Some(matched) => {
      let body := match matched {
        (b, _) => b,
      }
      let params := match matched {
        (_, p) => p,
      }
      let c := ctx.from_request(req, params)
      run_with_middleware_outcome(r.middleware, body, c)
    },
  }
}

# Workhorse for `dispatch_outcome`. Pre-middleware runs over Ctx;
# if it short-circuits with a Response we return DPlain(...) (a
# 401 short-circuit can't produce a stream). On Continue, plain
# handlers go through `run_with_middleware_h`'s post chain; stream
# handlers thread the stream through `run_post_stream` — which
# applies post-middleware to a STUB response carrying just status
# + headers, then merges the mutated status/headers back into the
# stream. Body-mutating middleware (gzip annotation, request-id,
# CORS) all work on the stub; body itself passes through untouched.
fn run_with_middleware_outcome(mws :: List[mw.MiddlewareKind], body :: rt.HandlerBody, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] DispatchOutcome {
  match mw.run_pre(mws, c) {
    Short(early) => DPlain(mw.run_post(mws, c, early)),
    Continue(c2) => match body {
      HPure(h, rm) => DPlain(mw.run_post(mws, c2, apply_response_model(h(c2), rm))),
      HEff(h, rm) => DPlain(mw.run_post(mws, c2, apply_response_model(h(c2), rm))),
      HStream(h, _) => {
        let sr := h(c2)
        let stub := { body: "", status: sr.status, headers: sr.headers }
        let processed := mw.run_post(mws, c2, stub)
        DStream({ body: sr.body, status: processed.status, headers: processed.headers })
      },
    },
  }
}

# Legacy list.fold dispatcher kept alongside the trie-based `dispatch`
# for the bench/servers/lex_web_bench_many_listfold.lex A/B variant.
# Behaviourally identical (modulo the trie's literal-first specificity);
# the only difference is route lookup cost (O(N × M) here vs O(M) via
# the trie). Not used by sub_router / openapi / the public README
# examples — those go through dispatch.
fn dispatch_listfold(r :: Router, req :: ctx.RawRequest) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
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

fn run_with_middleware(mws :: List[mw.MiddlewareKind], record :: RouteRecord, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  run_with_middleware_h(mws, record.body, c)
}

# Trie-driven dispatch path: we only have the body variant, not
# the full RouteRecord. run_with_middleware_h is the workhorse;
# run_with_middleware stays as a thin shim for the list.fold path.
#
# Response-model post-processing (#28) runs between the handler
# and `run_post` — so post-middleware sees the validated/filtered
# body, not the raw handler output. A short-circuiting pre-middleware
# return skips the handler AND the response_model step (there's no
# handler-output to validate); that matches "the gate fired, what
# the handler would have returned is irrelevant".
fn run_with_middleware_h(mws :: List[mw.MiddlewareKind], body :: rt.HandlerBody, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match mw.run_pre(mws, c) {
    Short(early) => mw.run_post(mws, c, early),
    Continue(c2) => {
      let raw_resp := match body {
        HPure(h, rm) => apply_response_model(h(c2), rm),
        HEff(h, rm) => apply_response_model(h(c2), rm),
        HStream(_, _) => resp.with_ct(500, "lex-web: this route was registered via route_stream. Use dispatch_outcome and match DStream in your main bridge.", "text/plain"),
      }
      mw.run_post(mws, c2, raw_resp)
    },
  }
}

# Response-model post-processor (#28). For routes registered with
# `route_with_meta(..., empty_meta() |> with_response_model(v))`,
# project the handler's response body through `v.serialize`:
#   - parses the body as JSON
#   - runs the schema validator (rejects missing required fields,
#     bad types, etc.)
#   - re-stringifies, silently dropping any fields not declared on
#     the schema — the "strip password_hash from a User response"
#     filtering behaviour FastAPI's response_model= exposes
# On validation failure the response is replaced with a 500 carrying
# the structured error list as JSON. The post-middleware chain
# (logger, CORS, request-id, etc.) runs over the *replaced* response,
# matching the standard "framework owns the 500 shape" contract.
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

