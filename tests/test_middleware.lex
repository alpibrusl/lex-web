# Tests for src/middleware.lex — pre/post middleware application.
#
# apply_post is [io, time, crypto, random] because MwRequestId uses time.now().
# Tests that call apply_post therefore also declare [io, time, crypto, random].
# Pure middleware (body_limit pre-phase) tests are effect-free.

import "std.list" as list

import "std.str" as str

import "std.map" as map

import "std.io" as io

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/middleware" as mw

import "../src/testing" as t

# ---- Helpers -----------------------------------------------------
fn bare_ctx(path :: Str, body :: Str) -> ctx.Ctx {
  ctx.from_request({ method: "GET", path: path, body: body, query: "", headers: map.new() }, map.new())
}

# Build via list.fold to avoid blowing lex's 1024-deep recursion limit;
# the body_limit tests pass n = 2000.
fn repeat_str(s :: Str, n :: Int) -> Str {
  str.join(list.fold(list.range(0, n), [], fn (acc :: List[Str], _i :: Int) -> List[Str] {
    list.concat(acc, [s])
  }), "")
}

# ---- body_limit --------------------------------------------------
fn body_limit_allows_small_body() -> Result[Unit, Str] {
  let c := bare_ctx("/", "hello")
  match mw.apply_pre(mw.body_limit(1024), c) {
    Continue(_) => Ok(()),
    Short(_) => Err("should not short-circuit small body"),
  }
}

fn body_limit_blocks_large_body() -> Result[Unit, Str] {
  let big := repeat_str("x", 2000)
  let c := bare_ctx("/", big)
  match mw.apply_pre(mw.body_limit(1024), c) {
    Short(r) => t.assert_status(r, 413),
    Continue(_) => Err("expected 413 short-circuit"),
  }
}

fn body_limit_exact_boundary_allowed() -> Result[Unit, Str] {
  let c := bare_ctx("/", "hello")
  match mw.apply_pre(mw.body_limit(5), c) {
    Continue(_) => Ok(()),
    Short(_) => Err("exact limit should not block"),
  }
}

fn run_pre_stops_at_first_short() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let big := repeat_str("x", 2000)
  let c := bare_ctx("/", big)
  let mws := [mw.body_limit(100), mw.body_limit(10000)]
  match mw.run_pre(mws, c) {
    Short(r) => t.assert_status(r, 413),
    Continue(_) => Err("expected short-circuit from first middleware"),
  }
}

# ---- cors --------------------------------------------------------
fn cors_adds_origin_header() -> [io, time, crypto, random] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.json("{}")
  let r2 := mw.apply_post(mw.cors(["https://example.com"]), c, r)
  t.assert_header_contains(r2, "access-control-allow-origin", "example.com")
}

fn cors_adds_methods_header() -> [io, time, crypto, random] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.json("{}")
  let r2 := mw.apply_post(mw.cors(["*"]), c, r)
  t.assert_header_present(r2, "access-control-allow-methods")
}

fn cors_preserves_existing_headers() -> [io, time, crypto, random] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.with_header(resp.json("{}"), "x-custom", "kept")
  let r2 := mw.apply_post(mw.cors(["*"]), c, r)
  t.assert_header(r2, "x-custom", "kept")
}

# ---- request_id --------------------------------------------------
fn request_id_adds_header() -> [io, time, crypto, random] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.json("{}")
  let r2 := mw.apply_post(mw.request_id(), c, r)
  t.assert_header_present(r2, "x-request-id")
}

# ---- non-matching kinds are no-ops for opposite phase -----------
fn body_limit_is_noop_in_post() -> [io, time, crypto, random] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.json("{\"original\":true}")
  let r2 := mw.apply_post(mw.body_limit(100), c, r)
  t.assert_body_eq(r2, "{\"original\":true}")
}

fn cors_is_noop_in_pre() -> Result[Unit, Str] {
  let c := bare_ctx("/", "small")
  match mw.apply_pre(mw.cors(["*"]), c) {
    Continue(_) => Ok(()),
    Short(_) => Err("cors should not short-circuit in pre"),
  }
}

# ---- MwCustom (#27) ----------------------------------------------
# Convenience builders so each test below stays one screen.
fn noop_before(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] mw.PreResult {
  Continue(c)
}

fn noop_after(_c :: ctx.Ctx, r :: resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  r
}

# Before-hook short-circuits with a Response — `run_pre` returns
# Short(...) and the matched handler is never reached.
fn custom_before_can_short_circuit() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := bare_ctx("/admin", "")
  let mws := [mw.custom("require-token", fn (cc :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] mw.PreResult {
    Short(resp.unauthorized("missing token"))
  }, noop_after)]
  match mw.run_pre(mws, c) {
    Short(r) => t.assert_status(r, 401),
    Continue(_) => Err("expected MwCustom.before to short-circuit"),
  }
}

# Before-hook returning Continue(ctx) leaves the request flowing
# through to the handler; chained Custom middlewares run in order.
fn custom_before_continue_passes_through() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := bare_ctx("/public", "")
  let mws := [mw.custom("tracer", noop_before, noop_after)]
  match mw.run_pre(mws, c) {
    Continue(_) => Ok(()),
    Short(_) => Err("noop MwCustom.before should not short-circuit"),
  }
}

# After-hook can mutate the response (header stamp here; the same
# shape works for status, body, anything `resp.with_*` exposes).
fn custom_after_can_mutate_response() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := { body: "ok", status: 200, headers: map.new() }
  let mws := [mw.custom("stamp", noop_before, fn (_cc :: ctx.Ctx, rr :: resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
    resp.with_header(rr, "x-custom-mw", "ran")
  })]
  let out := mw.run_post(mws, c, r)
  match map.get(out.headers, "x-custom-mw") {
    Some(v) => if v == "ran" {
      Ok(())
    } else {
      Err(str.concat("unexpected header value: ", v))
    },
    None => Err("MwCustom.after did not stamp the header"),
  }
}

# Built-in and MwCustom middlewares compose in the same stack —
# this test mixes MwRequestId (post-stamps x-request-id) with a
# user middleware that stamps x-trace, and asserts both fire.
fn custom_composes_with_builtin() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := { body: "ok", status: 200, headers: map.new() }
  let mws := [mw.request_id(), mw.custom("trace", noop_before, fn (_cc :: ctx.Ctx, rr :: resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
    resp.with_header(rr, "x-trace", "abc123")
  })]
  let out := mw.run_post(mws, c, r)
  match (map.get(out.headers, "x-request-id"), map.get(out.headers, "x-trace")) {
    (Some(_), Some(v)) => if v == "abc123" {
      Ok(())
    } else {
      Err("trace header value mismatch")
    },
    (None, _) => Err("MwRequestId did not stamp x-request-id"),
    (_, None) => Err("MwCustom did not stamp x-trace"),
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] List[Result[Unit, Str]] {
  [body_limit_allows_small_body(), body_limit_blocks_large_body(), body_limit_exact_boundary_allowed(), run_pre_stops_at_first_short(), cors_adds_origin_header(), cors_adds_methods_header(), cors_preserves_existing_headers(), request_id_adds_header(), body_limit_is_noop_in_post(), cors_is_noop_in_pre(), custom_before_can_short_circuit(), custom_before_continue_passes_through(), custom_after_can_mutate_response(), custom_composes_with_builtin()]
}

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

