# dispatch_with keeps the caller's effect row (#59). The resolver here
# declares only [sql], so this whole program needs only `sql`; CI runs
#
#   lex run --allow-effects sql tests/test_dispatch_with_sql.lex run_all
#
# and also checks that a grant without `sql` is refused. With
# router.dispatch the same service would need all twelve effects.

import "std.list" as list

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router_pure" as router

import "../src/testing" as t

fn resolve(name :: Str, c :: ctx.Ctx) -> [sql] resp.Response {
  if name == "get_one" {
    resp.text(match ctx.path_param(c, "id") {
      Some(id) => id,
      None => "",
    })
  } else {
    resp.not_found()
  }
}

fn app() -> router.Router {
  router.route_named(router.new(), "GET", "/invoices/:id", "get_one")
}

fn serve_one(path :: Str) -> [sql] resp.Response {
  router.dispatch_with(app(), t.get(path), resolve)
}

fn resolves_under_a_sql_only_row() -> [sql] Result[Unit, Str] {
  let r := serve_one("/invoices/42")
  t.all([t.assert_status(r, 200), t.assert_body_eq(r, "42")])
}

fn unknown_path_is_404() -> [sql] Result[Unit, Str] {
  t.assert_status(serve_one("/nope"), 404)
}

fn suite() -> [sql] List[Result[Unit, Str]] {
  [resolves_under_a_sql_only_row(), unknown_path_is_404()]
}

fn run_all() -> [sql] Unit {
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

