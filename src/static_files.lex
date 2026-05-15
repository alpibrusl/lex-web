# lex-web — static files
#
# Two paths to serving static content, mirroring Starlette's
# `StaticFiles` and FastAPI's `app.mount("/static", StaticFiles(...))`:
#
#   1. In-memory bundle. Drop a `Map[Str, Str]` of `path -> content`
#      into a router via `mount_map`. Pure, fast, no IO. Best for
#      embedded HTML / JS / CSS shipped alongside the binary.
#
#   2. Filesystem-backed. `mount_dir(router, prefix, dir)` adds a
#      catch-all route that resolves `prefix/<rest>` against `dir/<rest>`
#      using `std.io.read_str`. `[io]`-flavoured.
#
# Both reject path-traversal attempts (`..`, leading `/`).
#
# Effects:
#   mount_map / serve_from_map — none
#   mount_dir / serve_from_dir — [io]

import "std.str" as str
import "std.map" as map
import "std.io"  as io

import "./ctx"      as ctx
import "./response" as resp
import "./router"   as router

# ---- In-memory bundle --------------------------------------------

type Bundle = Map[Str, Str]

fn mount_map(
  r       :: router.Router,
  prefix  :: Str,
  bundle  :: Bundle
) -> router.Router {
  let pattern := str.concat(strip_trailing_slash(prefix), "/*path")
  router.route(r, "GET", pattern,
    fn (c :: ctx.Ctx) -> resp.Response {
      serve_from_map(c, bundle)
    })
}

fn serve_from_map(c :: ctx.Ctx, bundle :: Bundle) -> resp.Response {
  match ctx.path_param(c, "path") {
    None       => resp.not_found(),
    Some(path) =>
      if is_unsafe_path(path) { resp.bad_request("invalid path") }
      else {
        match map.get(bundle, path) {
          None       => resp.not_found(),
          Some(body) => with_inferred_ct(body, path),
        }
      },
  }
}

# ---- Filesystem-backed -------------------------------------------

fn mount_dir(
  r      :: router.Router,
  prefix :: Str,
  dir    :: Str
) -> router.Router {
  let pattern := str.concat(strip_trailing_slash(prefix), "/*path")
  router.route(r, "GET", pattern,
    fn (c :: ctx.Ctx) -> [io] resp.Response {
      serve_from_dir(c, dir)
    })
}

fn serve_from_dir(c :: ctx.Ctx, dir :: Str) -> [io] resp.Response {
  match ctx.path_param(c, "path") {
    None       => resp.not_found(),
    Some(path) =>
      if is_unsafe_path(path) { resp.bad_request("invalid path") }
      else {
        let full := str.concat(strip_trailing_slash(dir),
                       str.concat("/", path))
        match io.read_str(full) {
          Err(_)   => resp.not_found(),
          Ok(body) => with_inferred_ct(body, path),
        }
      },
  }
}

# ---- Content-type inference --------------------------------------

fn content_type_for(path :: Str) -> Str {
  let lower := str.to_lower(path)
  if str.ends_with(lower, ".html") { "text/html; charset=utf-8" }
  else { if str.ends_with(lower, ".htm") { "text/html; charset=utf-8" }
  else { if str.ends_with(lower, ".css") { "text/css; charset=utf-8" }
  else { if str.ends_with(lower, ".js")  { "application/javascript; charset=utf-8" }
  else { if str.ends_with(lower, ".mjs") { "application/javascript; charset=utf-8" }
  else { if str.ends_with(lower, ".json"){ "application/json" }
  else { if str.ends_with(lower, ".svg") { "image/svg+xml" }
  else { if str.ends_with(lower, ".png") { "image/png" }
  else { if str.ends_with(lower, ".jpg") { "image/jpeg" }
  else { if str.ends_with(lower, ".jpeg"){ "image/jpeg" }
  else { if str.ends_with(lower, ".gif") { "image/gif" }
  else { if str.ends_with(lower, ".ico") { "image/x-icon" }
  else { if str.ends_with(lower, ".webp"){ "image/webp" }
  else { if str.ends_with(lower, ".woff2"){ "font/woff2" }
  else { if str.ends_with(lower, ".woff"){ "font/woff" }
  else { if str.ends_with(lower, ".txt") { "text/plain; charset=utf-8" }
  else { if str.ends_with(lower, ".md")  { "text/markdown; charset=utf-8" }
  else { if str.ends_with(lower, ".xml") { "application/xml" }
  else { if str.ends_with(lower, ".pdf") { "application/pdf" }
  else { "application/octet-stream" } } } } } } } } } } } } } } } } } } }
}

fn with_inferred_ct(body :: Str, path :: Str) -> resp.Response {
  {
    body:    body,
    status:  200,
    headers: map.from_list([("content-type", content_type_for(path))]),
  }
}

# ---- Path-traversal guard ----------------------------------------

fn is_unsafe_path(path :: Str) -> Bool {
  if str.is_empty(path) { true }
  else {
    if str.starts_with(path, "/") { true }
    else { str.contains(path, "..") }
  }
}

fn strip_trailing_slash(s :: Str) -> Str {
  let n := str.len(s)
  if n == 0 { s }
  else {
    if str.slice(s, n - 1, n) == "/" { str.slice(s, 0, n - 1) }
    else { s }
  }
}
