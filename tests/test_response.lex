# Tests for src/response.lex — response builders and header mutation.

import "std.list" as list
import "std.str"  as str
import "std.map"  as map
import "std.int"  as int

import "../src/response" as resp
import "../src/testing"  as t

# ---- Content-type builders --------------------------------------

fn json_has_content_type() -> Result[Unit, Str] {
  let r := resp.json("{\"ok\":true}")
  t.all([
    t.assert_status(r, 200),
    t.assert_header(r, "content-type", "application/json"),
  ])
}

fn text_has_content_type() -> Result[Unit, Str] {
  let r := resp.text("hello")
  t.all([
    t.assert_status(r, 200),
    t.assert_header_contains(r, "content-type", "text/plain"),
  ])
}

fn html_has_content_type() -> Result[Unit, Str] {
  let r := resp.html("<h1>Hi</h1>")
  t.all([
    t.assert_status(r, 200),
    t.assert_header_contains(r, "content-type", "text/html"),
  ])
}

# ---- Status-code builders ----------------------------------------

fn created_status_and_location() -> Result[Unit, Str] {
  let r := resp.created("/users/42")
  t.all([
    t.assert_status(r, 201),
    t.assert_header(r, "location", "/users/42"),
  ])
}

fn created_json_has_body_location_status() -> Result[Unit, Str] {
  let r := resp.created_json("{\"id\":\"42\"}", "/users/42")
  t.all([
    t.assert_status(r, 201),
    t.assert_header(r, "location", "/users/42"),
    t.assert_header(r, "content-type", "application/json"),
    t.assert_body_contains(r, "42"),
  ])
}

fn no_content_is_204() -> Result[Unit, Str] {
  let r := resp.no_content()
  t.all([
    t.assert_status(r, 204),
    t.assert_body_eq(r, ""),
  ])
}

fn redirect_gives_302_location() -> Result[Unit, Str] {
  let r := resp.redirect("/new-path")
  t.all([
    t.assert_status(r, 302),
    t.assert_header(r, "location", "/new-path"),
  ])
}

fn not_found_is_404() -> Result[Unit, Str] {
  let r := resp.not_found()
  t.assert_status(r, 404)
}

fn method_not_allowed_has_allow_header() -> Result[Unit, Str] {
  let r := resp.method_not_allowed(["GET", "HEAD"])
  t.all([
    t.assert_status(r, 405),
    t.assert_header_contains(r, "allow", "GET"),
    t.assert_header_contains(r, "allow", "HEAD"),
  ])
}

fn bad_request_is_400() -> Result[Unit, Str] {
  let r := resp.bad_request("oops")
  t.all([
    t.assert_status(r, 400),
    t.assert_body_contains(r, "oops"),
  ])
}

fn internal_error_is_500() -> Result[Unit, Str] {
  let r := resp.internal_error()
  t.assert_status(r, 500)
}

fn payload_too_large_is_413() -> Result[Unit, Str] {
  let r := resp.payload_too_large()
  t.assert_status(r, 413)
}

# ---- Header mutation ---------------------------------------------

fn with_header_adds_entry() -> Result[Unit, Str] {
  let r := resp.json("{}")
    |> fn (r :: resp.Response) -> resp.Response {
         resp.with_header(r, "x-custom", "value")
       }
  t.assert_header(r, "x-custom", "value")
}

fn with_header_lowercases_key() -> Result[Unit, Str] {
  let r := resp.with_header(resp.json("{}"), "X-My-Header", "v")
  t.assert_header(r, "x-my-header", "v")
}

fn with_headers_sets_multiple() -> Result[Unit, Str] {
  let r := resp.with_headers(resp.json("{}"), [
    ("x-a", "1"),
    ("x-b", "2"),
  ])
  t.all([
    t.assert_header(r, "x-a", "1"),
    t.assert_header(r, "x-b", "2"),
  ])
}

fn with_header_overwrites_existing() -> Result[Unit, Str] {
  let r := resp.json("{}")
  let r2 := resp.with_header(r, "x-val", "old")
  let r3 := resp.with_header(r2, "x-val", "new")
  t.assert_header(r3, "x-val", "new")
}

# ---- body and status direct access ------------------------------

fn body_and_status_accessible() -> Result[Unit, Str] {
  let r := resp.json("{\"ok\":true}")
  if r.status == 200 and r.body == "{\"ok\":true}" { Ok(()) }
  else { Err(str.concat("unexpected: status=", str.concat(int.to_str(r.status), str.concat(" body=", r.body)))) }
}

# ---- Suite -------------------------------------------------------

fn suite() -> List[Result[Unit, Str]] {
  [
    json_has_content_type(),
    text_has_content_type(),
    html_has_content_type(),
    created_status_and_location(),
    created_json_has_body_location_status(),
    no_content_is_204(),
    redirect_gives_302_location(),
    not_found_is_404(),
    method_not_allowed_has_allow_header(),
    bad_request_is_400(),
    internal_error_is_500(),
    payload_too_large_is_413(),
    with_header_adds_entry(),
    with_header_lowercases_key(),
    with_headers_sets_multiple(),
    with_header_overwrites_existing(),
    body_and_status_accessible(),
  ]
}

fn run_all() -> () {
  assert list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  }) == 0
}
