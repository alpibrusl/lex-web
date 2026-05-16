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

import "std.str" as str

import "std.crypto" as crypto

# ---- Signed tokens -----------------------------------------------
# Produce a `value.sig` token where sig = sha256(secret || value).
# Use for signed cookies or CSRF tokens that can be verified without
# a database lookup.
#
# Was previously `blake2b` over Str; lex-lang 0.9.4's std.crypto
# tightened `blake2b` to `Bytes -> Bytes`, so we switched to
# `sha256_str` (still Str-in, Str-out) to keep the public signature
# of `sign` / `verify` stable. blake2b remains available via the
# bytes-typed entry point for callers that want it.
fn sign(secret :: Str, value :: Str) -> Str {
  let sig := crypto.sha256_str(str.concat(secret, value))
  str.concat(value, str.concat(".", sig))
}

# Verify a token produced by `sign`. Extracts the embedded value on
# success; returns Err("bad signature") on any mismatch or format
# error. Uses constant-time comparison to prevent timing attacks.
fn verify(secret :: Str, token :: Str) -> Result[Str, Str] {
  match find_dot(token, str.len(token) - 1) {
    None => Err("invalid token format"),
    Some(dot) => {
      let value := str.slice(token, 0, dot)
      let sig := str.slice(token, dot + 1, str.len(token))
      let expected := crypto.sha256_str(str.concat(secret, value))
      if crypto.eq_str(sig, expected) {
        Ok(value)
      } else {
        Err("bad signature")
      }
    },
  }
}

# ---- Nonce / random IDs ------------------------------------------
# Generate a random hex string of `n` bytes (2n hex chars).
# Effects: `random` — `crypto.random_str_hex` reseeds from the OS RNG.
fn random_id(n :: Int) -> [crypto, random] Str {
  crypto.random_str_hex(n)
}

# 16-byte random nonce for AES-GCM / ChaCha20 (standard nonce length).
fn random_nonce() -> [crypto, random] Str {
  crypto.random_str_hex(16)
}

# ---- Webhook signature -------------------------------------------
# Verify an HMAC-style webhook signature.
# Many providers (Stripe, GitHub) compute HMAC-SHA256 over the raw body
# with a shared secret. This implementation uses sha256 as the MAC;
# callers wrapping real providers should compare expected hex values
# from the provider's docs against sha256_str(secret || body).
#
# Was `blake2b` over Str; lex-lang 0.9.4's std.crypto tightened
# `blake2b` to `Bytes -> Bytes`. `sha256_str` keeps the Str-in
# signature and is just as fit for the constant-time-eq use case.
fn verify_webhook(secret :: Str, body :: Str, sig :: Str) -> Bool {
  let expected := crypto.sha256_str(str.concat(secret, body))
  crypto.eq_str(sig, expected)
}

# ---- Symmetric encryption ----------------------------------------
#
# The 3-arg `encrypt(key, nonce, plaintext) -> Result[Str, Str]` and
# matching `decrypt` wrappers that used to live here were thin
# pass-throughs over `crypto.aes_gcm_encrypt` / `crypto.aes_gcm_decrypt`
# from before lex-lang 0.9.2. The 0.9.2 AEAD API is materially
# different: 4-arg `aes_gcm_seal(key, nonce, plaintext, aad)` returning
# `AeadResult { ciphertext, tag }`, and 5-arg `aes_gcm_open` taking
# `tag` separately and returning `Bytes` (not `Str`). Inputs and
# outputs are `Bytes`, not `Str`.
#
# The previous wrappers had zero in-tree callers (grep -rn returned
# nothing across src/ tests/ examples/ bench/), so we removed them
# instead of writing a marshalling layer with no client. The
# `crypto.aes_gcm_seal` / `crypto.aes_gcm_open` / `chacha20_poly1305_*`
# primitives are still callable directly from std.crypto for any
# caller that needs them.
# ---- Helpers ---------------------------------------------------------
# Scan from the right looking for the last '.' (used to split
# value.signature tokens). Returns None if no dot found.
fn find_dot(s :: Str, i :: Int) -> Option[Int] {
  if i < 0 {
    None
  } else {
    if str.slice(s, i, i + 1) == "." {
      Some(i)
    } else {
      find_dot(s, i - 1)
    }
  }
}

