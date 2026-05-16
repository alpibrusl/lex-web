# lex-web — OpenAPI 3.1 export
#
# Walk the Router's route list and emit an OpenAPI 3.1 document
# as a lex-schema Json value. Routes with an attached Validator
# automatically get a requestBody schema derived from
# validator.openapi (the pre-computed OpenAPI schema fragment
# that lex-schema bundles at Validator construction time).
#
# v0.2 honours the per-route metadata exposed by router.RouteMeta:
#   - tags         → operation.tags
#   - summary      → operation.summary
#   - description  → operation.description
#   - status (>0)  → declared as the operation's success response
#
# Usage:
#   let doc := openapi.export_openapi(router(), info)
#   let _   := io.write("openapi.json", jv.stringify_pretty(doc))
#
# Effects: none. JSON construction is pure.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.map" as map

import "./router" as router

import "lex-schema/json_value" as jv

import "lex-schema/validator" as v

# ---- API info record ---------------------------------------------
type Info = { title :: Str, version :: Str, description :: Str }

fn make_info(title :: Str, version :: Str) -> Info {
  { title: title, version: version, description: "" }
}

fn make_info_full(title :: Str, version :: Str, description :: Str) -> Info {
  { title: title, version: version, description: description }
}

# ---- Top-level export --------------------------------------------
fn export_openapi(r :: router.Router, info :: Info) -> jv.Json {
  let tag_objs := build_tags(r.routes)
  let base := [("openapi", JStr("3.1.0")), ("info", build_info(info)), ("paths", build_paths(r.routes))]
  let with_tags := match list.len(tag_objs) {
    0 => base,
    _ => list.concat(base, [("tags", JList(tag_objs))]),
  }
  JObj(with_tags)
}

# Convenience: emit a pretty-printed JSON string directly.
fn export_openapi_str(r :: router.Router, info :: Info) -> Str {
  jv.stringify_pretty(export_openapi(r, info))
}

# ---- Info object -------------------------------------------------
fn build_info(info :: Info) -> jv.Json {
  let base := [("title", JStr(info.title)), ("version", JStr(info.version))]
  let with_desc := if str.is_empty(info.description) {
    base
  } else {
    list.concat(base, [("description", JStr(info.description))])
  }
  JObj(with_desc)
}

# ---- Paths object ------------------------------------------------
# Group routes by path pattern, then build one path-item per
# unique pattern. Within each path-item, each (method, record)
# pair becomes one operation.
fn build_paths(routes :: List[router.RouteRecord]) -> jv.Json {
  let patterns := unique_patterns(routes)
  let items := list.map(patterns, fn (pattern :: Str) -> (Str, jv.Json) {
    let matching := list.filter(routes, fn (rec :: router.RouteRecord) -> Bool {
      rec.pattern == pattern
    })
    (openapi_path(pattern), build_path_item(matching))
  })
  JObj(items)
}

# Build one path-item object from all routes sharing the same
# pattern. Each route contributes one lowercase-method key.
fn build_path_item(routes :: List[router.RouteRecord]) -> jv.Json {
  let ops := list.map(routes, fn (rec :: router.RouteRecord) -> (Str, jv.Json) {
    (str.to_lower(rec.method), build_operation(rec))
  })
  JObj(ops)
}

# Build one OpenAPI operation object for a single route.
fn build_operation(rec :: router.RouteRecord) -> jv.Json {
  let params := path_params_from_pattern(rec.pattern)
  let responses := match rec.meta.status {
    0 => default_responses(),
    s => responses_with_success(s),
  }
  let base := [("operationId", JStr(operation_id(rec))), ("parameters", JList(params)), ("responses", responses)]
  let with_summary := if str.is_empty(rec.meta.summary) {
    base
  } else {
    list.concat(base, [("summary", JStr(rec.meta.summary))])
  }
  let with_desc := if str.is_empty(rec.meta.description) {
    with_summary
  } else {
    list.concat(with_summary, [("description", JStr(rec.meta.description))])
  }
  let with_tags := match list.len(rec.meta.tags) {
    0 => with_desc,
    _ => list.concat(with_desc, [("tags", JList(list.map(rec.meta.tags, fn (t :: Str) -> jv.Json {
      JStr(t)
    })))]),
  }
  let with_body := match rec.validator {
    None => with_tags,
    Some(validator) => list.concat(with_tags, [("requestBody", build_request_body(validator))]),
  }
  JObj(with_body)
}

