# Tests for src/sub_router.lex — APIRouter equivalent.

import "std.list" as list

import "std.map" as map

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/sub_router" as sr

import "../src/testing" as t

# ---- Test handlers ------------------------------------------------
fn list_h(_c :: ctx.Ctx) -> resp.Response {
  resp.text("list")
}

fn one_h(_c :: ctx.Ctx) -> resp.Response {
  resp.text("one")
}

fn create_h(_c :: ctx.Ctx) -> resp.Response {
  resp.text("create")
}

fn users_router() -> sr.SubRouter {
  ((((sr.new("/users", ["users"]) |> fn (r :: sr.SubRouter) -> sr.SubRouter {
    sr.route(r, "GET", "/", list_h)
  }) |> fn (r :: sr.SubRouter) -> sr.SubRouter {
    sr.with_summary(r, "List users")
  }) |> fn (r :: sr.SubRouter) -> sr.SubRouter {
    sr.route(r, "GET", "/:id", one_h)
  }) |> fn (r :: sr.SubRouter) -> sr.SubRouter {
    sr.route(r, "POST", "/", create_h)
  }) |> fn (r :: sr.SubRouter) -> sr.SubRouter {
    sr.with_status(r, 201)
  }
}

fn app() -> router.Router {
  sr.mount(router.new(), users_router())
}

# ---- Tests --------------------------------------------------------
fn test_prefix_join_index() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.get("/users"))
  if r.status == 200 and r.body == "list" {
    Ok(())
  } else {
    Err("index route did not match under prefix")
  }
}

fn test_prefix_join_param() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.get("/users/42"))
  if r.status == 200 and r.body == "one" {
    Ok(())
  } else {
    Err(":id route did not match under prefix")
  }
}

fn test_post_under_prefix() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.post("/users", "{}"))
  if r.status == 200 and r.body == "create" {
    Ok(())
  } else {
    Err("POST under prefix did not match")
  }
}

fn test_meta_summary_attached() -> Result[Unit, Str] {
  let routes := app().routes
  let found := list.fold(routes, false, fn (acc :: Bool, rec :: router.RouteRecord) -> Bool {
    acc or rec.method == "GET" and rec.pattern == "/users" and rec.meta.summary == "List users"
  })
  if found {
    Ok(())
  } else {
    Err("summary metadata missing")
  }
}

fn test_meta_status_attached() -> Result[Unit, Str] {
  let routes := app().routes
  let found := list.fold(routes, false, fn (acc :: Bool, rec :: router.RouteRecord) -> Bool {
    acc or rec.method == "POST" and rec.pattern == "/users" and rec.meta.status == 201
  })
  if found {
    Ok(())
  } else {
    Err("status metadata missing")
  }
}

fn test_meta_tags_attached() -> Result[Unit, Str] {
  let routes := app().routes
  let found := list.fold(routes, false, fn (acc :: Bool, rec :: router.RouteRecord) -> Bool {
    let has_users := list.fold(rec.meta.tags, false, fn (a :: Bool, tag :: Str) -> Bool {
      a or tag == "users"
    })
    acc or rec.method == "GET" and rec.pattern == "/users" and has_users
  })
  if found {
    Ok(())
  } else {
    Err("tags missing")
  }
}

# ---- Suite --------------------------------------------------------
fn suite() -> List[Result[Unit, Str]] {
  [test_prefix_join_index(), test_prefix_join_param(), test_post_under_prefix(), test_meta_summary_attached(), test_meta_status_attached(), test_meta_tags_attached()]
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

