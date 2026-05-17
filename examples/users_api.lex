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
#   - net.serve_fn with a closure handler (lex-lang v0.9.0 / #354)
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

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.map" as map

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/body" as body

import "../src/middleware" as mw

import "../src/openapi" as openapi

import "../src/test_fixtures" as tf

# ---- Handlers ----------------------------------------------------
# POST /users — validate body and create a user.
# body.require_json_body returns Err(Response) on bad input so
# the match collapses to a single happy-path arm.
fn create_user(c :: ctx.Ctx) -> resp.Response {
  match body.require_json_body(c, tf.name_validator()) {
    Err(problem_resp) => problem_resp,
    Ok(_user_json) => resp.created_json("{\"id\":\"usr_001\",\"name\":\"Alice\"}", "/users/usr_001"),
  }
}

# GET /users/:id — fetch one user by path param.
fn get_user(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing id"),
    Some(id) => if id == "usr_001" {
      resp.json("{\"id\":\"usr_001\",\"name\":\"Alice\"}")
    } else {
      resp.not_found()
    },
  }
}

# GET /users — list users, supporting ?page= query param.
fn list_users(c :: ctx.Ctx) -> resp.Response {
  let page := ctx.query_param_or(c, "page", "1")
  resp.json(str.concat("{\"page\":", str.concat(page, ",\"items\":[{\"id\":\"usr_001\",\"name\":\"Alice\"}]}")))
}

# GET /openapi.json — serve the auto-generated OpenAPI document.
fn get_openapi(c :: ctx.Ctx) -> resp.Response {
  let doc := openapi.export_openapi_str(app(), openapi.make_info("Users API", "0.1.0"))
  resp.json(doc)
}

# ---- Router ------------------------------------------------------
fn app() -> router.Router {
  (((((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users", list_users)
  }) |> fn (r :: router.Router) -> router.Router {
    router.handler_json(r, "POST", "/users", tf.name_validator(), create_user)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/users/:id", get_user)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/openapi.json", get_openapi)
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.cors(["*"]))
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.logger())
  }
}

# ---- Entry point -------------------------------------------------
#
# net.serve_fn (lex-lang 0.9.5) hands us a `Request` value and wants
# a `Response` back. lex-web's router speaks `ctx.RawRequest` ->
# `resp.Response` (with `body :: Str`). A tiny boundary adapter
# translates: rebuild the request as a RawRequest literal, wrap the
# framework's Str body in `BodyStr(...)` on the way out.
fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Unit {
  let doc_size := str.len(openapi.export_openapi_str(app(), openapi.make_info("Users API", "0.1.0")))
  let __lex_discard_1 := io.print(str.concat("OpenAPI doc ready: ", str.concat(int.to_str(doc_size), " bytes")))
  net.serve_fn(8080, handle)
}

