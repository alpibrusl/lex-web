# lex-web — body decoding and validation
#
# Thin wrappers over lex-schema primitives. Three entry points:
#
#   json_body(ctx, validator)
#     Parses the request body as JSON and runs the Validator.
#     Returns Ok(Json) or Err(Errors) for the caller to map to
#     resp.problem() / resp.bad_request().
#
#   form_body(ctx)
#     Decodes application/x-www-form-urlencoded into a
#     Map[Str, Str]. Use lex-schema/coerce to pull typed fields
#     out of the map.
#
#   require_json_body(ctx, validator)
#     Like json_body but maps validation failures directly to a
#     422 Response, saving a match at every call site.
#
# Effects: none.

import "std.str" as str
import "std.map" as map

import "./ctx"      as ctx
import "./response" as resp

import "lex-data/validator"  as v
import "lex-data/json_value" as jv
import "lex-data/error"      as e
import "lex-data/form"       as form

# ---- JSON body ---------------------------------------------------

# Parse + validate the request body against the Validator.
# Outer parse errors (malformed JSON) carry code = "parse";
# field-level errors carry the per-rule codes from lex-schema.
fn json_body(
  c         :: ctx.Ctx,
  validator :: v.Validator
) -> Result[jv.Json, e.Errors] {
  v.validate_str(validator, c.body)
}

# Convenience: turn validation failures into a 422 Response so
# callers can collapse the common case into one match arm.
#
#   match body.require_json_body(ctx, user_v) {
#     Err(r)    => r,
#     Ok(user)  => handle_create(user),
#   }
fn require_json_body(
  c         :: ctx.Ctx,
  validator :: v.Validator
) -> Result[jv.Json, resp.Response] {
  match v.validate_str(validator, c.body) {
    Ok(j)   => Ok(j),
    Err(es) => Err(resp.problem(422, c.path, es)),
  }
}

# ---- Form body ---------------------------------------------------

# Decode an application/x-www-form-urlencoded body.
# Returns an Err if the Content-Type is not urlencoded or if the
# body is multipart (multipart support is deferred, see
# lex-schema/form.lex).
fn form_body(
  c :: ctx.Ctx
) -> Result[Map[Str, Str], e.Errors] {
  form.decode_body(c.body, ctx.content_type(c))
}

# Decode without checking Content-Type. Use when the client
# sends urlencoded data with an absent or wrong Content-Type.
fn form_body_raw(c :: ctx.Ctx) -> Map[Str, Str] {
  form.decode_urlencoded(c.body)
}

# ---- Raw body ----------------------------------------------------

fn raw_body(c :: ctx.Ctx) -> Str { c.body }

# ---- Content-Type helpers ----------------------------------------

fn is_json(c :: ctx.Ctx) -> Bool {
  str.starts_with(ctx.content_type(c), "application/json")
}

fn is_form(c :: ctx.Ctx) -> Bool {
  str.starts_with(ctx.content_type(c),
    "application/x-www-form-urlencoded")
}
