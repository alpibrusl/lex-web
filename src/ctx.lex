# lex-web — request context
#
# Wraps the raw net.serve Request into a richer Ctx that carries
# pre-parsed path parameters (bound by the router during dispatch),
# lazily-parsed query-param and cookie maps, and typed header
# accessors.
#
# Effects: none. Ctx is a pure value.

import "std.str" as str

import "std.list" as list

import "std.map" as map

# Mirrors the Request record that net.serve_fn passes to every handler.
# Defined locally so this module has no std.net import dependency;
# callers that already import std.net can use structural equivalence.
type RawRequest = { body :: Str, method :: Str, path :: Str, query :: Str, headers :: Map[Str, Str] }

# Enriched context threaded through every handler and middleware.
# `state` is a per-request scratchpad — handlers and middleware
# stash strings under named keys so downstream middleware /
# handlers can read them. FastAPI's `request.state.x` in
# concept; Str-typed here because Lex doesn't have an "any" type
# at the framework level. Wrap structured state in JSON via
# `jv.stringify` if needed; the common case (request-id,
# user-id, trace context, A/B bucket) is already Str.
type Ctx = { method :: Str, path :: Str, query :: Str, body :: Str, path_params :: Map[Str, Str], headers :: Map[Str, Str], state :: Map[Str, Str] }

# Build a Ctx from the raw request + the param bindings the
# router extracted during segment matching. `state` starts empty;
# middleware populates it via `set_state` for downstream stages.
fn from_request(req :: RawRequest, params :: Map[Str, Str]) -> Ctx {
  { method: req.method, path: req.path, query: req.query, body: req.body, path_params: params, headers: req.headers, state: map.new() }
}

fn from_request_with_headers(req :: RawRequest, params :: Map[Str, Str], hdrs :: Map[Str, Str]) -> Ctx {
  { method: req.method, path: req.path, query: req.query, body: req.body, path_params: params, headers: hdrs, state: map.new() }
}

# ---- State bag --------------------------------------------------
#
# Cross-handler / cross-middleware data sharing. Set in a pre-
# middleware hook, read in a handler or post-middleware hook.
# Returns a NEW Ctx — Lex values are immutable, so callers thread
# the updated Ctx through their dispatch chain:
#
#   match mw_auth.verify(c) {
#     Err(r)     => Short(r),
#     Ok(user)   => Continue(ctx.set_state(c, "user-id", user.id)),
#   }
#
# Later in the handler:
#
#   match ctx.get_state(c, "user-id") {
#     Some(uid) => greet(uid),
#     None      => resp.bad_request("auth middleware did not set user-id"),
#   }
fn set_state(c :: Ctx, key :: Str, value :: Str) -> Ctx {
  { method: c.method, path: c.path, query: c.query, body: c.body, path_params: c.path_params, headers: c.headers, state: map.set(c.state, key, value) }
}

fn get_state(c :: Ctx, key :: Str) -> Option[Str] {
  map.get(c.state, key)
}

# Read state with a default. Convenience for the common
# "use this value if middleware set it, fall back otherwise" case.
fn get_state_or(c :: Ctx, key :: Str, default :: Str) -> Str {
  match map.get(c.state, key) {
    Some(v) => v,
    None => default,
  }
}

# ---- Path-param accessors ----------------------------------------
fn path_param(ctx :: Ctx, name :: Str) -> Option[Str] {
  map.get(ctx.path_params, name)
}

fn require_path_param(ctx :: Ctx, name :: Str) -> Result[Str, Str] {
  match map.get(ctx.path_params, name) {
    Some(v) => Ok(v),
    None => Err(str.concat("missing path param: ", name)),
  }
}

# ---- Query-param accessors ---------------------------------------
# Parses `?a=1&b=hello` on every call. For hot paths bind with
# `let q := query_map(ctx)` to avoid repeated parsing.
fn query_map(ctx :: Ctx) -> Map[Str, Str] {
  let raw := strip_leading_q(ctx.query)
  if str.is_empty(raw) {
    map.new()
  } else {
    let pairs := list.map(str.split(raw, "&"), fn (kv :: Str) -> (Str, Str) {
      split_eq_pair(kv)
    })
    map.from_list(pairs)
  }
}

fn query_param(ctx :: Ctx, name :: Str) -> Option[Str] {
  map.get(query_map(ctx), name)
}

fn query_param_or(ctx :: Ctx, name :: Str, default :: Str) -> Str {
  match map.get(query_map(ctx), name) {
    Some(v) => v,
    None => default,
  }
}

# ---- Header accessors --------------------------------------------
# Expects lower-cased names; the runtime should lower-case incoming
# headers at the net.serve boundary.
fn header(ctx :: Ctx, name :: Str) -> Option[Str] {
  map.get(ctx.headers, str.to_lower(name))
}

fn header_or(ctx :: Ctx, name :: Str, default :: Str) -> Str {
  match header(ctx, name) {
    Some(v) => v,
    None => default,
  }
}

fn content_type(ctx :: Ctx) -> Str {
  header_or(ctx, "content-type", "")
}

# Returns the token from `Authorization: Bearer <token>`.
fn bearer_token(ctx :: Ctx) -> Option[Str] {
  match header(ctx, "authorization") {
    None => None,
    Some(v) => str.strip_prefix(v, "Bearer "),
  }
}

# ---- Cookie accessors --------------------------------------------
fn cookie_map(ctx :: Ctx) -> Map[Str, Str] {
  match header(ctx, "cookie") {
    None => map.new(),
    Some(c) => map.from_list(list.map(str.split(c, "; "), fn (kv :: Str) -> (Str, Str) {
      split_eq_pair(kv)
    })),
  }
}

fn cookie(ctx :: Ctx, name :: Str) -> Option[Str] {
  map.get(cookie_map(ctx), name)
}

# ---- Internal helpers --------------------------------------------
fn strip_leading_q(s :: Str) -> Str {
  match str.strip_prefix(s, "?") {
    Some(rest) => rest,
    None => s,
  }
}

# Split `key=value` into (key, value). A bare key with no `=`
# binds to the empty string, matching URLSearchParams behaviour.
fn split_eq_pair(kv :: Str) -> (Str, Str) {
  match find_char(kv, "=", 0) {
    None => (kv, ""),
    Some(i) => (str.slice(kv, 0, i), str.slice(kv, i + 1, str.len(kv))),
  }
}

fn find_char(s :: Str, c :: Str, i :: Int) -> Option[Int] {
  if i >= str.len(s) {
    None
  } else {
    if str.slice(s, i, i + 1) == c {
      Some(i)
    } else {
      find_char(s, c, i + 1)
    }
  }
}

