# lex-web — crypto utilities
#
# Signing, verification, and encryption helpers built on std.crypto
# (lex-lang 0.9.2+). Covers the three patterns most HTTP services need:
#
#   - Signed opaque tokens for cookies and CSRF prevention
#   - Webhook signature verification (Stripe/GitHub style)
#   - Symmetric authenticated encryption for session payloads
#
# All signing uses blake2b (constant-length, fast, collision-resistant).
# Encryption uses AES-GCM with a caller-supplied nonce; callers should
# generate nonces with `random_nonce()`.
#
# Effects:
#   random_id / random_nonce — [crypto]
#   sign / verify / verify_webhook — none (pure)
#   encrypt / decrypt — none (pure; nonce is supplied by caller)

import "std.str"    as str
import "std.crypto" as crypto

# ---- Signed tokens -----------------------------------------------

# Produce a `value.sig` token where sig = blake2b(secret || value).
# Use for signed cookies or CSRF tokens that can be verified without
# a database lookup.
fn sign(secret :: Str, value :: Str) -> Str {
  let sig := crypto.blake2b(str.concat(secret, value))
  str.concat(value, str.concat(".", sig))
}

# Verify a token produced by `sign`. Extracts the embedded value on
# success; returns Err("bad signature") on any mismatch or format
# error. Uses constant-time comparison to prevent timing attacks.
fn verify(secret :: Str, token :: Str) -> Result[Str, Str] {
  match find_dot(token, str.len(token) - 1) {
    None      => Err("invalid token format"),
    Some(dot) => {
      let value    := str.slice(token, 0, dot)
      let sig      := str.slice(token, dot + 1, str.len(token))
      let expected := crypto.blake2b(str.concat(secret, value))
      if crypto.eq(sig, expected) { Ok(value) }
      else { Err("bad signature") }
    },
  }
}

# ---- Nonce / random IDs ------------------------------------------

# Generate a random hex string of `n` bytes (2n hex chars).
fn random_id(n :: Int) -> [crypto] Str {
  crypto.random_str_hex(n)
}

# 16-byte random nonce for AES-GCM / ChaCha20 (standard nonce length).
fn random_nonce() -> [crypto] Str {
  crypto.random_str_hex(16)
}

# ---- Webhook signature -------------------------------------------

# Verify an HMAC-style webhook signature.
# Many providers (Stripe, GitHub) compute HMAC-SHA256 over the raw body
# with a shared secret. This implementation uses blake2b as the MAC;
# callers wrapping real providers should compare expected hex values
# from the provider's docs against blake2b(secret || body).
fn verify_webhook(secret :: Str, body :: Str, sig :: Str) -> Bool {
  let expected := crypto.blake2b(str.concat(secret, body))
  crypto.eq(sig, expected)
}

# ---- Symmetric encryption ----------------------------------------

# Encrypt `plaintext` with AES-GCM. `key` must be a 32-byte hex string
# (64 hex chars = 256-bit key). `nonce` must be a 16-byte hex string
# (32 hex chars). Use `random_nonce()` to generate the nonce, then
# store it alongside the ciphertext (it is not secret).
fn encrypt(key :: Str, nonce :: Str, plaintext :: Str) -> Result[Str, Str] {
  crypto.aes_gcm_encrypt(key, nonce, plaintext)
}

# Decrypt a ciphertext produced by `encrypt`. Returns Err if the key,
# nonce, or ciphertext are wrong (authentication tag mismatch).
fn decrypt(key :: Str, nonce :: Str, ciphertext :: Str) -> Result[Str, Str] {
  crypto.aes_gcm_decrypt(key, nonce, ciphertext)
}

# ---- Helpers ---------------------------------------------------------

# Scan from the right looking for the last '.' (used to split
# value.signature tokens). Returns None if no dot found.
fn find_dot(s :: Str, i :: Int) -> Option[Int] {
  if i < 0 { None }
  else {
    if str.slice(s, i, i + 1) == "." { Some(i) }
    else { find_dot(s, i - 1) }
  }
}
