# Tests for src/auth_basic.lex (#26 — HTTP Basic).
#
# Each test builds a Ctx with a synthetic Authorization header,
# runs `basic.verify` with a pure check callback, and asserts the
# Ok / Err shape.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "../src/ctx" as ctx

import "../src/auth_basic" as basic

import "../src/testing" as t

# ---- Helpers -----------------------------------------------------
fn ctx_with_auth(value :: Str) -> ctx.Ctx {
  let hdrs := map.set(map.new(), "authorization", value)
  ctx.from_request({ method: "GET", path: "/", body: "", query: "", headers: hdrs }, map.new())
}

fn ctx_without_auth() -> ctx.Ctx {
  ctx.from_request({ method: "GET", path: "/", body: "", query: "", headers: map.new() }, map.new())
}

# Test callbacks declare the HEff effect row (matching the
# verify signature) but their bodies stay pure — Lex's effect
# rows are invariant, so we sign the wider contract here. Same
# pattern handler bodies use under route_effectful.
fn accept_admin(user :: Str, pw :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool {
  basic.passwords_equal(user, "admin") and basic.passwords_equal(pw, "s3cret")
}

fn deny_all(_u :: Str, _p :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool {
  false
}

# ---- Tests -------------------------------------------------------
# `Basic YWRtaW46czNjcmV0` decodes to `admin:s3cret` — the
# check callback accepts it, verify returns Ok.
fn valid_credentials_ok() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := ctx_with_auth("Basic YWRtaW46czNjcmV0")
  match basic.verify(c, accept_admin) {
    Ok(pair) => match pair {
      (user, _) => if user == "admin" {
        Ok(())
      } else {
        Err(str.concat("expected user=admin, got: ", user))
      },
    },
    Err(_) => Err("expected Ok for valid admin:s3cret credentials"),
  }
}

# Missing Authorization header → 401 + WWW-Authenticate: Basic
# realm="..." per RFC 7617 §2.
fn missing_header_returns_401_with_challenge() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match basic.verify(ctx_without_auth(), accept_admin) {
    Ok(_) => Err("expected Err for missing header"),
    Err(r) => if r.status == 401 {
      match map.get(r.headers, "www-authenticate") {
        Some(v) => if str.contains(v, "Basic realm=") {
          Ok(())
        } else {
          Err(str.concat("expected Basic realm= challenge, got: ", v))
        },
        None => Err("expected www-authenticate header"),
      }
    } else {
      Err("expected status 401")
    },
  }
}

# Malformed base64 → treated as missing-header / 401.
fn malformed_base64_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match basic.verify(ctx_with_auth("Basic !!!not-b64!!!"), accept_admin) {
    Ok(_) => Err("expected Err for malformed base64"),
    Err(r) => if r.status == 401 {
      Ok(())
    } else {
      Err("expected status 401")
    },
  }
}

# Header without "Basic " prefix → not Basic auth, treated as
# missing. (Server might also be running JWT bearer auth on the
# same endpoint via auth.verify_bearer; the two helpers are
# independent.)
fn missing_basic_prefix_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match basic.verify(ctx_with_auth("Bearer some-jwt"), accept_admin) {
    Ok(_) => Err("expected Err for non-Basic scheme"),
    Err(r) => if r.status == 401 {
      Ok(())
    } else {
      Err("expected status 401")
    },
  }
}

# Valid header shape, wrong credentials → 401 with the SAME
# challenge so timing observers can't distinguish "user exists,
# wrong password" from "user doesn't exist". RFC 7617 §4.4.
fn wrong_credentials_returns_401() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match basic.verify(ctx_with_auth("Basic YWRtaW46czNjcmV0"), deny_all) {
    Ok(_) => Err("expected Err when check rejects"),
    Err(r) => if r.status == 401 {
      Ok(())
    } else {
      Err("expected status 401")
    },
  }
}

# Lowercase `basic` scheme is accepted (HTTP scheme names are
# case-insensitive per RFC 7235 §2.1).
fn lowercase_scheme_accepted() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match basic.verify(ctx_with_auth("basic YWRtaW46czNjcmV0"), accept_admin) {
    Ok(_) => Ok(()),
    Err(_) => Err("expected lowercase `basic` scheme to be accepted"),
  }
}

# Password containing colons is decoded correctly — only the first
# colon separates user from pass per RFC 7617.
fn password_with_colons_round_trips() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let c := ctx_with_auth("Basic dXNlcjpwOmFAcw==")
  match basic.verify(c, fn (u :: Str, p :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool {
    basic.passwords_equal(u, "user") and basic.passwords_equal(p, "p:a@s")
  }) {
    Ok(_) => Ok(()),
    Err(_) => Err("expected user=user / pass=p:a@s decode"),
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] List[Result[Unit, Str]] {
  [valid_credentials_ok(), missing_header_returns_401_with_challenge(), malformed_base64_returns_401(), missing_basic_prefix_returns_401(), wrong_credentials_returns_401(), lowercase_scheme_accepted(), password_with_colons_round_trips()]
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

