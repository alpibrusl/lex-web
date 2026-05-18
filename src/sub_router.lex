# lex-web — sub-routers (FastAPI's APIRouter equivalent)
#
# Build a group of routes under a shared prefix and a shared list of
# OpenAPI tags, then mount it into the main router. Every route the
# sub-router carries inherits the prefix on its pattern and the tags
# on its OpenAPI metadata.
#
# Pure / effectful split mirrors src/router.lex:
#   sub_router.route             — pure handler
#   sub_router.route_effectful   — effectful handler
#   sub_router.handler_json[…]   — same split, with a Validator attached
#
# Usage:
#
#   fn users() -> sub_router.SubRouter {
#     sub_router.new("/users", ["users"])
#       |> fn (r :: sub_router.SubRouter) -> sub_router.SubRouter {
#            sub_router.route(r, "GET", "/", list_users)
#          }
#       |> fn (r :: sub_router.SubRouter) -> sub_router.SubRouter {
#            sub_router.handler_json(r, "POST", "/", v_user, create_user)
#          }
#       |> fn (r :: sub_router.SubRouter) -> sub_router.SubRouter {
#            sub_router.route(r, "GET", "/:id", get_user)
#          }
#   }
#
#   fn app() -> router.Router {
#     sub_router.mount(router.new(), users())
#   }
#
# Effects: none.

import "std.str" as str

import "std.list" as list

import "./ctx" as ctx

import "./response" as resp

import "./router" as router

import "./route_trie" as rt

import "lex-schema/validator" as v

# ---- Sub-route record (matches router.RouteRecord, plus tags) ----
# `body` is the same tagged-union the main router uses; sub-routers
# now support both pure and effectful handlers.
type SubRoute = { method :: Str, pattern :: Str, body :: rt.HandlerBody, validator :: Option[v.Validator], tags :: List[Str], summary :: Str, description :: Str, status :: Int }

type SubRouter = { prefix :: Str, tags :: List[Str], routes :: List[SubRoute] }

# ---- Construction ------------------------------------------------
fn new(prefix :: Str, tags :: List[Str]) -> SubRouter {
  { prefix: prefix, tags: tags, routes: [] }
}

fn route(r :: SubRouter, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> resp.Response) -> SubRouter {
  add(r, mk_sub_route(method, pattern, HPure(handler, None), None, "", "", 0))
}

fn route_effectful(r :: SubRouter, method :: Str, pattern :: Str, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response) -> SubRouter {
  add(r, mk_sub_route(method, pattern, HEff(handler, None), None, "", "", 0))
}

fn handler_json(r :: SubRouter, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> resp.Response) -> SubRouter {
  add(r, mk_sub_route(method, pattern, HPure(handler, None), Some(validator), "", "", 0))
}

fn handler_json_effectful(r :: SubRouter, method :: Str, pattern :: Str, validator :: v.Validator, handler :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response) -> SubRouter {
  add(r, mk_sub_route(method, pattern, HEff(handler, None), Some(validator), "", "", 0))
}

# Annotate the most-recently-added route with summary / description
# / explicit success status. Returns the original router unchanged
# when no routes have been added yet.
fn with_summary(r :: SubRouter, summary :: Str) -> SubRouter {
  match list.fold(r.routes, (None, []), fn (acc :: (Option[SubRoute], List[SubRoute]), sr :: SubRoute) -> (Option[SubRoute], List[SubRoute]) {
    let last := match acc {
      (l, _) => l,
    }
    let kept := match acc {
      (_, k) => k,
    }
    match last {
      None => (Some(sr), kept),
      Some(p) => (Some(sr), list.concat(kept, [p])),
    }
  }) {
    (None, _) => r,
    (Some(last), prev) => {
      let updated := { method: last.method, pattern: last.pattern, body: last.body, validator: last.validator, tags: last.tags, summary: summary, description: last.description, status: last.status }
      { prefix: r.prefix, tags: r.tags, routes: list.concat(prev, [updated]) }
    },
  }
}

