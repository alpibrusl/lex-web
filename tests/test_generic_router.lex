# Tests for GenericRouter[e] (src/router.lex) — one caller-chosen effect
# row for every route, no bypass around the router for an effect the
# fixed `Router` doesn't carry.

import "std.io" as io

import "std.time" as time

import "std.str" as str

import "std.list" as list

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/static_files" as sf

import "../src/testing" as t

# ---- Path matching, at a pure row --------------------------------
# Plain, zero-effect handlers unify against `route_generic[e]`'s
# `(Ctx) -> [| e] Response` parameter with `e` resolving to the empty
# row — the same thing a bracket-less closure does against any open-row
# parameter (proven directly against the compiler before writing this
# router at all: a `fn () -> Int { 10 }` argument instantiates a
# `(...)-> [| e] Int` parameter's `e` as empty). So `pure_app` needs no
# effect annotation of its own; `[e]` here is only in scope for the type
# argument on `GenericRouter[e]`, not because the body performs anything.
fn health(c :: ctx.Ctx) -> resp.Response {
  resp.text("ok")
}

fn echo_id(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "id") {
    Some(id) => resp.text(id),
    None => resp.bad_request("no id"),
  }
}

fn echo_rest(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "rest") {
    Some(s) => resp.text(s),
    None => resp.bad_request("no rest"),
  }
}

fn pure_app[e]() -> router.GenericRouter[e] {
  let r0 := router.new_generic()
  let r1 := router.route_generic(r0, "GET", "/health", health)
  let r2 := router.route_generic(r1, "GET", "/users/:id", echo_id)
  router.route_generic(r2, "GET", "/files/*rest", echo_rest)
}

fn test_health() -> Result[Unit, Str] {
  t.assert_body_eq(router.dispatch_generic(pure_app(), t.get("/health")), "ok")
}

fn test_path_param() -> Result[Unit, Str] {
  t.assert_body_eq(router.dispatch_generic(pure_app(), t.get("/users/42")), "42")
}

fn test_wildcard() -> Result[Unit, Str] {
  t.assert_body_eq(router.dispatch_generic(pure_app(), t.get("/files/a/b/c")), "a/b/c")
}

fn test_no_match_is_404() -> Result[Unit, Str] {
  t.assert_status(router.dispatch_generic(pure_app(), t.get("/nope")), 404)
}

# ---- An effect the fixed Router's HEff row DOES carry, exercised
# through GenericRouter anyway — the point is that GenericRouter[e]
# accepts whatever row the caller writes down, not that this
# particular effect is exotic (see test_io_instantiation below for the
# part that actually distinguishes it from the fixed router: the SAME
# definitions retargeted to a different concrete row).
fn ticking(c :: ctx.Ctx) -> [time] resp.Response {
  let __now := time.now_ms()
  resp.text("ticked")
}

fn time_app[e]() -> router.GenericRouter[e] {
  router.route_generic(router.new_generic(), "GET", "/tick", ticking)
}

fn test_effectful_route() -> [time] Result[Unit, Str] {
  t.assert_body_eq(router.dispatch_generic(time_app(), t.get("/tick")), "ticked")
}

# ---- Genuine polymorphism: the SAME app-builder, two different
# concrete rows in the same program. If GenericRouter's `e` were
# secretly monomorphic (fixed to whatever the first call resolved it
# to, the exact bug this whole feature exists to avoid), one of these
# two would fail to type-check.
fn talking(c :: ctx.Ctx) -> [io] resp.Response {
  let __p := io.print("handled")
  resp.text("said")
}

fn talk_app[e]() -> router.GenericRouter[e] {
  router.route_generic(router.new_generic(), "GET", "/say", talking)
}

fn test_pure_and_io_reuse_the_same_definition() -> [io] Result[Unit, Str] {
  match t.assert_body_eq(router.dispatch_generic(pure_app(), t.get("/health")), "ok") {
    Err(e) => Err(e),
    Ok(_) => t.assert_body_eq(router.dispatch_generic(talk_app(), t.get("/say")), "said"),
  }
}

# ---- mount_dir_generic (static_files.lex) -------------------------
fn static_app[e]() -> [fs_read | e] router.GenericRouter[e] {
  sf.mount_dir_generic(router.new_generic(), "/static", "tests/fixtures/static")
}

fn test_mount_dir_generic_serves_a_file() -> [fs_read] Result[Unit, Str] {
  t.assert_body_contains(router.dispatch_generic(static_app(), t.get("/static/hello.txt")), "hello from a fixture")
}

fn test_mount_dir_generic_404s_on_missing_file() -> [fs_read] Result[Unit, Str] {
  t.assert_status(router.dispatch_generic(static_app(), t.get("/static/nope.txt")), 404)
}

fn suite() -> [io, time, fs_read] List[Result[Unit, Str]] {
  [t.label("health", test_health()), t.label("path param", test_path_param()), t.label("wildcard", test_wildcard()), t.label("no match is 404", test_no_match_is_404()), t.label("effectful route ([time])", test_effectful_route()), t.label("pure and io reuse the same GenericRouter[e] definition", test_pure_and_io_reuse_the_same_definition()), t.label("mount_dir_generic serves a file", test_mount_dir_generic_serves_a_file()), t.label("mount_dir_generic 404s on a missing file", test_mount_dir_generic_404s_on_missing_file())]
}

fn run_all() -> [io, time, fs_read] Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> [io] Int {
    match r {
      Ok(_) => n,
      Err(e) => {
        let __p := io.print(str.concat("FAIL: ", e))
        n + 1
      },
    }
  })
}

