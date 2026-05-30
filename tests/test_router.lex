# Tests for src/router.lex — route matching and dispatch_pure.

import "std.list" as list

import "std.str" as str

import "std.map" as map

import "std.iter" as iter

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/middleware" as mw

import "../src/stream" as strm

import "../src/test_fixtures" as fx

import "../src/testing" as t

# ---- Shared fixtures --------------------------------------------
fn echo_path(c :: ctx.Ctx) -> resp.Response {
  resp.text(c.path)
}

fn echo_param(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "id") {
    Some(id) => resp.text(id),
    None => resp.bad_request("no id"),
  }
}

fn echo_splat(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "rest") {
    Some(s) => resp.text(s),
    None => resp.bad_request("no rest"),
  }
}

fn echo_two_params(c :: ctx.Ctx) -> resp.Response {
  let org := match ctx.path_param(c, "org") {
    Some(s) => s,
    None => "",
  }
  let uid := match ctx.path_param(c, "user") {
    Some(s) => s,
    None => "",
  }
  resp.text(str.concat(org, str.concat("/", uid)))
}

fn simple_router() -> router.Router {
  ((((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/health", echo_path)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users/:id", echo_param)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "POST", "/users", echo_path)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/files/*rest", echo_splat)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/orgs/:org/users/:user", echo_two_params)
  }
}

# ---- Tests -------------------------------------------------------
fn static_route_matches() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.get("/health"))
  t.assert_status(resp, 200)
}

fn static_route_not_found() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.get("/missing"))
  t.assert_status(resp, 404)
}

fn param_route_matches_and_binds() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.get("/users/42"))
  t.all([t.assert_status(resp, 200), t.assert_body_eq(resp, "42")])
}

fn param_does_not_match_empty_segment() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.get("/users/"))
  t.assert_status(resp, 404)
}

fn method_mismatch_gives_404() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.get("/users"))
  t.assert_status(resp, 404)
}

fn post_matches_own_method() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.post("/users", ""))
  t.assert_status(resp, 200)
}

fn splat_captures_single_segment() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.get("/files/readme.txt"))
  t.all([t.assert_status(resp, 200), t.assert_body_eq(resp, "readme.txt")])
}

fn splat_captures_multiple_segments() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.get("/files/a/b/c.txt"))
  t.all([t.assert_status(resp, 200), t.assert_body_eq(resp, "a/b/c.txt")])
}

fn two_params_both_bound() -> Result[Unit, Str] {
  let resp := router.dispatch_pure(simple_router(), t.get("/orgs/acme/users/alice"))
  t.all([t.assert_status(resp, 200), t.assert_body_eq(resp, "acme/alice")])
}

fn literal_always_beats_param() -> Result[Unit, Str] {
  let r := (router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/items/:id", fn (c :: ctx.Ctx) -> resp.Response {
      resp.text("param")
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/items/special", fn (c :: ctx.Ctx) -> resp.Response {
      resp.text("static")
    })
  }
  let resp := router.dispatch_pure(r, t.get("/items/special"))
  t.assert_body_eq(resp, "static")
}

fn static_before_param_wins() -> Result[Unit, Str] {
  let r := (router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/items/special", fn (c :: ctx.Ctx) -> resp.Response {
      resp.text("static")
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/items/:id", fn (c :: ctx.Ctx) -> resp.Response {
      resp.text("param")
    })
  }
  let resp := router.dispatch_pure(r, t.get("/items/special"))
  t.assert_body_eq(resp, "static")
}

fn method_is_case_insensitive() -> Result[Unit, Str] {
  let r := router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "get", "/ping", fn (c :: ctx.Ctx) -> resp.Response {
      resp.text("pong")
    })
  }
  let resp := router.dispatch_pure(r, t.get("/ping"))
  t.assert_body_eq(resp, "pong")
}

fn param_name_conflict_first_registered_wins() -> Result[Unit, Str] {
  let r := (router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users/:id", echo_param)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users/:name/profile", fn (c :: ctx.Ctx) -> resp.Response {
      match ctx.path_param(c, "id") {
        Some(s) => resp.text(s),
        None => resp.text("missing-id"),
      }
    })
  }
  let r1 := router.dispatch_pure(r, t.get("/users/abc"))
  let r2 := router.dispatch_pure(r, t.get("/users/abc/profile"))
  t.all([t.assert_body_eq(r1, "abc"), t.assert_body_eq(r2, "abc")])
}

fn literal_falls_back_to_param_on_dead_end() -> Result[Unit, Str] {
  let r := (router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users/admin", fn (c :: ctx.Ctx) -> resp.Response {
      resp.text("admin-home")
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users/:id/profile", fn (c :: ctx.Ctx) -> resp.Response {
      match ctx.path_param(c, "id") {
        Some(s) => resp.text(str.concat(s, "-profile")),
        None => resp.text("missing-id"),
      }
    })
  }
  t.all([t.assert_body_eq(router.dispatch_pure(r, t.get("/users/admin")), "admin-home"), t.assert_body_eq(router.dispatch_pure(r, t.get("/users/admin/profile")), "admin-profile")])
}

# ---- RouteMeta.response_model (#28) ------------------------------
# `fx.item_validator()` is `{ name :: Str (non-empty), qty :: Int (positive) }`.
# Handler returns a body conforming to the schema PLUS extra fields
# (`internal_id`, `secret`). The framework should validate against
# the schema (success) and project the body down to just the
# declared fields — `internal_id` and `secret` should NOT appear
# in the wire response.
fn handler_with_extras(_c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"name\":\"widget\",\"qty\":5,\"internal_id\":\"sku-001\",\"secret\":\"do-not-leak\"}")
}

# Handler returns a body that's MISSING the `qty` required field —
# the framework should reject this with a 500 because the handler's
# output doesn't conform to the declared response model.
fn handler_missing_field(_c :: ctx.Ctx) -> resp.Response {
  resp.json("{\"name\":\"widget\"}")
}

fn handler_garbage(_c :: ctx.Ctx) -> resp.Response {
  resp.json("not even json")
}

fn router_with_response_model(handler :: (ctx.Ctx) -> resp.Response) -> router.Router {
  let meta := router.with_response_model(router.empty_meta(), fx.item_validator())
  router.route_with_meta(router.new(), "GET", "/item", handler, meta)
}

fn response_model_filters_unknown_fields() -> Result[Unit, Str] {
  let r := router_with_response_model(handler_with_extras)
  let out := router.dispatch_pure(r, t.get("/item"))
  if str.contains(out.body, "\"name\":\"widget\"") and str.contains(out.body, "\"qty\":5") and not str.contains(out.body, "internal_id") and not str.contains(out.body, "secret") {
    Ok(())
  } else {
    Err(str.concat("expected filtered body without internal_id/secret, got: ", out.body))
  }
}

fn response_model_500s_on_missing_required_field() -> Result[Unit, Str] {
  let r := router_with_response_model(handler_missing_field)
  let out := router.dispatch_pure(r, t.get("/item"))
  t.assert_status(out, 500)
}

fn response_model_500s_on_unparseable_body() -> Result[Unit, Str] {
  let r := router_with_response_model(handler_garbage)
  let out := router.dispatch_pure(r, t.get("/item"))
  t.assert_status(out, 500)
}

# Without response_model, the body passes through unchanged —
# extra fields stay, malformed JSON is the handler's problem,
# not the framework's.
fn no_response_model_means_passthrough() -> Result[Unit, Str] {
  let r := router.route(router.new(), "GET", "/item", handler_with_extras)
  let out := router.dispatch_pure(r, t.get("/item"))
  if str.contains(out.body, "internal_id") and str.contains(out.body, "secret") {
    Ok(())
  } else {
    Err(str.concat("expected raw passthrough including extras, got: ", out.body))
  }
}

# ---- route_stream / dispatch_outcome (#29) -----------------------
#
# Streaming handlers return a `stream.StreamResponse` whose body
# is a lazy `Iter[Str]`. The router routes them through
# `dispatch_outcome` which returns `DispatchOutcome` —
# `DPlain(Response)` for HPure/HEff routes, `DStream(StreamResponse)`
# for HStream routes. The caller's bridge matches the outcome and
# picks the right `BodyStr` / `BodyStream` wrapping for net.serve_fn.
fn tick_stream(_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] strm.StreamResponse {
  let frames := list.map(list.range(0, 3), fn (n :: Int) -> Str {
    strm.sse_event(str.concat("tick-", str.concat(str.to_lower("X"), "")))
  })
  strm.event_stream(iter.from_list(frames))
}

fn plain_handler(_c :: ctx.Ctx) -> resp.Response {
  resp.text("hello")
}

fn stream_router() -> router.Router {
  (router.new() |> fn (r :: router.Router) -> router.Router {
    router.route_stream(r, "GET", "/events", tick_stream)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/plain", plain_handler)
  }
}

fn dispatch_outcome_routes_stream_to_dstream() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match router.dispatch_outcome(stream_router(), t.get("/events")) {
    DStream(sr) => if sr.status == 200 {
      Ok(())
    } else {
      Err(str.concat("expected status 200 on stream, got ", str.to_lower("?")))
    },
    DPlain(_) => Err("expected DStream for a route_stream-registered handler"),
  }
}

fn dispatch_outcome_routes_plain_to_dplain() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match router.dispatch_outcome(stream_router(), t.get("/plain")) {
    DPlain(r) => t.assert_body_eq(r, "hello"),
    DStream(_) => Err("expected DPlain for a plain route_handler"),
  }
}

fn dispatch_outcome_unmatched_is_dplain_404() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match router.dispatch_outcome(stream_router(), t.get("/missing")) {
    DPlain(r) => t.assert_status(r, 404),
    DStream(_) => Err("expected DPlain(404) for an unmatched path"),
  }
}

# `dispatch` (the plain dispatcher) 500s on HStream routes with a
# clear hint pointing callers at `dispatch_outcome`. This is the
# fall-back behaviour; mixed apps should use dispatch_outcome.
fn legacy_dispatch_500s_on_stream_route() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let out := router.dispatch(stream_router(), t.get("/events"))
  if out.status == 500 and str.contains(out.body, "dispatch_outcome") {
    Ok(())
  } else {
    Err(str.concat("expected 500 + dispatch_outcome hint, got: ", out.body))
  }
}

# Post-handler middleware mutates the stream's status/headers via
# the stub-response shim; the body iterator passes through
# untouched. MwRequestId stamps `x-request-id` on the response,
# which means stream responses also get the trace ID.
fn stream_post_middleware_stamps_headers() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let r := (router.new() |> fn (rr :: router.Router) -> router.Router {
    router.use_mw(rr, mw.request_id())
  }) |> fn (rr :: router.Router) -> router.Router {
    router.route_stream(rr, "GET", "/events", tick_stream)
  }
  match router.dispatch_outcome(r, t.get("/events")) {
    DStream(sr) => match map.get(sr.headers, "x-request-id") {
      Some(_) => Ok(()),
      None => Err("expected MwRequestId to stamp x-request-id on the stream response"),
    },
    DPlain(_) => Err("expected DStream for /events"),
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] List[Result[Unit, Str]] {
  [static_route_matches(), static_route_not_found(), param_route_matches_and_binds(), param_does_not_match_empty_segment(), method_mismatch_gives_404(), post_matches_own_method(), splat_captures_single_segment(), splat_captures_multiple_segments(), two_params_both_bound(), literal_always_beats_param(), static_before_param_wins(), method_is_case_insensitive(), param_name_conflict_first_registered_wins(), literal_falls_back_to_param_on_dead_end(), response_model_filters_unknown_fields(), response_model_500s_on_missing_required_field(), response_model_500s_on_unparseable_body(), no_response_model_means_passthrough(), dispatch_outcome_routes_stream_to_dstream(), dispatch_outcome_routes_plain_to_dplain(), dispatch_outcome_unmatched_is_dplain_404(), legacy_dispatch_500s_on_stream_route(), stream_post_middleware_stamps_headers()]
}

# `lex test` calls run_all and reports the file as failed iff run_all
# panics. We fold the suite into a failure count and force a panic
# (`1 / 0`) when any case failed; the failed Err(_) messages are not
# surfaced today — `lex test` only reports the panic site — but the
# panic correctly fails the run.
fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __lex_discard_1 := 1 / 0
    ()
  }
}

