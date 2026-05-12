# lex-web — OpenAPI 3.1 export
#
# Walk the Router's route list and emit an OpenAPI 3.1 document
# as a lex-schema Json value. Routes with an attached Validator
# automatically get a requestBody schema derived from
# validator.openapi (the pre-computed OpenAPI schema fragment
# that lex-schema bundles at Validator construction time).
#
# Usage:
#   let doc := openapi.export_openapi(router(), info)
#   let _   := io.write("openapi.json", jv.stringify_pretty(doc))
#
# Effects: none. JSON construction is pure.

import "std.str"  as str
import "std.list" as list
import "std.map"  as map

import "./router" as router

import "lex-data/json_value" as jv
import "lex-data/validator"  as v

# ---- API info record ---------------------------------------------

type Info = {
  title       :: Str,
  version     :: Str,
  description :: Str,
}

fn make_info(title :: Str, version :: Str) -> Info {
  { title: title, version: version, description: "" }
}

fn make_info_full(
  title       :: Str,
  version     :: Str,
  description :: Str
) -> Info {
  { title: title, version: version, description: description }
}

# ---- Top-level export --------------------------------------------

fn export_openapi(r :: router.Router, info :: Info) -> jv.Json {
  JObj([
    ("openapi", JStr("3.1.0")),
    ("info",    build_info(info)),
    ("paths",   build_paths(r.routes)),
  ])
}

# Convenience: emit a pretty-printed JSON string directly.
fn export_openapi_str(r :: router.Router, info :: Info) -> Str {
  jv.stringify_pretty(export_openapi(r, info))
}

# ---- Info object -------------------------------------------------

fn build_info(info :: Info) -> jv.Json {
  let base := [
    ("title",   JStr(info.title)),
    ("version", JStr(info.version)),
  ]
  let with_desc :=
    if str.is_empty(info.description) { base }
    else { list.concat(base, [("description", JStr(info.description))]) }
  JObj(with_desc)
}

# ---- Paths object ------------------------------------------------

# Group routes by path pattern, then build one path-item per
# unique pattern. Within each path-item, each (method, record)
# pair becomes one operation.
fn build_paths(routes :: List[router.RouteRecord]) -> jv.Json {
  let patterns := unique_patterns(routes)
  let items := list.map(patterns,
    fn (pattern :: Str) -> (Str, jv.Json) {
      let matching := list.filter(routes,
        fn (rec :: router.RouteRecord) -> Bool {
          rec.pattern == pattern
        })
      (openapi_path(pattern), build_path_item(matching))
    })
  JObj(items)
}

# Build one path-item object from all routes sharing the same
# pattern. Each route contributes one lowercase-method key.
fn build_path_item(routes :: List[router.RouteRecord]) -> jv.Json {
  let ops := list.map(routes,
    fn (rec :: router.RouteRecord) -> (Str, jv.Json) {
      (str.to_lower(rec.method), build_operation(rec))
    })
  JObj(ops)
}

# Build one OpenAPI operation object for a single route.
fn build_operation(rec :: router.RouteRecord) -> jv.Json {
  let params := path_params_from_pattern(rec.pattern)
  let base := [
    ("parameters", JList(params)),
    ("responses",  default_responses()),
  ]
  let with_body := match rec.validator {
    None    => base,
    Some(validator) =>
      list.concat(base, [("requestBody", build_request_body(validator))]),
  }
  JObj(with_body)
}

# ---- Request body ------------------------------------------------

fn build_request_body(validator :: v.Validator) -> jv.Json {
  JObj([
    ("required", JBool(true)),
    ("content",  JObj([
      ("application/json", JObj([
        ("schema", validator.openapi),
      ])),
    ])),
  ])
}

# ---- Parameter objects -------------------------------------------

# Extract `:name` segments from the pattern and emit OpenAPI
# path parameter objects.
fn path_params_from_pattern(pattern :: Str) -> List[jv.Json] {
  let segs := list.filter(str.split(pattern, "/"),
    fn (s :: Str) -> Bool { not str.is_empty(s) })
  list.fold(segs, [],
    fn (acc :: List[jv.Json], seg :: Str) -> List[jv.Json] {
      if str.starts_with(seg, ":") {
        let name := str.slice(seg, 1, str.len(seg))
        list.concat(acc, [path_param_obj(name)])
      } else {
        acc
      }
    })
}

fn path_param_obj(name :: Str) -> jv.Json {
  JObj([
    ("name",     JStr(name)),
    ("in",       JStr("path")),
    ("required", JBool(true)),
    ("schema",   JObj([("type", JStr("string"))])),
  ])
}

# ---- Default responses -------------------------------------------

# Every operation gets a minimal responses object. Routes can
# annotate richer response schemas in a future version.
fn default_responses() -> jv.Json {
  JObj([
    ("200", JObj([("description", JStr("OK"))])),
    ("400", JObj([("description", JStr("Bad Request"))])),
    ("422", JObj([("description", JStr("Validation Error"))])),
    ("500", JObj([("description", JStr("Internal Server Error"))])),
  ])
}

# ---- Helpers -----------------------------------------------------

# Convert a lex-web path pattern to an OpenAPI path template.
# `/users/:id` → `/users/{id}`, `*rest` → `{rest}`.
fn openapi_path(pattern :: Str) -> Str {
  let segs := str.split(pattern, "/")
  let converted := list.map(segs,
    fn (seg :: Str) -> Str {
      if str.starts_with(seg, ":") {
        let name := str.slice(seg, 1, str.len(seg))
        str.concat("{", str.concat(name, "}"))
      } else {
        if str.starts_with(seg, "*") {
          let name := str.slice(seg, 1, str.len(seg))
          str.concat("{", str.concat(name, "}"))
        } else {
          seg
        }
      }
    })
  str.join(converted, "/")
}

# Return unique route patterns in insertion order.
fn unique_patterns(routes :: List[router.RouteRecord]) -> List[Str] {
  list.fold(routes, [],
    fn (acc :: List[Str], rec :: router.RouteRecord) -> List[Str] {
      let already := list.fold(acc, false,
        fn (found :: Bool, p :: Str) -> Bool {
          found or (p == rec.pattern)
        })
      if already { acc }
      else { list.concat(acc, [rec.pattern]) }
    })
}