# Stable operationId from method+pattern: `getUsersId` for
# GET /users/:id. FastAPI follows a similar convention.
fn operation_id(rec :: router.RouteRecord) -> Str {
  let parts := list.filter(str.split(rec.pattern, "/"), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
  let cleaned := list.map(parts, fn (s :: Str) -> Str {
    if str.starts_with(s, ":") {
      capitalize(str.slice(s, 1, str.len(s)))
    } else {
      if str.starts_with(s, "*") {
        capitalize(str.slice(s, 1, str.len(s)))
      } else {
        capitalize(s)
      }
    }
  })
  str.concat(str.to_lower(rec.method), str.join(cleaned, ""))
}

fn capitalize(s :: Str) -> Str {
  if str.is_empty(s) {
    s
  } else {
    str.concat(str.to_upper(str.slice(s, 0, 1)), str.slice(s, 1, str.len(s)))
  }
}

# ---- Tags (top-level summary) ------------------------------------
# Collect every tag mentioned by any route into the top-level
# "tags" array, with empty descriptions; Swagger UI uses this to
# preserve declaration order.
fn build_tags(routes :: List[router.RouteRecord]) -> List[jv.Json] {
  let names := list.fold(routes, [], fn (acc :: List[Str], rec :: router.RouteRecord) -> List[Str] {
    list.fold(rec.meta.tags, acc, fn (a :: List[Str], t :: Str) -> List[Str] {
      let already := list.fold(a, false, fn (found :: Bool, x :: Str) -> Bool {
        found or x == t
      })
      if already {
        a
      } else {
        list.concat(a, [t])
      }
    })
  })
  list.map(names, fn (n :: Str) -> jv.Json {
    JObj([("name", JStr(n))])
  })
}

# ---- Request body ------------------------------------------------
fn build_request_body(validator :: v.Validator) -> jv.Json {
  JObj([("required", JBool(true)), ("content", JObj([("application/json", JObj([("schema", validator.openapi)]))]))])
}

# ---- Parameter objects -------------------------------------------
# Extract `:name` segments from the pattern and emit OpenAPI
# path parameter objects.
fn path_params_from_pattern(pattern :: Str) -> List[jv.Json] {
  let segs := list.filter(str.split(pattern, "/"), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
  list.fold(segs, [], fn (acc :: List[jv.Json], seg :: Str) -> List[jv.Json] {
    if str.starts_with(seg, ":") {
      let name := str.slice(seg, 1, str.len(seg))
      list.concat(acc, [path_param_obj(name)])
    } else {
      acc
    }
  })
}

fn path_param_obj(name :: Str) -> jv.Json {
  JObj([("name", JStr(name)), ("in", JStr("path")), ("required", JBool(true)), ("schema", JObj([("type", JStr("string"))]))])
}

# ---- Default responses -------------------------------------------
# Every operation gets a minimal responses object. Routes can
# annotate richer response schemas via RouteMeta.status.
fn default_responses() -> jv.Json {
  JObj([("200", JObj([("description", JStr("OK"))])), ("400", JObj([("description", JStr("Bad Request"))])), ("422", JObj([("description", JStr("Validation Error"))])), ("500", JObj([("description", JStr("Internal Server Error"))]))])
}

fn responses_with_success(status :: Int) -> jv.Json {
  let success_key := int.to_str(status)
  let success_desc := description_for(status)
  JObj([(success_key, JObj([("description", JStr(success_desc))])), ("400", JObj([("description", JStr("Bad Request"))])), ("422", JObj([("description", JStr("Validation Error"))])), ("500", JObj([("description", JStr("Internal Server Error"))]))])
}

fn description_for(status :: Int) -> Str {
  if status == 200 {
    "OK"
  } else {
    if status == 201 {
      "Created"
    } else {
      if status == 202 {
        "Accepted"
      } else {
        if status == 204 {
          "No Content"
        } else {
          if status == 301 {
            "Moved Permanently"
          } else {
            if status == 302 {
              "Found"
            } else {
              if status == 400 {
                "Bad Request"
              } else {
                if status == 401 {
                  "Unauthorized"
                } else {
                  if status == 403 {
                    "Forbidden"
                  } else {
                    if status == 404 {
                      "Not Found"
                    } else {
                      "Response"
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# ---- Helpers -----------------------------------------------------
# Convert a lex-web path pattern to an OpenAPI path template.
# `/users/:id` → `/users/{id}`, `*rest` → `{rest}`.
fn openapi_path(pattern :: Str) -> Str {
  let segs := str.split(pattern, "/")
  let converted := list.map(segs, fn (seg :: Str) -> Str {
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
  list.fold(routes, [], fn (acc :: List[Str], rec :: router.RouteRecord) -> List[Str] {
    let already := list.fold(acc, false, fn (found :: Bool, p :: Str) -> Bool {
      found or p == rec.pattern
    })
    if already {
      acc
    } else {
      list.concat(acc, [rec.pattern])
    }
  })
}

