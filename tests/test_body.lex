# Tests for src/body.lex — request body decoding helpers.

import "std.list" as list
import "std.str"  as str
import "std.map"  as map
import "std.int"  as int

import "../src/ctx"           as ctx
import "../src/response"      as resp
import "../src/body"          as body
import "../src/testing"       as t
import "../src/test_fixtures" as tf

# ---- Helpers -----------------------------------------------------

fn json_ctx(body_str :: Str) -> ctx.Ctx {
  ctx.from_request_with_headers(
    { method: "POST", path: "/", body: body_str, query: "", headers: map.new() },
    map.new(),
    map.from_list([("content-type", "application/json")]))
}

fn form_ctx(body_str :: Str) -> ctx.Ctx {
  ctx.from_request_with_headers(
    { method: "POST", path: "/", body: body_str, query: "", headers: map.new() },
    map.new(),
    map.from_list([
      ("content-type", "application/x-www-form-urlencoded")
    ]))
}

# ---- is_json / is_form -------------------------------------------

fn is_json_true_for_json_content_type() -> Result[Unit, Str] {
  let c := json_ctx("{}")
  if body.is_json(c) { Ok(()) }
  else { Err("expected is_json to be true") }
}

fn is_json_false_for_form_content_type() -> Result[Unit, Str] {
  let c := form_ctx("a=1")
  if not (body.is_json(c)) { Ok(()) }
  else { Err("expected is_json to be false for form") }
}

fn is_form_true_for_urlencoded() -> Result[Unit, Str] {
  let c := form_ctx("a=1")
  if body.is_form(c) { Ok(()) }
  else { Err("expected is_form to be true") }
}

# ---- json_body ---------------------------------------------------

fn json_body_ok_on_valid_json() -> Result[Unit, Str] {
  let c := json_ctx("{\"name\":\"alice\"}")
  match body.json_body(c, tf.name_validator()) {
    Ok(_)  => Ok(()),
    Err(_) => Err("unexpected validation error on valid body"),
  }
}

fn json_body_err_on_invalid_json() -> Result[Unit, Str] {
  let c := json_ctx("not json")
  match body.json_body(c, tf.name_validator()) {
    Err(_) => Ok(()),
    Ok(_)  => Err("expected error on malformed JSON"),
  }
}

fn json_body_err_on_missing_required_field() -> Result[Unit, Str] {
  let c := json_ctx("{\"other\":\"value\"}")
  match body.json_body(c, tf.name_validator()) {
    Err(_) => Ok(()),
    Ok(_)  => Err("expected error on missing required field"),
  }
}

# ---- require_json_body -------------------------------------------

fn require_json_body_ok_returns_json() -> Result[Unit, Str] {
  let c := json_ctx("{\"name\":\"alice\"}")
  match body.require_json_body(c, tf.name_validator()) {
    Ok(_)  => Ok(()),
    Err(r) => Err(str.concat("expected ok, got status ",
      int.to_str(r.status))),
  }
}

fn require_json_body_err_returns_422() -> Result[Unit, Str] {
  let c := json_ctx("{}")
  match body.require_json_body(c, tf.name_validator()) {
    Err(r) => t.assert_status(r, 422),
    Ok(_)  => Err("expected 422 response on invalid body"),
  }
}

# ---- raw_body ----------------------------------------------------

fn raw_body_returns_body_string() -> Result[Unit, Str] {
  let c := json_ctx("hello world")
  if body.raw_body(c) == "hello world" { Ok(()) }
  else { Err("raw_body did not return original body") }
}

# ---- form_body_raw -----------------------------------------------

fn form_body_raw_parses_simple_pair() -> Result[Unit, Str] {
  let c := form_ctx("key=value")
  let m := body.form_body_raw(c)
  match map.get(m, "key") {
    Some("value") => Ok(()),
    Some(other)   => Err(str.concat("expected value, got: ", other)),
    None          => Err("key not found in form body"),
  }
}

fn form_body_raw_parses_multiple_pairs() -> Result[Unit, Str] {
  let c := form_ctx("a=1&b=hello")
  let m := body.form_body_raw(c)
  let a := match map.get(m, "a") { Some(v) => v, None => "" }
  let b := match map.get(m, "b") { Some(v) => v, None => "" }
  if a == "1" and b == "hello" { Ok(()) }
  else {
    Err(str.concat("unexpected values: a=",
      str.concat(a, str.concat(" b=", b))))
  }
}

# ---- Suite -------------------------------------------------------

fn suite() -> List[Result[Unit, Str]] {
  [
    is_json_true_for_json_content_type(),
    is_json_false_for_form_content_type(),
    is_form_true_for_urlencoded(),
    json_body_ok_on_valid_json(),
    json_body_err_on_invalid_json(),
    json_body_err_on_missing_required_field(),
    require_json_body_ok_returns_json(),
    require_json_body_err_returns_422(),
    raw_body_returns_body_string(),
    form_body_raw_parses_simple_pair(),
    form_body_raw_parses_multiple_pairs(),
  ]
}

fn run_all() -> () {
  assert list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  }) == 0
}
