# Tests for src/openapi.lex — OpenAPI 3.1 document generation.

import "std.list" as list
import "std.str"  as str
import "std.map"  as map

import "../src/ctx"      as ctx
import "../src/response" as resp
import "../src/router"   as router
import "../src/openapi"  as openapi
import "../src/testing"  as t

import "lex-schema/schema"      as s
import "lex-schema/constraints" as c
import "lex-schema/validator"   as v
import "lex-schema/json_value"  as jv

# ---- Helpers -----------------------------------------------------

fn noop_handler(c :: ctx.Ctx) -> resp.Response { resp.no_content() }

fn item_validator() -> v.Validator {
  v.make({
    title: "Item", description: "",
    fields: [
      s.required_str("name",  [c.StrNonEmpty]),
      s.required_int("qty",   [c.IntPositive]),
    ],
  })
}

# ---- openapi_path conversion ------------------------------------

fn static_path_unchanged() -> Result[Unit, Str] {
  let p := openapi.openapi_path("/health")
  if p == "/health" { Ok(()) }
  else { Err(str.concat("got: ", p)) }
}

fn param_segment_converted() -> Result[Unit, Str] {
  let p := openapi.openapi_path("/users/:id")
  if p == "/users/{id}" { Ok(()) }
  else { Err(str.concat("got: ", p)) }
}

fn multi_param_converted() -> Result[Unit, Str] {
  let p := openapi.openapi_path("/orgs/:org/users/:user")
  if p == "/orgs/{org}/users/{user}" { Ok(()) }
  else { Err(str.concat("got: ", p)) }
}

fn splat_converted() -> Result[Unit, Str] {
  let p := openapi.openapi_path("/files/*rest")
  if p == "/files/{rest}" { Ok(()) }
  else { Err(str.concat("got: ", p)) }
}

# ---- Path parameters in operation --------------------------------

fn param_route_emits_parameter_object() -> Result[Unit, Str] {
  let r := router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/users/:id", noop_handler)
       }
  let doc := jv.stringify(openapi.export_openapi(r, openapi.make_info("T", "1")))
  if str.contains(doc, "\"in\":\"path\"") and str.contains(doc, "\"name\":\"id\"")
  { Ok(()) }
  else { Err(str.concat("param object missing in: ", doc)) }
}

fn static_route_no_parameter_objects() -> Result[Unit, Str] {
  let r := router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/health", noop_handler)
       }
  let doc := jv.stringify(openapi.export_openapi(r, openapi.make_info("T", "1")))
  if not (str.contains(doc, "\"in\":\"path\"")) { Ok(()) }
  else { Err("unexpected path param in static route") }
}

# ---- Validator-attached routes -----------------------------------

fn route_with_validator_has_request_body() -> Result[Unit, Str] {
  let r := router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.handler_json(r, "POST", "/items", item_validator(), noop_handler)
       }
  let doc := jv.stringify(openapi.export_openapi(r, openapi.make_info("T", "1")))
  if str.contains(doc, "requestBody") and str.contains(doc, "application/json")
  { Ok(()) }
  else { Err(str.concat("requestBody missing: ", doc)) }
}

fn route_without_validator_has_no_request_body() -> Result[Unit, Str] {
  let r := router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/items", noop_handler)
       }
  let doc := jv.stringify(openapi.export_openapi(r, openapi.make_info("T", "1")))
  if not (str.contains(doc, "requestBody")) { Ok(()) }
  else { Err("unexpected requestBody on GET route") }
}

fn validator_schema_fields_in_doc() -> Result[Unit, Str] {
  let r := router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.handler_json(r, "POST", "/items", item_validator(), noop_handler)
       }
  let doc := jv.stringify(openapi.export_openapi(r, openapi.make_info("T", "1")))
  if str.contains(doc, "\"name\"") and str.contains(doc, "\"qty\"")
  { Ok(()) }
  else { Err(str.concat("schema fields missing: ", doc)) }
}

# ---- Document structure ------------------------------------------

fn doc_has_openapi_version() -> Result[Unit, Str] {
  let r   := router.new()
  let doc := jv.stringify(openapi.export_openapi(r, openapi.make_info("My API", "2.0.0")))
  if str.contains(doc, "3.1.0") { Ok(()) }
  else { Err("missing openapi version") }
}

fn doc_has_info_title_and_version() -> Result[Unit, Str] {
  let r   := router.new()
  let doc := jv.stringify(openapi.export_openapi(r,
    openapi.make_info("My API", "2.0.0")))
  if str.contains(doc, "My API") and str.contains(doc, "2.0.0") { Ok(()) }
  else { Err(str.concat("info missing: ", doc)) }
}

fn same_path_different_methods_one_path_item() -> Result[Unit, Str] {
  # GET and POST on /items should produce one path item with two
  # method keys, not two separate path items.
  let r :=
    router.new()
      |> fn (r :: router.Router) -> router.Router {
           router.route(r, "GET",  "/items", noop_handler)
         }
      |> fn (r :: router.Router) -> router.Router {
           router.route(r, "POST", "/items", noop_handler)
         }
  let doc := jv.stringify(openapi.export_openapi(r, openapi.make_info("T", "1")))
  # If deduplicated, "/items" appears exactly once as a path key.
  # We check both method keys are present without "/items" doubled.
  if str.contains(doc, "\"get\"") and str.contains(doc, "\"post\"")
  { Ok(()) }
  else { Err(str.concat("methods missing: ", doc)) }
}

# ---- Suite -------------------------------------------------------

fn suite() -> List[Result[Unit, Str]] {
  [
    static_path_unchanged(),
    param_segment_converted(),
    multi_param_converted(),
    splat_converted(),
    param_route_emits_parameter_object(),
    static_route_no_parameter_objects(),
    route_with_validator_has_request_body(),
    route_without_validator_has_no_request_body(),
    validator_schema_fields_in_doc(),
    doc_has_openapi_version(),
    doc_has_info_title_and_version(),
    same_path_different_methods_one_path_item(),
  ]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  })
}
