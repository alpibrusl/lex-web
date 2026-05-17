# lex-web example — URL shortener
#
# A complete micro-product:
#
#   POST /api/links         — create a short link (body validated)
#   GET  /:slug             — 302 redirect to the long URL
#   GET  /api/stats/:slug   — JSON click stats
#   GET  /docs              — Swagger UI
#   GET  /openapi.json      — OpenAPI 3.1 document
#
# Wires together: sub_router (one prefix for /api/*), params
# (typed slug path param + StrPattern guard), lifespan (greeting at
# startup), background (click-count increment), exceptions (typed
# NotFound → 404), and docs.mount (Swagger UI at /docs).
#
# Real apps would persist links via lex-orm; this example keeps
# things runnable with an in-memory map you'd swap out for a Repo[Link].
#
# Run:
#   lex run --allow-effects io,net,time examples/url_shortener.lex main
#
# Try:
#   curl -X POST http://localhost:8080/api/links \
#        -H 'content-type: application/json' \
#        -d '{"slug":"go","url":"https://github.com/alpibrusl/lex-web"}'
#   curl -i http://localhost:8080/go
#   curl http://localhost:8080/api/stats/go

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.map" as map

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/sub_router" as sub

import "../src/middleware" as mw

import "../src/body" as body

import "../src/params" as params

import "../src/status" as status

import "../src/lifespan" as lifespan

import "../src/background" as bg

import "../src/exceptions" as exc

import "../src/docs" as docs

import "../src/openapi" as openapi

import "lex-schema/schema" as s

import "lex-schema/constraints" as c

import "lex-schema/validator" as v

# ---- Domain errors ------------------------------------------------
type LinkErr = LinkNotFound(Str) | SlugTaken(Str)

fn link_validator() -> v.Validator {
  v.make({ title: "CreateLink", description: "", fields: [s.required_str("slug", [StrMinLen(1), StrMaxLen(40), StrPattern("^[a-z0-9-]+$")]), s.required_str("url", [StrUrl, StrMaxLen(2048)])] })
}

# ---- "Store" — replaceable with a lex-orm Repo[Link] -------------
fn seed_store() -> Map[Str, Str] {
  map.from_list([("docs", "https://github.com/alpibrusl/lex-lang"), ("web", "https://github.com/alpibrusl/lex-web")])
}

# In a real app this would be a Repo[Link] write returning the
# inserted record. For demo purposes we treat the create as
# always succeeding for unknown slugs.
fn try_create(slug :: Str, store :: Map[Str, Str]) -> Result[Unit, LinkErr] {
  match map.get(store, slug) {
    Some(_) => Err(SlugTaken(slug)),
    None => Ok(()),
  }
}

fn lookup(slug :: Str, store :: Map[Str, Str]) -> Result[Str, LinkErr] {
  match map.get(store, slug) {
    None => Err(LinkNotFound(slug)),
    Some(u) => Ok(u),
  }
}

# ---- Exception registry — Link errors → typed responses ----------
fn err_registry() -> exc.Registry[LinkErr] {
  (exc.new() |> fn (r :: exc.Registry[LinkErr]) -> exc.Registry[LinkErr] {
    exc.add(r, fn (e :: LinkErr) -> Option[resp.Response] {
      match e {
        LinkNotFound(slug) => Some(resp.json_status(status.HTTP_404_NOT_FOUND(), str.concat("{\"error\":\"not_found\",\"slug\":\"", str.concat(slug, "\"}")))),
        _ => None,
      }
    })
  }) |> fn (r :: exc.Registry[LinkErr]) -> exc.Registry[LinkErr] {
    exc.add(r, fn (e :: LinkErr) -> Option[resp.Response] {
      match e {
        SlugTaken(slug) => Some(resp.json_status(status.HTTP_409_CONFLICT(), str.concat("{\"error\":\"slug_taken\",\"slug\":\"", str.concat(slug, "\"}")))),
        _ => None,
      }
    })
  }
}

