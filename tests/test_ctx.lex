# Tests for src/ctx.lex — Ctx construction and accessors.

import "std.list" as list

import "std.str" as str

import "std.map" as map

import "../src/ctx" as ctx

import "../src/testing" as t

# ---- Helpers -----------------------------------------------------
fn make_ctx(path :: Str, query :: Str) -> ctx.Ctx {
  ctx.from_request({ method: "GET", path: path, body: "", query: query, headers: map.new() }, map.new())
}

fn make_ctx_with_headers(path :: Str, hdrs :: List[(Str, Str)]) -> ctx.Ctx {
  ctx.from_request_with_headers({ method: "GET", path: path, body: "", query: "", headers: map.new() }, map.new(), map.from_list(hdrs))
}

# ---- query_param -------------------------------------------------
fn query_simple_kv() -> Result[Unit, Str] {
  let c := make_ctx("/", "a=1&b=2")
  match ctx.query_param(c, "a") {
    Some("1") => Ok(()),
    _ => Err("expected a=1"),
  }
}

fn query_second_key() -> Result[Unit, Str] {
  let c := make_ctx("/", "a=1&b=hello")
  match ctx.query_param(c, "b") {
    Some("hello") => Ok(()),
    _ => Err("expected b=hello"),
  }
}

fn query_strips_leading_question_mark() -> Result[Unit, Str] {
  let c := make_ctx("/", "?page=3")
  match ctx.query_param(c, "page") {
    Some("3") => Ok(()),
    _ => Err("did not strip leading ?"),
  }
}

fn query_absent_returns_none() -> Result[Unit, Str] {
  let c := make_ctx("/", "a=1")
  match ctx.query_param(c, "missing") {
    None => Ok(()),
    _ => Err("expected None"),
  }
}

fn query_param_or_default() -> Result[Unit, Str] {
  let c := make_ctx("/", "")
  let v := ctx.query_param_or(c, "page", "1")
  if v == "1" {
    Ok(())
  } else {
    Err(str.concat("got: ", v))
  }
}

fn query_empty_string_body() -> Result[Unit, Str] {
  let c := make_ctx("/", "")
  match ctx.query_param(c, "x") {
    None => Ok(()),
    _ => Err("expected None for empty query"),
  }
}

# ---- path_param --------------------------------------------------
fn path_param_found() -> Result[Unit, Str] {
  let c := ctx.from_request({ method: "GET", path: "/users/99", body: "", query: "", headers: map.new() }, map.from_list([("id", "99")]))
  match ctx.path_param(c, "id") {
    Some("99") => Ok(()),
    _ => Err("expected 99"),
  }
}

fn path_param_missing() -> Result[Unit, Str] {
  let c := ctx.from_request({ method: "GET", path: "/users/99", body: "", query: "", headers: map.new() }, map.new())
  match ctx.path_param(c, "id") {
    None => Ok(()),
    _ => Err("expected None"),
  }
}

fn require_path_param_ok() -> Result[Unit, Str] {
  let c := ctx.from_request({ method: "GET", path: "/x", body: "", query: "", headers: map.new() }, map.from_list([("slug", "hello")]))
  match ctx.require_path_param(c, "slug") {
    Ok("hello") => Ok(()),
    Ok(other) => Err(str.concat("wrong value: ", other)),
    Err(msg) => Err(msg),
  }
}

fn require_path_param_err() -> Result[Unit, Str] {
  let c := ctx.from_request({ method: "GET", path: "/x", body: "", query: "", headers: map.new() }, map.new())
  match ctx.require_path_param(c, "slug") {
    Err(_) => Ok(()),
    Ok(_) => Err("expected Err"),
  }
}

# ---- header accessors -------------------------------------------
fn bearer_token_present() -> Result[Unit, Str] {
  let c := make_ctx_with_headers("/", [("authorization", "Bearer my-secret-token")])
  match ctx.bearer_token(c) {
    Some("my-secret-token") => Ok(()),
    Some(other) => Err(str.concat("wrong token: ", other)),
    None => Err("expected Some"),
  }
}

fn bearer_token_absent() -> Result[Unit, Str] {
  let c := make_ctx("/", "")
  match ctx.bearer_token(c) {
    None => Ok(()),
    _ => Err("expected None"),
  }
}

