# lex-web — OAuth2 bearer authentication + OpenAPI scheme (#26)
#
# OAuth2 verification at runtime is mostly the same Bearer-token
# extraction as `auth.verify_bearer` — what makes OAuth2 distinct
# is the OpenAPI scheme declaration that lets Swagger UI render
# the "Authorize" flow, and the scope-checking convention. This
# module supplies:
#
#   - `OAuth2Flow` variants for Password / AuthorizationCode /
#     ClientCredentials (the three RFC 6749 flows lex-web supports
#     in v1 — Implicit is deprecated and not added)
#   - `OAuth2Scheme` — name + flow, registered on the Router via
#     `router.add_security_scheme` and referenced from RouteMeta
#   - `verify_oauth2_bearer(c, validate)` — read the Bearer token,
#     call the caller's `validate` callback (typically a JWT verify
#     or a remote token-introspection round-trip), return
#     `Result[Claims, Response]`
#   - `require_scopes(claims, required)` — check that the verified
#     claims carry every requested scope
#   - `scheme_password` / `scheme_auth_code` / `scheme_client_creds`
#     constructors that build OAuth2Scheme values
#   - `to_openapi(scheme)` — emit the JSON fragment that lives
#     under `components.securitySchemes.<name>` in the OpenAPI doc
#
# Pattern:
#
#   let oauth := o2.scheme_password("api-auth", "/login",
#                  map.from_list([("read:items", "read items"),
#                                 ("write:items", "write items")]))
#   let app := router.new()
#               |> fn (r) -> router.Router { router.add_security_scheme(r, oauth) }
#               |> fn (r) -> router.Router {
#                    router.route_effectful_with_meta(r, "GET", "/items", list_items,
#                      router.with_security(router.empty_meta(), "api-auth", ["read:items"]))
#                  }
#
# Inside the handler:
#
#   fn list_items(c :: ctx.Ctx) -> [HEff] resp.Response {
#     match o2.verify_oauth2_bearer(c, my_validate_jwt) {
#       Err(r) => r,
#       Ok(claims) => match o2.require_scopes(claims, ["read:items"]) {
#         Err(r) => r,
#         Ok(_) => resp.json("..."),
#       },
#     }
#   }
#
# `validate` is the production hook: returns `Result[Claims, Str]`
# from any source — local JWT verify, /introspect HTTP call, etc.
#
# Issue: lex-web#26 (slice 2 of 2).

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "lex-schema/json_value" as jv

import "./ctx" as ctx

import "./response" as resp

# ---- Public types ------------------------------------------------
# A verified OAuth2 token's claims, as projected by the caller's
# `validate` callback. `sub` is the subject (user id / client id);
# `scopes` is the list of granted scope strings parsed from the
# token's `scope` claim (or wherever the issuer puts them — the
# callback decides).
type Claims = { sub :: Str, scopes :: List[Str] }

# RFC 6749 flow shapes — each carries the URLs Swagger UI needs to
# render the Authorize button + the scope catalogue. The scope
# map is `name -> description` (description shown in the consent
# screen). Refresh URL is "" if not supported.
type OAuth2Flow = Password({ token_url :: Str, refresh_url :: Str, scopes :: Map[Str, Str] }) | AuthorizationCode({ authorization_url :: Str, token_url :: Str, refresh_url :: Str, scopes :: Map[Str, Str] }) | ClientCredentials({ token_url :: Str, refresh_url :: Str, scopes :: Map[Str, Str] })

type OAuth2Scheme = { name :: Str, description :: Str, flow :: OAuth2Flow }

# ---- Constructors ------------------------------------------------
fn scheme_password(name :: Str, token_url :: Str, scopes :: Map[Str, Str]) -> OAuth2Scheme {
  { name: name, description: "", flow: Password({ token_url: token_url, refresh_url: "", scopes: scopes }) }
}

fn scheme_auth_code(name :: Str, authorization_url :: Str, token_url :: Str, scopes :: Map[Str, Str]) -> OAuth2Scheme {
  { name: name, description: "", flow: AuthorizationCode({ authorization_url: authorization_url, token_url: token_url, refresh_url: "", scopes: scopes }) }
}

fn scheme_client_creds(name :: Str, token_url :: Str, scopes :: Map[Str, Str]) -> OAuth2Scheme {
  { name: name, description: "", flow: ClientCredentials({ token_url: token_url, refresh_url: "", scopes: scopes }) }
}

fn with_description(s :: OAuth2Scheme, description :: Str) -> OAuth2Scheme {
  { name: s.name, description: description, flow: s.flow }
}

