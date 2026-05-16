# lex-web — response builders
#
# Typed constructors for every common HTTP response shape.
# `Response` (body, status, headers) is the native net.serve_fn
# response type as of lex-lang v0.9.0 (#355).
#
# Effects: none.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "lex-schema/error" as e

import "lex-schema/problem" as prob

# Response value. Headers use lower-cased names per HTTP/2 convention.
type Response = { body :: Str, status :: Int, headers :: Map[Str, Str] }

# ---- 2xx builders ------------------------------------------------
fn json(body :: Str) -> Response {
  with_ct(200, body, "application/json")
}

fn text(body :: Str) -> Response {
  with_ct(200, body, "text/plain; charset=utf-8")
}

fn html(body :: Str) -> Response {
  with_ct(200, body, "text/html; charset=utf-8")
}

fn created(location :: Str) -> Response {
  { body: "", status: 201, headers: map.from_list([("location", location)]) }
}

fn created_json(body :: Str, location :: Str) -> Response {
  { body: body, status: 201, headers: map.from_list([("content-type", "application/json"), ("location", location)]) }
}

fn no_content() -> Response {
  { body: "", status: 204, headers: map.new() }
}

# ---- Redirect builders -------------------------------------------
fn redirect(location :: Str) -> Response {
  { body: "", status: 302, headers: map.from_list([("location", location)]) }
}

fn permanent_redirect(location :: Str) -> Response {
  { body: "", status: 301, headers: map.from_list([("location", location)]) }
}

# ---- 4xx / 5xx builders ------------------------------------------
fn not_found() -> Response {
  json_status(404, "{\"error\":\"not found\"}")
}

fn method_not_allowed(allowed :: List[Str]) -> Response {
  { body: "{\"error\":\"method not allowed\"}", status: 405, headers: map.from_list([("content-type", "application/json"), ("allow", str.join(allowed, ", "))]) }
}

fn bad_request(detail :: Str) -> Response {
  json_status(400, err_body("bad request", detail))
}

fn unauthorized(detail :: Str) -> Response {
  json_status(401, err_body("unauthorized", detail))
}

fn forbidden(detail :: Str) -> Response {
  json_status(403, err_body("forbidden", detail))
}

fn payload_too_large() -> Response {
  json_status(413, "{\"error\":\"payload too large\"}")
}

fn internal_error() -> Response {
  json_status(500, "{\"error\":\"internal server error\"}")
}

# RFC 7807 problem+json from a lex-schema Errors list.
# `instance` should be the request path (ctx.path).
fn problem(status :: Int, instance :: Str, errs :: e.Errors) -> Response {
  let p := prob.validation_problem("https://example.com/problems/validation", instance, errs)
  { body: prob.to_str(p), status: status, headers: map.from_list([("content-type", prob.content_type())]) }
}

# ---- Header mutation ---------------------------------------------
fn with_header(resp :: Response, key :: Str, val :: Str) -> Response {
  { body: resp.body, status: resp.status, headers: map.set(resp.headers, str.to_lower(key), val) }
}

fn with_headers(resp :: Response, pairs :: List[(Str, Str)]) -> Response {
  list.fold(pairs, resp, fn (r :: Response, kv :: (Str, Str)) -> Response {
    let k := match kv {
      (a, _) => a,
    }
    let v := match kv {
      (_, b) => b,
    }
    with_header(r, k, v)
  })
}

# ---- Internal helpers --------------------------------------------
fn with_ct(status :: Int, body :: Str, ct :: Str) -> Response {
  { body: body, status: status, headers: map.from_list([("content-type", ct)]) }
}

fn json_status(status :: Int, body :: Str) -> Response {
  with_ct(status, body, "application/json")
}

fn err_body(error :: Str, detail :: Str) -> Str {
  str.concat("{\"error\":\"", str.concat(error, str.concat("\",\"detail\":\"", str.concat(detail, "\"}"))))
}

