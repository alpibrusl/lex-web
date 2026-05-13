# lex-web example — FastAPI-style API
#
# Showcases every FastAPI parity feature added in lex-web v0.2:
#
#   - sub_router  — APIRouter equivalent with prefix and tags
#   - params      — typed query/path coercion + validation → 422
#   - depends     — dependency injection (bearer auth, pagination)
#   - status      — named HTTP status constants
#   - lifespan    — startup hooks
#   - background  — post-response work
#   - docs        — Swagger UI at /docs, ReDoc at /redoc
#   - openapi     — auto-generated, with tags / summaries / per-route status
#   - exceptions  — typed error → response mapping
#
# Run:
#   lex run --allow-effects io,net,time examples/fastapi_style.lex main
#
# Try:
#   curl http://localhost:8080/docs                    # Swagger UI
#   curl http://localhost:8080/openapi.json
#   curl 'http://localhost:8080/items?page=2&size=20' \
#        -H 'authorization: Bearer demo'
#   curl -X POST http://localhost:8080/items \
#        -H 'content-type: application/json' \
#        -H 'authorization: Bearer demo' \
#        -d '{"name":"widget","qty":3}'

import "std.net"  as net
import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list
import "std.map"  as map

import "../src/ctx"           as ctx
import "../src/response"      as resp
import "../src/router"        as router
import "../src/sub_router"    as sub
import "../src/middleware"    as mw
import "../src/body"          as body
import "../src/params"        as params
import "../src/depends"       as depends
import "../src/status"        as status
import "../src/lifespan"      as lifespan
import "../src/background"    as background
import "../src/docs"          as docs
import "../src/exceptions"    as exceptions
import "../src/openapi"       as openapi
import "../src/test_fixtures" as tf

# ---- Domain errors ------------------------------------------------

type AppError =
    AppNotFound(Str)
  | AppConflict(Str)

# ---- Auth dep -----------------------------------------------------

# Reads the bearer token; rejects anything other than the demo token.
# Real apps would look the token up in a session store.
fn current_user(c :: ctx.Ctx) -> Result[Str, resp.Response] {
  match params.bearer(c) {
    Err(r)  => Err(r),
    Ok(tok) =>
      if tok == "demo" { Ok("demo-user") }
      else { Err(resp.unauthorized("invalid bearer token")) },
  }
}

# Pagination dep — returns (page, size).
fn pagination(c :: ctx.Ctx) -> Result[(Int, Int), resp.Response] {
  match params.query_int(c, "page", Some(1), [IntPositive]) {
    Err(r)   => Err(r),
    Ok(page) =>
      match params.query_int(c, "size", Some(20), [IntInRange(1, 100)]) {
        Err(r)   => Err(r),
        Ok(size) => Ok((page, size)),
      },
  }
}

# ---- Exception registry -------------------------------------------

fn err_registry() -> exceptions.Registry[AppError] {
  exceptions.new()
    |> fn (r :: exceptions.Registry[AppError]) -> exceptions.Registry[AppError] {
         exceptions.add(r,
           fn (e :: AppError) -> Option[resp.Response] {
             match e {
               AppNotFound(what) => Some(resp.json_status(404,
                 str.concat("{\"error\":\"not_found\",\"what\":\"",
                            str.concat(what, "\"}")))),
               _ => None,
             }
           })
       }
    |> fn (r :: exceptions.Registry[AppError]) -> exceptions.Registry[AppError] {
         exceptions.add(r,
           fn (e :: AppError) -> Option[resp.Response] {
             match e {
               AppConflict(what) => Some(resp.json_status(409,
                 str.concat("{\"error\":\"conflict\",\"what\":\"",
                            str.concat(what, "\"}")))),
               _ => None,
             }
           })
       }
}

# ---- Handlers -----------------------------------------------------

