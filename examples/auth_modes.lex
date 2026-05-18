# examples/auth_modes.lex — HTTP Basic + API key + JWT bearer
#
# Demonstrates the three auth helpers shipped in lex-web#26:
#   /basic       — HTTP Basic (admin:s3cret) via auth_basic.verify
#   /api         — API key in `X-Api-Key` header via auth_apikey.verify_header
#   /api-cookie  — API key in `Cookie: api_key=...` via auth_apikey.verify_cookie
#   /jwt         — JWT bearer via auth.verify_bearer (issued by /login)
#   /login       — issues a JWT for demo purposes
#
# Run:
#   lex run --allow-effects io,net,time,crypto,random,sql,fs_read,fs_write,concurrent \
#           examples/auth_modes.lex main
#
# Try:
#   curl -i -u admin:s3cret  http://localhost:8082/basic
#   curl -i -H 'X-Api-Key: k_live_abcd1234' http://localhost:8082/api
#   curl -i -b 'api_key=k_live_abcd1234' http://localhost:8082/api-cookie
#   TOKEN=$(curl -sX POST http://localhost:8082/login -d 'alice' | jq -r .token)
#   curl -i -H "Authorization: Bearer $TOKEN" http://localhost:8082/jwt

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.bytes" as bytes

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/auth" as auth

import "../src/auth_basic" as basic

import "../src/auth_apikey" as apikey

# ---- Shared config (production: load from environment) -----------
fn secret() -> Bytes {
  bytes.from_str("change-me-in-production")
}

fn valid_api_key(k :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool {
  k == "k_live_abcd1234"
}

fn check_basic(user :: Str, pw :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool {
  basic.passwords_equal(user, "admin") and basic.passwords_equal(pw, "s3cret")
}

# ---- Handlers ----------------------------------------------------
fn basic_protected(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match basic.verify(c, check_basic) {
    Err(r) => r,
    Ok(pair) => match pair {
      (user, _) => resp.json(str.concat("{\"scheme\":\"basic\",\"user\":\"", str.concat(user, "\"}"))),
    },
  }
}

fn apikey_header_protected(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match apikey.verify_header(c, "x-api-key", valid_api_key) {
    Err(r) => r,
    Ok(_) => resp.json("{\"scheme\":\"api-key-header\"}"),
  }
}

fn apikey_cookie_protected(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match apikey.verify_cookie(c, "api_key", valid_api_key) {
    Err(r) => r,
    Ok(_) => resp.json("{\"scheme\":\"api-key-cookie\"}"),
  }
}

fn jwt_protected(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match auth.verify_bearer(c, secret()) {
    Err(r) => r,
    Ok(claims) => resp.json(str.concat("{\"scheme\":\"jwt\",\"sub\":\"", str.concat(claims.sub, "\"}"))),
  }
}

fn issue_jwt(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  let sub := if str.is_empty(c.body) {
    "guest"
  } else {
    c.body
  }
  let token := auth.issue(secret(), sub, 3600)
  resp.json(str.concat("{\"token\":\"", str.concat(token, "\"}")))
}

# ---- App ---------------------------------------------------------
fn app() -> router.Router {
  ((((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/basic", basic_protected)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/api", apikey_header_protected)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/api-cookie", apikey_cookie_protected)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/jwt", jwt_protected)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "POST", "/login", issue_jwt)
  }
}

fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Unit {
  let __lex_discard_1 := io.print("auth-modes demo on :8082")
  let __lex_discard_2 := io.print("  GET  /basic      (admin:s3cret)")
  let __lex_discard_3 := io.print("  GET  /api        (X-Api-Key: k_live_abcd1234)")
  let __lex_discard_4 := io.print("  GET  /api-cookie (Cookie: api_key=k_live_abcd1234)")
  let __lex_discard_5 := io.print("  POST /login  →  JWT")
  let __lex_discard_6 := io.print("  GET  /jwt        (Authorization: Bearer <token>)")
  net.serve_fn(8082, handle)
}