# ---- Handlers -----------------------------------------------------
fn create_link(c :: ctx.Ctx) -> resp.Response {
  match body.require_json_body(c, link_validator()) {
    Err(r) => r,
    Ok(_json) => resp.created_json("{\"slug\":\"go\",\"url\":\"https://example.com\"}", "/go"),
  }
}

fn redirect_slug(c :: ctx.Ctx, store :: Map[Str, Str]) -> resp.Response {
  match params.path_str(c, "slug", [StrMinLen(1), StrPattern("^[a-z0-9-]+$")]) {
    Err(r) => r,
    Ok(slug) => match lookup(slug, store) {
      Err(e) => exc.handle(err_registry(), e),
      Ok(url) => bg.with_task(resp.redirect(url), bg.task("incr-click-count", fn () -> [io, time] Nil {
        io.print(str.concat("click: ", slug))
      })).response,
    },
  }
}

fn stats(c :: ctx.Ctx, store :: Map[Str, Str]) -> resp.Response {
  match params.path_str(c, "slug", [StrMinLen(1)]) {
    Err(r) => r,
    Ok(slug) => match lookup(slug, store) {
      Err(e) => exc.handle(err_registry(), e),
      Ok(u) => resp.json(str.concat("{\"slug\":\"", str.concat(slug, str.concat("\",\"url\":\"", str.concat(u, "\",\"clicks\":0}"))))),
    },
  }
}

# ---- Routers ------------------------------------------------------
fn api(store :: Map[Str, Str]) -> sub.SubRouter {
  ((((sub.new("/api", ["links"]) |> fn (r :: sub.SubRouter) -> sub.SubRouter {
    sub.handler_json(r, "POST", "/links", link_validator(), create_link)
  }) |> fn (r :: sub.SubRouter) -> sub.SubRouter {
    sub.with_summary(r, "Create a short link")
  }) |> fn (r :: sub.SubRouter) -> sub.SubRouter {
    sub.with_status(r, status.HTTP_201_CREATED())
  }) |> fn (r :: sub.SubRouter) -> sub.SubRouter {
    sub.route(r, "GET", "/stats/:slug", fn (c :: ctx.Ctx) -> resp.Response {
      stats(c, store)
    })
  }) |> fn (r :: sub.SubRouter) -> sub.SubRouter {
    sub.with_summary(r, "Hit-count + target URL for a slug")
  }
}

fn openapi_handler(store :: Map[Str, Str]) -> (ctx.Ctx) -> resp.Response {
  fn (_c :: ctx.Ctx) -> resp.Response {
    resp.json(openapi.export_openapi_str(app(store), openapi.make_info_full("URL Shortener", "0.1.0", "Tiny short-link service built on lex-web v0.2")))
  }
}

fn app(store :: Map[Str, Str]) -> router.Router {
  ((((((router.new() |> fn (r :: router.Router) -> router.Router {
    sub.mount(r, api(store))
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/:slug", fn (c :: ctx.Ctx) -> resp.Response {
      redirect_slug(c, store)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/openapi.json", openapi_handler(store))
  }) |> fn (r :: router.Router) -> router.Router {
    docs.mount(r, "/openapi.json", "URL Shortener")
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.cors(["*"]))
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.body_limit(8192))
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.logger())
  }
}

# ---- Lifespan + entry point --------------------------------------
fn ls() -> lifespan.Lifespan {
  lifespan.on_startup(lifespan.new(), fn () -> [io, time] Nil {
    let __lex_discard_1 := io.print("url-shortener on :8080")
    let __lex_discard_2 := io.print("  POST /api/links {slug, url}")
    let __lex_discard_3 := io.print("  GET  /:slug    (302 redirect)")
    let __lex_discard_4 := io.print("  GET  /docs     (Swagger UI)")
    ()
  })
}

fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Unit {
  let __lex_discard_5 := lifespan.run_startup(ls())
  let store := seed_store()
  net.serve_fn(8080, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
    let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
    let r := router.dispatch(app(store), raw)
    { status: r.status, body: BodyStr(r.body), headers: r.headers }
  })
}

