# Tests for src/router_pure.lex — the effect-free router tier.
#
# Every function here, `run_all` included, declares NO effects. `lex test`
# does not enforce the policy, but `lex run` does, so CI also runs
#
#   lex run tests/test_router_pure.lex run_all
#
# with an empty --allow-effects set. That is the regression guard for
# the minimal-grant property: if anything effect-bearing (middleware,
# lex-log, the wide `dispatch` row) is imported into router_pure's
# module graph, the runtime refuses to load this program.

import "std.list" as list

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router_pure" as router

import "../src/testing" as t

fn quote(c :: ctx.Ctx) -> resp.Response {
  let sym := match ctx.path_param(c, "sym") {
    Some(s) => s,
    None => "",
  }
  resp.json(sym)
}

fn health(_c :: ctx.Ctx) -> resp.Response {
  resp.text("ok")
}

fn app() -> router.Router {
  (router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/quote/:sym", quote)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "get", "/health", health)
  }
}

fn param_route_binds() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.get("/quote/lex"))
  t.all([t.assert_status(r, 200), t.assert_body_eq(r, "lex")])
}

fn method_is_case_insensitive() -> Result[Unit, Str] {
  t.assert_status(router.dispatch_pure(app(), t.get("/health")), 200)
}

fn unknown_path_is_404() -> Result[Unit, Str] {
  t.assert_status(router.dispatch_pure(app(), t.get("/nope")), 404)
}

fn wrong_method_is_404() -> Result[Unit, Str] {
  t.assert_status(router.dispatch_pure(app(), t.post("/health", "")), 404)
}

fn empty_router_is_404() -> Result[Unit, Str] {
  t.assert_status(router.dispatch_pure(router.new(), t.get("/")), 404)
}

fn suite() -> List[Result[Unit, Str]] {
  [param_route_binds(), method_is_case_insensitive(), unknown_path_is_404(), wrong_method_is_404(), empty_router_is_404()]
}

fn run_all() -> Unit {
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

