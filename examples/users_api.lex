# lex-web example: Users CRUD API
#
# Demonstrates the full lex-web surface:
#   - lex-schema Validator for request body validation
#   - handler_json() to attach the validator to a route
#   - Path parameters via ctx.path_param()
#   - Response builders: json, created, not_found, problem
#   - CORS + logger middleware via use_mw()
#   - OpenAPI export at startup
#   - Dispatch via a named wrapper (until lex-lang#354 lands)
#
# Run:
#   lex run --allow-effects io,net examples/users_api.lex main
#
# Try:
#   curl -X POST http://localhost:8080/users \
#        -H 'content-type: application/json' \
#        -d '{"name":"Alice","email":"alice@example.com","age":30}'
#
#   curl http://localhost:8080/users/1
#   curl http://localhost:8080/openapi.json

import "std.net"  as net
import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list
import "std.map"  as map

import "lex-web/ctx"      as ctx
import "lex-web/response" as resp
import "lex-web/router"   as router
import "lex-web/body"     as body
import "lex-web/middleware" as mw
import "lex-web/openapi"  as openapi

import "lex-schema/schema"     as s
import "lex-schema/constraints" as c
import "lex-schema/validator"  as v
import "lex-schema/json_value" as jv

# ---- Schema ------------------------------------------------------

fn user_schema() -> s.ModelSchema {
  {
    title:       "User",
    description: "A user account",
    fields: [
      s.required_str("name",  [c.StrNonEmpty, c.StrMaxLen(100)]),
      s.required_str("email", [c.StrEmail]),
      s.required_int("age",   [c.IntMin(0), c.IntMax(150)]),
    ],
  }
}

fn user_validator() -> v.Validator { v.make(user_schema()) }

# ---- Handlers ----------------------------------------------------

# POST /users — create a user
fn create_user(c :: ctx.Ctx) -> resp.Response {
  match body.require_json_body(c, user_validator()) {
    Err(problem_resp) => problem_resp,
    Ok(user_json)     => {
      # In a real app: db.insert(user_json) -> Ok(id)
      let name := match jv.get_str(user_json, "name") {
        Some(n) => n,
        None    => "unknown",
      }
      let body_str := str.concat(
        "{\"id\":\"usr_001\",\"name\":\"",
        str.concat(name, "\"}"))
      resp.created_json(body_str, "/users/usr_001")
    },
  }
}

# GET /users/:id — fetch one user
fn get_user(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "id") {
    None     => resp.bad_request("missing id"),
    Some(id) =>
      # Simulate a lookup. Real app: db.find(id).
      if id == "usr_001" {
        resp.json("{\"id\":\"usr_001\",\"name\":\"Alice\",\"email\":\"alice@example.com\",\"age\":30}")
      } else {
        resp.not_found()
      },
  }
}

# GET /users — list users
fn list_users(c :: ctx.Ctx) -> resp.Response {
  let page := ctx.query_param_or(c, "page", "1")
  resp.json(str.concat(
    "{\"page\":",
    str.concat(page, ",\"items\":[{\"id\":\"usr_001\",\"name\":\"Alice\"}]}")))
}

# GET /openapi.json — serve the generated OpenAPI document
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
         router.handler_json(r, "POST", "/users", user_validator(), create_user)
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
# Temporary dispatch wrapper required until lex-lang#354 lands
# (net.serve currently takes a fn name string, not a closure).
# Once #354 ships this collapses to: web.serve(8080, app())

type RawRequest  = { body :: Str, method :: Str, path :: Str, query :: Str }
type RawResponse = { body :: Str, status :: Int }

fn handle(req :: RawRequest) -> [io] RawResponse {
  resp.to_raw(router.dispatch(app(), req))
}

fn main() -> [net, io] Nil {
  let info := openapi.make_info("Users API", "0.1.0")
  let doc  := openapi.export_openapi_str(app(), info)
  let _    := io.print(str.concat("OpenAPI doc ready: ", str.concat(int.to_str(str.len(doc)), " bytes")))
  net.serve(8080, "handle")
}