# ---- Verification ------------------------------------------------
# Read the Bearer token from the Authorization header and pass it
# to `validate`. `validate` does the actual cryptographic /
# introspection work — usually a JWT signature check via
# `lex-crypto/jwt` or a remote /introspect call. Returns
# `Ok(claims)` on success, `Err(401 Response)` on missing /
# rejected token.
#
# `validate`'s effect row is fixed at HEff so introspection over
# the network or a DB-backed token store works. Pure validators
# (verify HS256 locally) need to declare the wide row in their
# signature — same pattern as auth_basic.lex.
fn verify_oauth2_bearer(c :: ctx.Ctx, validate :: (Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Claims, Str]) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Claims, resp.Response] {
  match ctx.bearer_token(c) {
    None => Err(resp.unauthorized("missing Bearer token")),
    Some(token) => match validate(token) {
      Ok(claims) => Ok(claims),
      Err(reason) => Err(resp.unauthorized(reason)),
    },
  }
}

# Check that `claims.scopes` contains every entry in `required`.
# Returns `Ok(())` on full coverage, `Err(403 Response)` with the
# missing scopes in the body when one or more are absent.
#
# 403 (Forbidden) not 401 (Unauthorized) — the token is valid,
# the token-bearer just isn't authorized for this operation per
# RFC 6750 §3.1.
fn require_scopes(claims :: Claims, required :: List[Str]) -> Result[Unit, resp.Response] {
  let missing := list.fold(required, [], fn (acc :: List[Str], scope :: Str) -> List[Str] {
    if has_scope(claims.scopes, scope) {
      acc
    } else {
      list.concat(acc, [scope])
    }
  })
  if list.len(missing) == 0 {
    Ok(())
  } else {
    Err(resp.forbidden(str.concat("insufficient scopes; missing: ", str.join(missing, " "))))
  }
}

fn has_scope(have :: List[Str], scope :: Str) -> Bool {
  list.fold(have, false, fn (acc :: Bool, s :: Str) -> Bool {
    acc or s == scope
  })
}

# ---- OpenAPI emit ------------------------------------------------
# Build the JSON fragment that goes under
# `components.securitySchemes.<scheme.name>` per OpenAPI 3.1
# §securityScheme. Always emits `type: oauth2` and one entry in
# `flows`; lex-web doesn't combine multiple flows on one scheme
# in v1 (each scheme is single-flow — register multiple schemes
# for multi-flow support).
fn to_openapi(scheme :: OAuth2Scheme) -> jv.Json {
  let base := [("type", JStr("oauth2"))]
  let with_desc := if str.is_empty(scheme.description) {
    base
  } else {
    list.concat(base, [("description", JStr(scheme.description))])
  }
  JObj(list.concat(with_desc, [("flows", flow_object(scheme.flow))]))
}

fn flow_object(flow :: OAuth2Flow) -> jv.Json {
  match flow {
    Password(p) => JObj([("password", flow_password(p))]),
    AuthorizationCode(ac) => JObj([("authorizationCode", flow_auth_code(ac))]),
    ClientCredentials(cc) => JObj([("clientCredentials", flow_client_creds(cc))]),
  }
}

fn flow_password(p :: { token_url :: Str, refresh_url :: Str, scopes :: Map[Str, Str] }) -> jv.Json {
  let base := [("tokenUrl", JStr(p.token_url)), ("scopes", scope_object(p.scopes))]
  with_refresh(base, p.refresh_url)
}

fn flow_auth_code(ac :: { authorization_url :: Str, token_url :: Str, refresh_url :: Str, scopes :: Map[Str, Str] }) -> jv.Json {
  let base := [("authorizationUrl", JStr(ac.authorization_url)), ("tokenUrl", JStr(ac.token_url)), ("scopes", scope_object(ac.scopes))]
  with_refresh(base, ac.refresh_url)
}

fn flow_client_creds(cc :: { token_url :: Str, refresh_url :: Str, scopes :: Map[Str, Str] }) -> jv.Json {
  let base := [("tokenUrl", JStr(cc.token_url)), ("scopes", scope_object(cc.scopes))]
  with_refresh(base, cc.refresh_url)
}

fn with_refresh(base :: List[(Str, jv.Json)], refresh_url :: Str) -> jv.Json {
  if str.is_empty(refresh_url) {
    JObj(base)
  } else {
    JObj(list.concat(base, [("refreshUrl", JStr(refresh_url))]))
  }
}

# Build the OpenAPI scope object: `{ "scope.name": "description" }`.
fn scope_object(scopes :: Map[Str, Str]) -> jv.Json {
  JObj(list.map(map.entries(scopes), fn (entry :: (Str, Str)) -> (Str, jv.Json) {
    match entry {
      (k, v) => (k, JStr(v)),
    }
  }))
}

