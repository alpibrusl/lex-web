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
#      using `fs.read_to_string`. `[fs_read]`-flavoured (registered via
#      `route_effectful`), so the row names the filesystem — and
#      `--allow-fs-read <dir>` bounds which files a mounted directory can
#      actually serve. This used to be `io.read` under `[io]`, an effect
#      documented as "console / stdio" (lex-lang#882); a static file
#      server is the worst possible place for a row that does not say it
#      reads files.
#
# Both reject path-traversal attempts (`..`, leading `/`).
#
# Effects:
#   mount_map / serve_from_map — none
#   mount_dir / serve_from_dir — [fs_read]

import "std.str" as str

import "std.map" as map

import "std.fs" as fs

import "./ctx" as ctx

import "./response" as resp

import "./router" as router

# ---- In-memory bundle --------------------------------------------
type Bundle = Map[Str, Str]

fn mount_map(r :: router.Router, prefix :: Str, bundle :: Bundle) -> router.Router {
  let pattern := str.concat(strip_trailing_slash(prefix), "/*path")
  router.route(r, "GET", pattern, fn (c :: ctx.Ctx) -> resp.Response {
    serve_from_map(c, bundle)
  })
}

fn serve_from_map(c :: ctx.Ctx, bundle :: Bundle) -> resp.Response {
  match ctx.path_param(c, "path") {
    None => resp.not_found(),
    Some(path) => if is_unsafe_path(path) {
      resp.bad_request("invalid path")
    } else {
      match map.get(bundle, path) {
        None => resp.not_found(),
        Some(body) => with_inferred_ct(body, path),
      }
    },
  }
}

# ---- Filesystem-backed -------------------------------------------
fn mount_dir(r :: router.Router, prefix :: Str, dir :: Str) -> router.Router {
  let pattern := str.concat(strip_trailing_slash(prefix), "/*path")
  router.route_effectful(r, "GET", pattern, fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    serve_from_dir(c, dir)
  })
}

# `GenericRouter[e]` counterpart to `mount_dir`: registers on the
# caller's own chosen row `e` instead of `Router`'s fixed one.
# `serve_from_dir` is already narrow (`[fs_read]` only); `[fs_read | e]`
# is a mixed row — `fs_read` is this route's own fixed lower bound,
# `e` is whatever else the rest of the caller's router needs — so one
# `GenericRouter[e]` can mount static files alongside routes that need
# `env`/`fs_walk`/anything else, all under the one row `e` names.
#
# `-> [| e]` on THIS function's own return type is required even though
# building a router performs no effect at all: the lambda below is a
# literal expression checked in its own body-checking pass, and that
# pass resolves a lambda's row-var name against the *enclosing
# function's own declared open row* (recorded once, when the enclosing
# function itself is checked) — not generally against any of its type
# parameters. `e` appears in `GenericRouter[e]`'s type here regardless,
# but that alone doesn't seed the lookup the lambda needs; dropping
# `[| e]` from this signature reproduces "unbound effect-row variable
# `e`" at the lambda below, even though `e` is a perfectly valid,
# declared parameter.
fn mount_dir_generic[e](r :: router.GenericRouter[e], prefix :: Str, dir :: Str) -> [| e] router.GenericRouter[e] {
  let pattern := str.concat(strip_trailing_slash(prefix), "/*path")
  router.route_generic(r, "GET", pattern, fn (c :: ctx.Ctx) -> [fs_read | e] resp.Response {
    serve_from_dir(c, dir)
  })
}

fn serve_from_dir(c :: ctx.Ctx, dir :: Str) -> [fs_read] resp.Response {
  match ctx.path_param(c, "path") {
    None => resp.not_found(),
    Some(path) => if is_unsafe_path(path) {
      resp.bad_request("invalid path")
    } else {
      let full := str.concat(strip_trailing_slash(dir), str.concat("/", path))
      match fs.read_to_string(full) {
        Err(_) => resp.not_found(),
        Ok(body) => with_inferred_ct(body, path),
      }
    },
  }
}

# ---- Content-type inference --------------------------------------
fn content_type_for(path :: Str) -> Str {
  let lower := str.to_lower(path)
  if str.ends_with(lower, ".html") {
    "text/html; charset=utf-8"
  } else {
    if str.ends_with(lower, ".htm") {
      "text/html; charset=utf-8"
    } else {
      if str.ends_with(lower, ".css") {
        "text/css; charset=utf-8"
      } else {
        if str.ends_with(lower, ".js") {
          "application/javascript; charset=utf-8"
        } else {
          if str.ends_with(lower, ".mjs") {
            "application/javascript; charset=utf-8"
          } else {
            if str.ends_with(lower, ".json") {
              "application/json"
            } else {
              if str.ends_with(lower, ".svg") {
                "image/svg+xml"
              } else {
                if str.ends_with(lower, ".png") {
                  "image/png"
                } else {
                  if str.ends_with(lower, ".jpg") {
                    "image/jpeg"
                  } else {
                    if str.ends_with(lower, ".jpeg") {
                      "image/jpeg"
                    } else {
                      if str.ends_with(lower, ".gif") {
                        "image/gif"
                      } else {
                        if str.ends_with(lower, ".ico") {
                          "image/x-icon"
                        } else {
                          if str.ends_with(lower, ".webp") {
                            "image/webp"
                          } else {
                            if str.ends_with(lower, ".woff2") {
                              "font/woff2"
                            } else {
                              if str.ends_with(lower, ".woff") {
                                "font/woff"
                              } else {
                                if str.ends_with(lower, ".txt") {
                                  "text/plain; charset=utf-8"
                                } else {
                                  if str.ends_with(lower, ".md") {
                                    "text/markdown; charset=utf-8"
                                  } else {
                                    if str.ends_with(lower, ".xml") {
                                      "application/xml"
                                    } else {
                                      if str.ends_with(lower, ".pdf") {
                                        "application/pdf"
                                      } else {
                                        "application/octet-stream"
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
                }
              }
            }
          }
        }
      }
    }
  }
}

fn with_inferred_ct(body :: Str, path :: Str) -> resp.Response {
  { body: body, status: 200, headers: map.from_list([("content-type", content_type_for(path))]) }
}

# ---- Path-traversal guard ----------------------------------------
fn is_unsafe_path(path :: Str) -> Bool {
  if str.is_empty(path) {
    true
  } else {
    if str.starts_with(path, "/") {
      true
    } else {
      str.contains(path, "..")
    }
  }
}

fn strip_trailing_slash(s :: Str) -> Str {
  let n := str.len(s)
  if n == 0 {
    s
  } else {
    if str.slice(s, n - 1, n) == "/" {
      str.slice(s, 0, n - 1)
    } else {
      s
    }
  }
}

