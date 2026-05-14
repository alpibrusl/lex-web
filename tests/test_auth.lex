# Tests for src/auth.lex (pure subset — no time effect)
#
# sign_hs256 and decode_unverified are both pure, so the sign→decode
# round-trip can run under lex test without --allow-effects.
# Tests that need verify_hs256 (expiry check) belong in the
# effectful suite once lex-web adds one.

import "std.bytes" as bytes
import "std.str"   as str
import "std.list"  as list

import "lex-crypto/jwt" as jwt

import "../src/auth" as auth

fn make_claims() -> jwt.Claims {
  { sub: "user-42", iss: "myapp", aud: "api", jti: "", exp: 0, nbf: 0, iat: 0 }
}

fn test_issue_claims_decode_roundtrip() -> Bool {
  let secret := bytes.from_str("test-secret-do-not-use-in-prod")
  let token  := auth.issue_claims(secret, make_claims())
  match jwt.decode_unverified(token) {
    Err(_) => false,
    Ok(c)  => c.sub == "user-42" and c.iss == "myapp",
  }
}

fn test_wrong_secret_gives_different_token() -> Bool {
  let s1     := bytes.from_str("secret-alpha")
  let s2     := bytes.from_str("secret-beta")
  let claims := make_claims()
  let t1     := auth.issue_claims(s1, claims)
  let t2     := auth.issue_claims(s2, claims)
  t1 != t2
}

fn test_hs256_token_has_three_parts() -> Bool {
  let secret := bytes.from_str("any-secret")
  let token  := auth.issue_claims(secret, make_claims())
  let parts  := str.split(token, ".")
  list.len(parts) == 3
}

fn run_all() -> () {
  assert test_issue_claims_decode_roundtrip()
  assert test_wrong_secret_gives_different_token()
  assert test_hs256_token_has_three_parts()
}
