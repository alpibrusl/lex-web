# lex-web — HTTP Basic authentication (RFC 7617)
#
# Wraps the `Authorization: Basic <base64(user:pass)>` flow with
# constant-time password comparison via std.crypto. Mirrors the
# shape of `auth.lex` (JWT bearer): every helper returns
# `Result[T, resp.Response]` so handlers stay one-liners:
#
#   match basic.verify(c, check_password) {
#     Err(r)        => r,
#     Ok((user, _)) => resp.json(str.concat("{\"sub\":\"", str.concat(user, "\"}"))),
#   }
#
# `check_password` is a caller-supplied `(Str, Str) -> [HEff] Bool`
# — typically a constant-time compare against a hashed value in a
# database. The framework only does the wire-level decode; auth
# decisions belong to the application.
#
# Effects:
#   verify             — propagates the caller's `check` effect row
#   decode_credentials — pure  (just unwraps the header)
#
# Issue: lex-web#26.

import "std.str" as str

import "std.crypto" as crypto

import "./ctx" as ctx

import "./response" as resp

# ---- Decode the Authorization header without verifying ----------
#
# `decode_credentials(c)` returns `Some((user, pass))` if a
# well-formed `Authorization: Basic <b64>` header is present,
# `None` otherwise. Use this when you want custom error handling;
# most callers want `verify` below.
#
# Pure — no constant-time work happens here. The base64 decode
# can fail; that surfaces as `None`, identical to a missing header.
fn decode_credentials(c :: ctx.Ctx) -> Option[(Str, Str)] {
  match ctx.header(c, "authorization") {
    None => None,
    Some(raw) => match str.strip_prefix(raw, "Basic ") {
      None => match str.strip_prefix(raw, "basic ") {
        None => None,
        Some(b64) => decode_b64_pair(b64),
      },
      Some(b64) => decode_b64_pair(b64),
    },
  }
}

# Split a decoded `user:pass` Str on the first ':'. RFC 7617 says
# the colon is the separator and that user-id MUST NOT contain a
# colon; pass MAY. `None` if the decoded payload has no colon at
# all (malformed). Iterates characters via a slice-and-check loop
# since Lex's pattern syntax doesn't support list-literal patterns
# (which would have been the natural fit here).
fn split_user_pass(decoded :: Str) -> Option[(Str, Str)] {
  let n := str.len(decoded)
  let idx := find_colon(decoded, 0, n)
  if idx < 0 {
    None
  } else {
    Some((str.slice(decoded, 0, idx), str.slice(decoded, idx + 1, n)))
  }
}

# Linear scan for the first ':' character. Returns -1 if absent.
# Uses `str.slice(s, i, i+1)` as a 1-char read — Lex has no direct
# index-into-Str primitive on the 0.9.5 toolchain.
fn find_colon(s :: Str, i :: Int, n :: Int) -> Int {
  if i >= n {
    -1
  } else {
    if str.slice(s, i, i + 1) == ":" {
      i
    } else {
      find_colon(s, i + 1, n)
    }
  }
}

fn decode_b64_pair(b64 :: Str) -> Option[(Str, Str)] {
  match crypto.base64_decode(b64) {
    Err(_) => None,
    Ok(bs) => match bytes_to_str(bs) {
      None => None,
      Some(decoded) => split_user_pass(decoded),
    },
  }
}

# Bridge from Bytes to Str. Returns None if the decoded bytes
# aren't valid UTF-8 — a malformed Basic header that decodes to
# garbage shouldn't pretend to be a real credential.
fn bytes_to_str(b :: Bytes) -> Option[Str] {
  match std_bytes_to_str(b) {
    Err(_) => None,
    Ok(s) => Some(s),
  }
}

# Wrapper around std.bytes.to_str so the import lives in one place
# (the std.bytes import is unused elsewhere in this module).
import "std.bytes" as bytes

fn std_bytes_to_str(b :: Bytes) -> Result[Str, Str] {
  bytes.to_str(b)
}

# ---- Verification ------------------------------------------------
#
# `verify(c, check)`:
#   - Reads the Authorization header
#   - Decodes the base64 payload
#   - Calls `check(user, pass)` — caller's authoritative test,
#     typically a constant-time compare against a stored hash
#   - Returns `Ok((user, pass))` on success, `Err(401 Response)` on
#     missing / malformed / rejected credentials
#
# Note that `pass` is returned plain on Ok — the caller decided
# the credential is valid, so handing back the password lets the
# handler use it (e.g., to feed into a downstream auth proxy).
# Most callers ignore it (`Ok((user, _))`).
#
# `check`'s effect row is fixed at HEff so DB-backed compares (the
# common production case) work. Pure check callbacks need to be
# declared with the HEff annotation too — Lex's effect rows are
# invariant and pure fns don't auto-widen to effectful. The body
# stays pure; only the type signature carries the row. See
# `tests/test_auth_basic.lex` for the pattern.
fn verify(c :: ctx.Ctx, check :: (Str, Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[(Str, Str), resp.Response] {
  match decode_credentials(c) {
    None => Err(unauthorized_with_realm("Restricted")),
    Some(pair) => match pair {
      (user, pw) => if check(user, pw) {
        Ok((user, pw))
      } else {
        Err(unauthorized_with_realm("Restricted"))
      },
    },
  }
}

# ---- Constant-time compare ---------------------------------------
#
# Convenience for the most common `check` case: "is the password
# this exact constant?". Use this directly when the secret is a
# fixed string (admin endpoint with a static password); use
# `verify` with a callback that does a hashed compare for anything
# that lives in a database.
#
# Pure — wraps `crypto.constant_time_eq`.
fn passwords_equal(submitted :: Str, expected :: Str) -> Bool {
  crypto.constant_time_eq(bytes.from_str(submitted), bytes.from_str(expected))
}

# ---- Helpers -----------------------------------------------------
#
# RFC 7617 §2: the WWW-Authenticate response header SHOULD carry
# `Basic realm="<name>"`. Wrap that pattern.
fn unauthorized_with_realm(realm :: Str) -> resp.Response {
  let challenge := str.concat("Basic realm=\"", str.concat(realm, "\""))
  resp.with_header(resp.unauthorized("authentication required"), "www-authenticate", challenge)
}

