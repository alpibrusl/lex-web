# lex-web example: Users CRUD API
#
# Demonstrates the full lex-web surface:
#   - lex-schema Validator for request body validation
#   - handler_json() to attach the validator to a route
#   - Path parameters via ctx.path_param()
#   - Query params via ctx.query_param_or()
#   - Response builders: json, created, not_found, problem
#   - CORS + logger middleware via use_mw()
#   - OpenAPI export served at /openapi.json
#   - Dispatch via a named wrapper (until lex-lang#354 lands)
#
# Validators and schema helpers are accessed through src/test_fixtures
# so the module identity matches body.lex and router.lex (all three
# import lex-data from the same relative-path chain).
#
# Run:
#   lex run --allow-effects io,net,time \
#           examples/users_api.lex main
#
# Try:
#   curl -X POST http://localhost:8080/users \
#        -H 'content-type: application/json' \
#        -d '{"name":"Alice"}'
#   curl http://localhost:8080/users/usr_001
#   curl http://localhost:8080/openapi.json

import "std.net"  as net
import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list
import "std.map"  as map

import "../src/ctx"           as ctx
import "../src/response"      as resp
import "../src/router"        as router
import "../src/body"          as body
import "../src/middleware"    as mw
import "../src/openapi"       as openapi
import "../src/test_fixtures" as tf

# ---- Handlers ----------------------------------------------------

# POST /users — validate body and create a user.
# body.require_json_body returns Err(Response) on bad input so
# the match collapses to a single happy-path arm.
fn create_user(c :: ctx.Ctx) -> resp.Response {
  match body.require_json_body(c, tf.name_validator()) {
    Err(problem_resp) => problem_resp,
    Ok(_user_json)    =>
      resp.created_json(
        "{\"id\":\"usr_001\",\"name\":\"Alice\"}",
        "/users/usr_001"),
  }
}

# GET /users/:id — fetch one user by path param.
fn get_user(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "id") {
    None     => resp.bad_request("missing id"),
    Some(id) =>
      if id == "usr_001" {
        resp.json("{\"id\":\"usr_001\",\"name\":\"Alice\"}")
      } else {
        resp.not_found()
      },
  }
}

# GET /users — list users, supporting ?page= query param.
fn list_users(c :: ctx.Ctx) -> resp.Response {
  let page := ctx.query_param_or(c, "page", "1")
  resp.json(str.concat(
    "{\"page\":",
    str.concat(page,
      ",\"items\":[{\"id\":\"usr_001\",\"name\":\"Alice\"}]}")))
}

# GET /openapi.json — serve the auto-generated OpenAPI document.
fn get_openapi(c :: ctx.Ctx) -> resp.Response {
  let doc := openapi.export_openapi_str(
    app(),
    openapi.make_info("Users API", "0.1.0"))
  resp.json(doc)
}

# ---- Router ------------------------------------------------------

fn app() -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/users", list_users)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.handler_json(r, "POST", "/users", tf.name_validator(), create_user)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/users/:id", get_user)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/openapi.json", get_openapi)
       }
    |> fn (r :: router.Router) -> router.Router {
         router.use_mw(r, mw.cors(["*"]))
       }
    |> fn (r :: router.Router) -> router.Router {
         router.use_mw(r, mw.logger())
       }
}

# ---- Entry point -------------------------------------------------
#
# net.serve currently takes a handler-name string (lex-lang#354).
# The `handle` wrapper adapts our router to that interface.
# Once #354 lands this collapses to: net.serve(8080, app())

fn handle(req :: ctx.RawRequest) -> [io, time] resp.RawResponse {
  resp.to_raw(router.dispatch(app(), req))
}

fn main() -> [net, io] Nil {
  let doc_size := str.len(openapi.export_openapi_str(
    app(), openapi.make_info("Users API", "0.1.0")))
  let _ := io.print(str.concat(
    "OpenAPI doc ready: ",
    str.concat(int.to_str(doc_size), " bytes")))
  net.serve(8080, "handle")
}