fn with_description(r :: SubRouter, description :: Str) -> SubRouter {
  match list.fold(r.routes, (None, []), fn (acc :: (Option[SubRoute], List[SubRoute]), sr :: SubRoute) -> (Option[SubRoute], List[SubRoute]) {
    let last := match acc {
      (l, _) => l,
    }
    let kept := match acc {
      (_, k) => k,
    }
    match last {
      None => (Some(sr), kept),
      Some(p) => (Some(sr), list.concat(kept, [p])),
    }
  }) {
    (None, _) => r,
    (Some(last), prev) => {
      let updated := { method: last.method, pattern: last.pattern, body: last.body, validator: last.validator, tags: last.tags, summary: last.summary, description: description, status: last.status }
      { prefix: r.prefix, tags: r.tags, routes: list.concat(prev, [updated]) }
    },
  }
}

fn with_status(r :: SubRouter, status :: Int) -> SubRouter {
  match list.fold(r.routes, (None, []), fn (acc :: (Option[SubRoute], List[SubRoute]), sr :: SubRoute) -> (Option[SubRoute], List[SubRoute]) {
    let last := match acc {
      (l, _) => l,
    }
    let kept := match acc {
      (_, k) => k,
    }
    match last {
      None => (Some(sr), kept),
      Some(p) => (Some(sr), list.concat(kept, [p])),
    }
  }) {
    (None, _) => r,
    (Some(last), prev) => {
      let updated := { method: last.method, pattern: last.pattern, body: last.body, validator: last.validator, tags: last.tags, summary: last.summary, description: last.description, status: status }
      { prefix: r.prefix, tags: r.tags, routes: list.concat(prev, [updated]) }
    },
  }
}

# ---- Mount onto the main Router ----------------------------------
#
# Concatenate every sub-route onto the main router, prepending the
# sub-router's prefix to each pattern. The tags / summary /
# description / status are stored on the main router via
# router.attach_meta, so the OpenAPI exporter can pick them up.
#
# We go through `router.add_record` directly so the HandlerBody
# variant is preserved end-to-end (the sugar wrappers route /
# handler_json discard variant info by re-wrapping).
fn mount(main :: router.Router, sub :: SubRouter) -> router.Router {
  list.fold(sub.routes, main, fn (acc :: router.Router, sr :: SubRoute) -> router.Router {
    let full := join_path(sub.prefix, sr.pattern)
    let merged_tags := dedup_concat(sub.tags, sr.tags)
    let stage1 := router.add_record(acc, sr.method, full, sr.body, sr.validator, router.empty_meta())
    router.attach_meta(stage1, sr.method, full, { tags: merged_tags, summary: sr.summary, description: sr.description, status: sr.status, response_model: None })
  })
}

# ---- Internal helpers --------------------------------------------
fn add(r :: SubRouter, sr :: SubRoute) -> SubRouter {
  { prefix: r.prefix, tags: r.tags, routes: list.concat(r.routes, [sr]) }
}

fn mk_sub_route(method :: Str, pattern :: Str, body :: rt.HandlerBody, validator :: Option[v.Validator], summary :: Str, description :: Str, status :: Int) -> SubRoute {
  { method: str.to_upper(method), pattern: pattern, body: body, validator: validator, tags: [], summary: summary, description: description, status: status }
}

# "/users" + "/" → "/users", "/users" + "/:id" → "/users/:id".
fn join_path(prefix :: Str, sub_pattern :: Str) -> Str {
  let p := strip_trailing_slash(prefix)
  if str.is_empty(sub_pattern) {
    p
  } else {
    if sub_pattern == "/" {
      p
    } else {
      if str.starts_with(sub_pattern, "/") {
        str.concat(p, sub_pattern)
      } else {
        str.concat(p, str.concat("/", sub_pattern))
      }
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

# Concatenate two tag lists with insertion-order de-duplication.
fn dedup_concat(a :: List[Str], b :: List[Str]) -> List[Str] {
  list.fold(b, a, fn (acc :: List[Str], t :: Str) -> List[Str] {
    let already := list.fold(acc, false, fn (found :: Bool, x :: Str) -> Bool {
      found or x == t
    })
    if already {
      acc
    } else {
      list.concat(acc, [t])
    }
  })
}

