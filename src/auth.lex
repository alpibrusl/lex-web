# lex-web — JWT bearer authentication
#
# Wraps lex-crypto/jwt for the common pattern of HS256 Bearer-token
# auth on JSON APIs. Provides verify/issue helpers that integrate
# with Ctx and Response so handler bodies stay one-liners:
#
#   match auth.verify_bearer(c, secret) {
#     Err(r)       => r,
#     Ok(claims)   => resp.json("{\"sub\":\"" + claims.sub + "\"}")
#   }
#
# Effects:
#   verify_bearer — [time]  (expiry check calls time.now())
#   issue         — [time]  (stamps iat/nbf/exp with time.now())
#   issue_claims  — pure    (caller controls all claim fields)

import "std.bytes" as bytes
import "std.time"  as time

import "lex-crypto/jwt" as jwt

import "./ctx"      as ctx
import "./response" as resp

# ---- Verification -----------------------------------------------

# Verify the Bearer token from the Authorization header.
# Returns Ok(claims) on success; Err(Response) with a 401 on any
# failure so the handler can return it directly:
#
#   match auth.verify_bearer(c, secret) {
#     Err(r)     => r,
#     Ok(claims) => resp.json("..."),
#   }
fn verify_bearer(
  c      :: ctx.Ctx,
  secret :: Bytes
) -> [time] Result[jwt.Claims, resp.Response] {
  match ctx.bearer_token(c) {
    None        => Err(resp.unauthorized("missing Bearer token")),
    Some(token) => match jwt.verify_hs256(secret, token) {
      Ok(claims)           => Ok(claims),
      Err(jwt.Expired)     => Err(resp.unauthorized("token expired")),
      Err(jwt.NotYetValid) => Err(resp.unauthorized("token not yet valid")),
      Err(_)               => Err(resp.unauthorized("invalid token")),
    },
  }
}

# ---- Token issuance ---------------------------------------------

# Issue a HS256 JWT for `sub` that expires in `ttl_secs` seconds.
# Common values: 3600 (1 h session), 86400 (1 day), 604800 (1 week).
# Use bytes.from_str(secret_str) if your secret lives as a Str.
fn issue(secret :: Bytes, sub :: Str, ttl_secs :: Int) -> [time] Str {
  let now    := time.now()
  let claims := {
    sub: sub, iss: "", aud: "", jti: "",
    exp: now + ttl_secs, nbf: now, iat: now,
  }
  jwt.sign_hs256(secret, claims)
}

# Issue with full claim control. Caller is responsible for setting
# exp / nbf / iat. Set exp: 0 to disable expiry checks on verify.
fn issue_claims(secret :: Bytes, claims :: jwt.Claims) -> Str {
  jwt.sign_hs256(secret, claims)
}