fn content_type_accessor() -> Result[Unit, Str] {
  let c := make_ctx_with_headers("/", [("content-type", "application/json")])
  let ct := ctx.content_type(c)
  if ct == "application/json" {
    Ok(())
  } else {
    Err(str.concat("got: ", ct))
  }
}

fn header_case_insensitive() -> Result[Unit, Str] {
  let c := make_ctx_with_headers("/", [("x-request-id", "abc-123")])
  match ctx.header(c, "X-Request-Id") {
    Some("abc-123") => Ok(()),
    Some(other) => Err(str.concat("wrong: ", other)),
    None => Err("not found"),
  }
}

# ---- cookie accessors -------------------------------------------
fn cookie_parsed() -> Result[Unit, Str] {
  let c := make_ctx_with_headers("/", [("cookie", "session=abc; theme=dark")])
  match ctx.cookie(c, "session") {
    Some("abc") => Ok(()),
    Some(other) => Err(str.concat("wrong: ", other)),
    None => Err("session cookie not found"),
  }
}

fn cookie_second_value() -> Result[Unit, Str] {
  let c := make_ctx_with_headers("/", [("cookie", "session=abc; theme=dark")])
  match ctx.cookie(c, "theme") {
    Some("dark") => Ok(()),
    _ => Err("theme cookie not found"),
  }
}

fn cookie_absent() -> Result[Unit, Str] {
  let c := make_ctx("/", "")
  match ctx.cookie(c, "session") {
    None => Ok(()),
    _ => Err("expected None"),
  }
}

# ---- State bag --------------------------------------------------
fn state_starts_empty() -> Result[Unit, Str] {
  let c := make_ctx("/", "")
  match ctx.get_state(c, "anything") {
    None => Ok(()),
    Some(_) => Err("expected empty state on fresh ctx"),
  }
}

fn set_state_round_trips() -> Result[Unit, Str] {
  let c := ctx.set_state(make_ctx("/", ""), "user-id", "u_42")
  match ctx.get_state(c, "user-id") {
    Some(v) => if v == "u_42" {
      Ok(())
    } else {
      Err(str.concat("unexpected value: ", v))
    },
    None => Err("expected user-id to be set"),
  }
}

fn set_state_is_immutable() -> Result[Unit, Str] {
  let c0 := make_ctx("/", "")
  let c1 := ctx.set_state(c0, "k", "v")
  match ctx.get_state(c0, "k") {
    None => match ctx.get_state(c1, "k") {
      Some(_) => Ok(()),
      None => Err("c1 lost the value"),
    },
    Some(_) => Err("c0 was mutated"),
  }
}

fn get_state_or_returns_default_when_missing() -> Result[Unit, Str] {
  let c := make_ctx("/", "")
  let v := ctx.get_state_or(c, "missing", "fallback")
  if v == "fallback" {
    Ok(())
  } else {
    Err(str.concat("unexpected default: ", v))
  }
}

fn get_state_or_returns_value_when_present() -> Result[Unit, Str] {
  let c := ctx.set_state(make_ctx("/", ""), "k", "real")
  let v := ctx.get_state_or(c, "k", "fallback")
  if v == "real" {
    Ok(())
  } else {
    Err(str.concat("expected real, got: ", v))
  }
}

fn set_state_overwrites() -> Result[Unit, Str] {
  let c := ctx.set_state(ctx.set_state(make_ctx("/", ""), "k", "first"), "k", "second")
  match ctx.get_state(c, "k") {
    Some(v) => if v == "second" {
      Ok(())
    } else {
      Err(str.concat("expected overwrite to win, got: ", v))
    },
    None => Err("k missing"),
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> List[Result[Unit, Str]] {
  [query_simple_kv(), query_second_key(), query_strips_leading_question_mark(), query_absent_returns_none(), query_param_or_default(), query_empty_string_body(), path_param_found(), path_param_missing(), require_path_param_ok(), require_path_param_err(), bearer_token_present(), bearer_token_absent(), content_type_accessor(), header_case_insensitive(), cookie_parsed(), cookie_second_value(), cookie_absent(), state_starts_empty(), set_state_round_trips(), set_state_is_immutable(), get_state_or_returns_default_when_missing(), get_state_or_returns_value_when_present(), set_state_overwrites()]
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

