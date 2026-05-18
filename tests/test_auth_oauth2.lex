# Tests for src/auth_oauth2.lex (#26 slice 2).
#
# Two phases:
#   1. `verify_oauth2_bearer` + `require_scopes` runtime behaviour
#      under a synthetic `validate` callback.
#   2. `to_openapi` schema-emission round-trip — assert the
#      JSON fragment carries the right keys per OpenAPI 3.1.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "lex-schema/json_value" as jv

import "../src/ctx" as ctx

import "../src/auth_oauth2" as o2

import "../src/testing" as t

# ---- Helpers -----------------------------------------------------
fn ctx_with_bearer(token :: Str) -> ctx.Ctx {
  let hdrs := map.set(map.new(), "authorization", str.concat("Bearer ", token))
  ctx.from_request({ method: "GET", path: "/", body: "", query: "", headers: hdrs }, map.new())
}

fn ctx_no_bearer() -> ctx.Ctx {
  ctx.from_request({ method: "GET", path: "/", body: "", query: "", headers: map.new() }, map.new())
}

# Validate callback: accepts only the token "good-token" and
# yields claims with two scopes.
fn validate_good(token :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[o2.Claims, Str] {
  if token == "good-token" {
    Ok({ sub: "user-42", scopes: ["read:items", "write:items"] })
  } else {
    Err("invalid token")
  }
}

fn validate_no_scopes(_t :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[o2.Claims, Str] {
  Ok({ sub: "user-42", scopes: [] })
}

# ---- verify_oauth2_bearer ---------------------------------------
fn valid_bearer_returns_claims() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := ctx_with_bearer("good-token")
  match o2.verify_oauth2_bearer(c, validate_good) {
    Ok(claims) => if claims.sub == "user-42" {
      Ok(())
    } else {
      Err(str.concat("unexpected sub: ", claims.sub))
    },
    Err(_) => Err("expected Ok for good-token"),
  }
}

fn missing_bearer_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match o2.verify_oauth2_bearer(ctx_no_bearer(), validate_good) {
    Ok(_) => Err("expected Err for missing bearer"),
    Err(r) => t.assert_status(r, 401),
  }
}

fn validate_failure_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match o2.verify_oauth2_bearer(ctx_with_bearer("nope"), validate_good) {
    Ok(_) => Err("expected Err when validate rejects"),
    Err(r) => t.assert_status(r, 401),
  }
}

# ---- require_scopes ---------------------------------------------
fn require_scopes_passes_when_all_present() -> Result[Unit, Str] {
  let claims := { sub: "u", scopes: ["read:items", "write:items", "admin"] }
  match o2.require_scopes(claims, ["read:items", "admin"]) {
    Ok(_) => Ok(()),
    Err(_) => Err("expected Ok when all required scopes present"),
  }
}

fn require_scopes_403s_when_any_missing() -> Result[Unit, Str] {
  let claims := { sub: "u", scopes: ["read:items"] }
  match o2.require_scopes(claims, ["read:items", "write:items"]) {
    Ok(_) => Err("expected Err when write:items missing"),
    Err(r) => if r.status == 403 and str.contains(r.body, "write:items") {
      Ok(())
    } else {
      Err(str.concat("expected 403 mentioning write:items, got: ", r.body))
    },
  }
}

fn require_scopes_empty_required_is_ok() -> Result[Unit, Str] {
  let claims := { sub: "u", scopes: [] }
  match o2.require_scopes(claims, []) {
    Ok(_) => Ok(()),
    Err(_) => Err("expected Ok for empty required-scopes list"),
  }
}

# ---- OpenAPI emit -----------------------------------------------
fn password_scheme_emits_openapi_fragment() -> Result[Unit, Str] {
  let scopes := map.set(map.set(map.new(), "read:items", "read items"), "write:items", "write items")
  let scheme := o2.scheme_password("api-auth", "/login", scopes)
  let json := o2.to_openapi(scheme)
  let serialised := jv.stringify(json)
  if str.contains(serialised, "\"type\":\"oauth2\"") and str.contains(serialised, "\"password\"") and str.contains(serialised, "\"tokenUrl\":\"/login\"") and str.contains(serialised, "\"read:items\"") {
    Ok(())
  } else {
    Err(str.concat("unexpected password scheme fragment: ", serialised))
  }
}

fn auth_code_scheme_emits_openapi_fragment() -> Result[Unit, Str] {
  let scopes := map.set(map.new(), "openid", "openid scope")
  let scheme := o2.scheme_auth_code("oidc", "https://idp/authorize", "https://idp/token", scopes)
  let serialised := jv.stringify(o2.to_openapi(scheme))
  if str.contains(serialised, "\"authorizationCode\"") and str.contains(serialised, "\"authorizationUrl\":\"https://idp/authorize\"") and str.contains(serialised, "\"tokenUrl\":\"https://idp/token\"") {
    Ok(())
  } else {
    Err(str.concat("unexpected auth_code scheme fragment: ", serialised))
  }
}

fn client_creds_scheme_emits_openapi_fragment() -> Result[Unit, Str] {
  let scheme := o2.scheme_client_creds("m2m", "/oauth/token", map.new())
  let serialised := jv.stringify(o2.to_openapi(scheme))
  if str.contains(serialised, "\"clientCredentials\"") and str.contains(serialised, "\"tokenUrl\":\"/oauth/token\"") {
    Ok(())
  } else {
    Err(str.concat("unexpected client_creds fragment: ", serialised))
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] List[Result[Unit, Str]] {
  [valid_bearer_returns_claims(), missing_bearer_returns_401(), validate_failure_returns_401(), require_scopes_passes_when_all_present(), require_scopes_403s_when_any_missing(), require_scopes_empty_required_is_ok(), password_scheme_emits_openapi_fragment(), auth_code_scheme_emits_openapi_fragment(), client_creds_scheme_emits_openapi_fragment()]
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

