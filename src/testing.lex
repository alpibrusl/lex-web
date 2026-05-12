# lex-web — test helpers
#
# Utilities for writing handler and router unit tests.
# All functions here are pure (no effects), so test suites that
# only call dispatch_pure stay effect-free.
#
# Usage pattern (mirrors lex-data test files):
#
#   fn my_test() -> Result[Unit, Str] {
#     let req  := testing.get("/users/42")
#     let resp := router.dispatch_pure(app(), req)
#     testing.assert_status(resp, 200)
#   }
#
#   fn suite() -> List[Result[Unit, Str]] { [my_test(), ...] }
#   fn run_all() -> Int {
#     list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
#       match r { Ok(_) => n, Err(_) => n + 1 }
#     })
#   }

import "std.str"  as str
import "std.int"  as int
import "std.list" as list
import "std.map"  as map

import "./ctx"      as ctx
import "./response" as resp

# ---- Request builders --------------------------------------------

fn get(path :: Str) -> ctx.RawRequest {
  { method: "GET", path: path, body: "", query: "" }
}

fn post(path :: Str, body :: Str) -> ctx.RawRequest {
  { method: "POST", path: path, body: body, query: "" }
}

fn put(path :: Str, body :: Str) -> ctx.RawRequest {
  { method: "PUT", path: path, body: body, query: "" }
}

fn patch(path :: Str, body :: Str) -> ctx.RawRequest {
  { method: "PATCH", path: path, body: body, query: "" }
}

fn delete(path :: Str) -> ctx.RawRequest {
  { method: "DELETE", path: path, body: "", query: "" }
}

# Full constructor for cases that need query string or custom body.
fn request(
  method :: Str,
  path   :: Str,
  body   :: Str,
  query  :: Str
) -> ctx.RawRequest {
  { method: method, path: path, body: body, query: query }
}

# Add headers to a RawRequest (returns a Ctx directly, since
# RawRequest has no headers field in the current net.serve spec).
fn with_ctx_headers(
  req  :: ctx.RawRequest,
  hdrs :: List[(Str, Str)]
) -> ctx.Ctx {
  ctx.from_request_with_headers(req, map.new(), map.from_list(hdrs))
}

# ---- Response assertions -----------------------------------------

# All assertions return Ok(()) on pass, Err(message) on fail.

fn assert_status(
  r        :: resp.Response,
  expected :: Int
) -> Result[Unit, Str] {
  if r.status == expected { Ok(()) }
  else {
    Err(str.concat("expected status ",
      str.concat(int.to_str(expected),
        str.concat(", got ", int.to_str(r.status)))))
  }
}

fn assert_ok(r :: resp.Response) -> Result[Unit, Str] {
  if r.status >= 200 and r.status < 300 { Ok(()) }
  else { Err(str.concat("expected 2xx, got ", int.to_str(r.status))) }
}

fn assert_body_contains(r :: resp.Response, sub :: Str) -> Result[Unit, Str] {
  if str.contains(r.body, sub) { Ok(()) }
  else {
    Err(str.concat("body does not contain \"",
      str.concat(sub, str.concat("\": ", r.body))))
  }
}

fn assert_body_eq(r :: resp.Response, expected :: Str) -> Result[Unit, Str] {
  if r.body == expected { Ok(()) }
  else {
    Err(str.concat("body mismatch. expected: ",
      str.concat(expected, str.concat(" got: ", r.body))))
  }
}

fn assert_header(
  r   :: resp.Response,
  key :: Str,
  val :: Str
) -> Result[Unit, Str] {
  let k := str.to_lower(key)
  match map.get(r.headers, k) {
    None    => Err(str.concat("header not present: ", k)),
    Some(v) =>
      if v == val { Ok(()) }
      else {
        Err(str.concat("header \"",
          str.concat(k, str.concat("\" expected \"",
            str.concat(val, str.concat("\", got \"",
              str.concat(v, "\"")))))
        ))
      },
  }
}

fn assert_header_present(
  r   :: resp.Response,
  key :: Str
) -> Result[Unit, Str] {
  match map.get(r.headers, str.to_lower(key)) {
    Some(_) => Ok(()),
    None    => Err(str.concat("missing header: ", str.to_lower(key))),
  }
}

fn assert_header_contains(
  r   :: resp.Response,
  key :: Str,
  sub :: Str
) -> Result[Unit, Str] {
  let k := str.to_lower(key)
  match map.get(r.headers, k) {
    None    => Err(str.concat("header not present: ", k)),
    Some(v) =>
      if str.contains(v, sub) { Ok(()) }
      else {
        Err(str.concat("header \"",
          str.concat(k, str.concat("\" does not contain \"",
            str.concat(sub, str.concat("\", got: ", v))))))
      },
  }
}

# ---- Assertion combinators ---------------------------------------

# Run a list of assertions; return the first failure, or Ok(()).
fn all(results :: List[Result[Unit, Str]]) -> Result[Unit, Str] {
  list.fold(results, Ok(()),
    fn (acc :: Result[Unit, Str], r :: Result[Unit, Str]) -> Result[Unit, Str] {
      match acc {
        Err(_) => acc,
        Ok(_)  => r,
      }
    })
}

# Tag a Result with a test name so failures are easy to find.
fn label(name :: Str, r :: Result[Unit, Str]) -> Result[Unit, Str] {
  match r {
    Ok(_)    => Ok(()),
    Err(msg) => Err(str.concat(name, str.concat(": ", msg))),
  }
}
