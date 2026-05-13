# lex-web — typed parameter extraction
#
# FastAPI lets you declare typed query, path, and header parameters
# with constraints; missing or malformed inputs become a 422 response
# automatically. lex-web ports the same idea on top of lex-schema:
#
#   match params.query_int(c, "page", Some(1), [IntPositive]) {
#     Err(r)    => r,                       # 422 problem+json
#     Ok(page)  => list_users(page),
#   }
#
# Each function returns Result[T, resp.Response]: handlers can chain
# them together with `match` cascades or via depends.chain*.
#
# Effects: none.

import "std.str"  as str
import "std.list" as list
import "std.map"  as map

import "./ctx"      as ctx
import "./response" as resp

import "lex-schema/error"       as e
import "lex-schema/coerce"      as coerce
import "lex-schema/constraints" as c
import "lex-schema/field"       as f

# ---- Path parameters ---------------------------------------------

# Path params are always required (the route wouldn't match otherwise).

fn path_str(
  c :: ctx.Ctx,
  name   :: Str,
  checks :: List[StrCheck]
) -> Result[Str, resp.Response] {
  match ctx.path_param(c, name) {
    None    => Err(resp.problem(422, c.path,
      e.single(name, "missing", str.concat("missing path param: ", name)))),
    Some(v) =>
      match f.check_str(name, v, checks) {
        Ok(s)   => Ok(s),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
  }
}

fn path_int(
  c :: ctx.Ctx,
  name   :: Str,
  checks :: List[IntCheck]
) -> Result[Int, resp.Response] {
  match ctx.path_param(c, name) {
    None    => Err(resp.problem(422, c.path,
      e.single(name, "missing", str.concat("missing path param: ", name)))),
    Some(v) =>
      match coerce.check_str_as_int(name, v, checks) {
        Ok(n)   => Ok(n),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
  }
}

fn path_float(
  c :: ctx.Ctx,
  name   :: Str,
  checks :: List[FloatCheck]
) -> Result[Float, resp.Response] {
  match ctx.path_param(c, name) {
    None    => Err(resp.problem(422, c.path,
      e.single(name, "missing", str.concat("missing path param: ", name)))),
    Some(v) =>
      match coerce.check_str_as_float(name, v, checks) {
        Ok(x)   => Ok(x),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
  }
}

# ---- Query parameters --------------------------------------------

# `default :: Option[T]` makes a param optional. When None and the
# query string omits the key, the result is a 422 problem+json.

fn query_str(
  c :: ctx.Ctx,
  name    :: Str,
  default :: Option[Str],
  checks  :: List[StrCheck]
) -> Result[Str, resp.Response] {
  let qs := ctx.query_map(c)
  let raw := match map.get(qs, name) {
    Some(v) => Some(v),
    None    => default,
  }
  match raw {
    None    => Err(missing_resp(c.path, name)),
    Some(v) =>
      match f.check_str(name, v, checks) {
        Ok(s)   => Ok(s),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
  }
}

fn query_int(
  c :: ctx.Ctx,
  name    :: Str,
  default :: Option[Int],
  checks  :: List[IntCheck]
) -> Result[Int, resp.Response] {
  let qs := ctx.query_map(c)
  match map.get(qs, name) {
    Some(v) =>
      match coerce.check_str_as_int(name, v, checks) {
        Ok(n)   => Ok(n),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
    None =>
      match default {
        Some(d) => Ok(d),
        None    => Err(missing_resp(c.path, name)),
      },
  }
}

fn query_float(
  c :: ctx.Ctx,
  name    :: Str,
  default :: Option[Float],
  checks  :: List[FloatCheck]
) -> Result[Float, resp.Response] {
  let qs := ctx.query_map(c)
  match map.get(qs, name) {
    Some(v) =>
      match coerce.check_str_as_float(name, v, checks) {
        Ok(x)   => Ok(x),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
    None =>
      match default {
        Some(d) => Ok(d),
        None    => Err(missing_resp(c.path, name)),
      },
  }
}

fn query_bool(
  c :: ctx.Ctx,
  name    :: Str,
  default :: Option[Bool]
) -> Result[Bool, resp.Response] {
  let qs := ctx.query_map(c)
  match map.get(qs, name) {
    Some(v) =>
      match coerce.coerce_str_to_bool(name, v) {
        Ok(b)   => Ok(b),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
    None =>
      match default {
        Some(d) => Ok(d),
        None    => Err(missing_resp(c.path, name)),
      },
  }
}

# Optional query → Option[T]. Never errs on absent; only on bad value.
fn query_optional_str(
  c :: ctx.Ctx,
  name   :: Str,
  checks :: List[StrCheck]
) -> Result[Option[Str], resp.Response] {
  let qs := ctx.query_map(c)
  match map.get(qs, name) {
    None    => Ok(None),
    Some(v) =>
      match f.check_str(name, v, checks) {
        Ok(s)   => Ok(Some(s)),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
  }
}

fn query_optional_int(
  c :: ctx.Ctx,
  name   :: Str,
  checks :: List[IntCheck]
) -> Result[Option[Int], resp.Response] {
  let qs := ctx.query_map(c)
  match map.get(qs, name) {
    None    => Ok(None),
    Some(v) =>
      match coerce.check_str_as_int(name, v, checks) {
        Ok(n)   => Ok(Some(n)),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
  }
}

# ---- Header parameters -------------------------------------------

fn header_str(
  c :: ctx.Ctx,
  name    :: Str,
  default :: Option[Str],
  checks  :: List[StrCheck]
) -> Result[Str, resp.Response] {
  let raw := match ctx.header(c, name) {
    Some(v) => Some(v),
    None    => default,
  }
  match raw {
    None    => Err(missing_resp(c.path, str.concat("header:", name))),
    Some(v) =>
      match f.check_str(name, v, checks) {
        Ok(s)   => Ok(s),
        Err(es) => Err(resp.problem(422, c.path, es)),
      },
  }
}

# Bearer token from `Authorization: Bearer <token>`. Missing or
# malformed → 401 (matches FastAPI's HTTPBearer behaviour).
fn bearer(c :: ctx.Ctx) -> Result[Str, resp.Response] {
  match ctx.bearer_token(c) {
    Some(t) =>
      if str.is_empty(t) { Err(resp.unauthorized("empty bearer token")) }
      else { Ok(t) },
    None => Err(resp.unauthorized("missing bearer token")),
  }
}

# ---- Internal helpers --------------------------------------------

fn missing_resp(path :: Str, name :: Str) -> resp.Response {
  resp.problem(422, path,
    e.single(name, "missing", str.concat("missing required parameter: ", name)))
}
