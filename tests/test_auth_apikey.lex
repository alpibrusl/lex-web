# Tests for src/auth_apikey.lex (#26 — header/query/cookie API key).
#
# Test fns + callbacks declare the HEff effect row to match
# auth_apikey's verify_* signatures; bodies stay pure.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "../src/ctx" as ctx

import "../src/auth_apikey" as apikey

import "../src/testing" as t

# ---- Helpers -----------------------------------------------------
fn ctx_with(method :: Str, path :: Str, query :: Str, hdrs :: Map[Str, Str]) -> ctx.Ctx {
  ctx.from_request({ method: method, path: path, body: "", query: query, headers: hdrs }, map.new())
}

fn ctx_with_header(name :: Str, value :: Str) -> ctx.Ctx {
  ctx_with("GET", "/", "", map.set(map.new(), name, value))
}

fn ctx_with_query(qs :: Str) -> ctx.Ctx {
  ctx_with("GET", "/", qs, map.new())
}

fn ctx_with_cookie(jar :: Str) -> ctx.Ctx {
  ctx_with("GET", "/", "", map.set(map.new(), "cookie", jar))
}

fn accept_known(k :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool {
  k == "k_live_abcd1234"
}

fn deny_all(_k :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool {
  false
}

# ---- Header ------------------------------------------------------
fn header_valid_key_ok() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := ctx_with_header("x-api-key", "k_live_abcd1234")
  match apikey.verify_header(c, "x-api-key", accept_known) {
    Ok(k) => if k == "k_live_abcd1234" {
      Ok(())
    } else {
      Err("unexpected key")
    },
    Err(_) => Err("expected Ok for known key in x-api-key"),
  }
}

fn header_missing_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := ctx_with("GET", "/", "", map.new())
  match apikey.verify_header(c, "x-api-key", accept_known) {
    Ok(_) => Err("expected Err for missing header"),
    Err(r) => t.assert_status(r, 401),
  }
}

fn header_rejected_key_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := ctx_with_header("x-api-key", "wrong-token")
  match apikey.verify_header(c, "x-api-key", deny_all) {
    Ok(_) => Err("expected Err when valid returns false"),
    Err(r) => t.assert_status(r, 401),
  }
}

# ---- Query -------------------------------------------------------
fn query_valid_key_ok() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := ctx_with_query("api_key=k_live_abcd1234")
  match apikey.verify_query(c, "api_key", accept_known) {
    Ok(_) => Ok(()),
    Err(_) => Err("expected Ok for valid query api_key"),
  }
}

fn query_missing_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match apikey.verify_query(ctx_with("GET", "/", "", map.new()), "api_key", accept_known) {
    Ok(_) => Err("expected Err for missing query param"),
    Err(r) => t.assert_status(r, 401),
  }
}

# ---- Cookie ------------------------------------------------------
fn cookie_valid_key_ok() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := ctx_with_cookie("api_key=k_live_abcd1234")
  match apikey.verify_cookie(c, "api_key", accept_known) {
    Ok(_) => Ok(()),
    Err(_) => Err("expected Ok for valid cookie api_key"),
  }
}

fn cookie_missing_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match apikey.verify_cookie(ctx_with("GET", "/", "", map.new()), "api_key", accept_known) {
    Ok(_) => Err("expected Err for missing cookie"),
    Err(r) => t.assert_status(r, 401),
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] List[Result[Unit, Str]] {
  [header_valid_key_ok(), header_missing_returns_401(), header_rejected_key_returns_401(), query_valid_key_ok(), query_missing_returns_401(), cookie_valid_key_ok(), cookie_missing_returns_401()]
}

fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Unit {
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