fn list_items_h(_c :: ctx.Ctx, _user :: Str, page_size :: (Int, Int)) -> resp.Response {
  let page := match page_size { (p, _) => p }
  let size := match page_size { (_, s) => s }
  resp.json(str.concat("{\"page\":",
    str.concat(int.to_str(page),
      str.concat(",\"size\":",
        str.concat(int.to_str(size), ",\"items\":[]}")))))
}

fn list_items(c :: ctx.Ctx) -> resp.Response {
  depends.inject2(c, current_user, pagination, list_items_h)
}

fn create_item_h(_c :: ctx.Ctx, _user :: Str) -> background.Reply {
  let r := resp.created_json(
    "{\"id\":\"itm_001\",\"name\":\"widget\",\"qty\":3}",
    "/items/itm_001")
  background.with_task(r,
    background.task("audit-log",
      fn () -> [io, time] Nil { io.print("audit: created itm_001") }))
}

fn create_item(c :: ctx.Ctx) -> resp.Response {
  match current_user(c) {
    Err(r)    => r,
    Ok(user)  =>
      match body.require_json_body(c, tf.item_validator()) {
        Err(rsp)  => rsp,
        Ok(_item) =>
          # Background task is queued in Reply; the dispatcher runs
          # them after handing back the Response.
          create_item_h(c, user).response,
      },
  }
}

fn get_item(c :: ctx.Ctx) -> resp.Response {
  match params.path_str(c, "id", [StrNonEmpty]) {
    Err(r)  => r,
    Ok(id)  =>
      if id == "itm_001" {
        resp.json("{\"id\":\"itm_001\",\"name\":\"widget\",\"qty\":3}")
      } else {
        exceptions.handle(err_registry(), AppNotFound(id))
      },
  }
}

# ---- Routers ------------------------------------------------------

fn items_router() -> sub.SubRouter {
  sub.new("/items", ["items"])
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.route(r, "GET", "/", list_items)
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "List items, paginated")
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.handler_json(r, "POST", "/", tf.item_validator(), create_item)
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "Create an item")
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_status(r, status.HTTP_201_CREATED())
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.route(r, "GET", "/:id", get_item)
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "Get one item by id")
       }
}

fn openapi_handler(_c :: ctx.Ctx) -> resp.Response {
  resp.json(openapi.export_openapi_str(app(),
    openapi.make_info_full("Items API", "0.2.0",
      "FastAPI-style demo built on lex-web v0.2.")))
}

fn app() -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router { sub.mount(r, items_router()) }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/openapi.json", openapi_handler)
       }
    |> fn (r :: router.Router) -> router.Router {
         docs.mount(r, "/openapi.json", "Items API")
       }
    |> fn (r :: router.Router) -> router.Router {
         router.use_mw(r, mw.cors(["*"]))
       }
    |> fn (r :: router.Router) -> router.Router {
         router.use_mw(r, mw.body_limit(1_000_000))
       }
    |> fn (r :: router.Router) -> router.Router {
         router.use_mw(r, mw.request_id())
       }
    |> fn (r :: router.Router) -> router.Router {
         router.use_mw(r, mw.gzip(1_024))
       }
    |> fn (r :: router.Router) -> router.Router {
         router.use_mw(r, mw.logger())
       }
}

# ---- Lifespan -----------------------------------------------------

fn ls() -> lifespan.Lifespan {
  lifespan.new()
    |> fn (l :: lifespan.Lifespan) -> lifespan.Lifespan {
         lifespan.on_startup(l,
           fn () -> [io, time] Nil { io.print("starting items API on :8080") })
       }
    |> fn (l :: lifespan.Lifespan) -> lifespan.Lifespan {
         lifespan.on_startup(l,
           fn () -> [io, time] Nil {
             io.print("Swagger UI: http://localhost:8080/docs")
           })
       }
}

# ---- Entry point --------------------------------------------------

fn handle(req :: ctx.RawRequest) -> [io, time] resp.Response {
  router.dispatch(app(), req)
}

fn main() -> [net, io, time] Nil {
  let _ := lifespan.run_startup(ls())
  net.serve_fn(8080, handle)
}
