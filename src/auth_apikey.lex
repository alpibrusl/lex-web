# lex-web — API key authentication
#
# Three thin extractors for the API-key-in-{header,query,cookie}
# pattern. Each returns `Result[Str, resp.Response]`: `Ok(key)`
# on a present key that the caller's `valid` callback accepts,
# `Err(401)` otherwise. Mirrors FastAPI's `APIKeyHeader` /
# `APIKeyQuery` / `APIKeyCookie`.
#
# Pattern:
#
#   match apikey.verify_header(c, "x-api-key", check_key) {
#     Err(r)   => r,
#     Ok(key)  => resp.json("{\"ok\":true}"),
#   }
#
# `valid` is a caller-supplied `(Str) -> [E] Bool` — typically a
# constant-time compare against a stored token (use
# `crypto.constant_time_eq` on `bytes.from_str(...)`). Effect row
# `[E]` propagates so a DB-backed check works.
#
# Issue: lex-web#26.

import "std.str" as str

import "./ctx" as ctx

import "./response" as resp

# ---- Header-based API key ----------------------------------------
#
# `verify_header(c, name, valid)` reads the header `name`
# (case-insensitive — ctx.header lower-cases on the way in) and
# calls `valid(key)`. Missing → 401 with an `x-error: api key
# required` header.
fn verify_header(c :: ctx.Ctx, name :: Str, valid :: (Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Str, resp.Response] {
  match ctx.header(c, name) {
    None => Err(missing_key_response(str.concat("header ", name))),
    Some(key) => if valid(key) {
      Ok(key)
    } else {
      Err(invalid_key_response())
    },
  }
}

# ---- Query-string API key ----------------------------------------
#
# `verify_query(c, name, valid)` reads `?<name>=<key>` from the
# request URL and calls `valid`. Useful for SDK integrations that
# can't easily set custom headers (some browser-based clients,
# legacy proxies).
#
# Note: API keys in URLs leak into access logs and `Referer`
# headers. Prefer header- or cookie-based extraction in
# production. This helper exists for compatibility, not as a
# recommended pattern.
fn verify_query(c :: ctx.Ctx, name :: Str, valid :: (Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Str, resp.Response] {
  match ctx.query_param(c, name) {
    None => Err(missing_key_response(str.concat("query parameter ", name))),
    Some(key) => if valid(key) {
      Ok(key)
    } else {
      Err(invalid_key_response())
    },
  }
}

# ---- Cookie API key ----------------------------------------------
#
# `verify_cookie(c, name, valid)` reads cookie `name` and calls
# `valid`. SameSite / Secure attributes are the caller's
# responsibility on the `Set-Cookie` side; this helper only
# extracts the value at request time.
fn verify_cookie(c :: ctx.Ctx, name :: Str, valid :: (Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Bool) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Str, resp.Response] {
  match ctx.cookie(c, name) {
    None => Err(missing_key_response(str.concat("cookie ", name))),
    Some(key) => if valid(key) {
      Ok(key)
    } else {
      Err(invalid_key_response())
    },
  }
}

# ---- Response builders -------------------------------------------
fn missing_key_response(where :: Str) -> resp.Response {
  resp.unauthorized(str.concat("API key required in ", where))
}

fn invalid_key_response() -> resp.Response {
  resp.unauthorized("invalid API key")
}

