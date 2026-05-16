# Tests for src/router.lex — route matching and dispatch_pure.

import "std.list" as list

import "std.str" as str

import "std.map" as map

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

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

# ---- Suite -------------------------------------------------------
fn suite() -> List[Result[Unit, Str]] {
  [static_route_matches(), static_route_not_found(), param_route_matches_and_binds(), param_does_not_match_empty_segment(), method_mismatch_gives_404(), post_matches_own_method(), splat_captures_single_segment(), splat_captures_multiple_segments(), two_params_both_bound(), literal_always_beats_param(), static_before_param_wins(), method_is_case_insensitive(), param_name_conflict_first_registered_wins(), literal_falls_back_to_param_on_dead_end()]
}

# `lex test` calls run_all and reports the file as failed iff run_all
# panics. We fold the suite into a failure count and force a panic
# (`1 / 0`) when any case failed; the failed Err(_) messages are not
# surfaced today — `lex test` only reports the panic site — but the
# panic correctly fails the run.
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

