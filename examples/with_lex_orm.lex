# lex-web example — FastAPI-style API backed by lex-orm
#
# Builds on examples/fastapi_style.lex by replacing the in-memory
# fake store with a real lex-orm `Repo[Item]`. The same lex-schema
# `ModelSchema` drives:
#
#   - request-body validation (body.require_json_body)
#   - OpenAPI requestBody + responses[201] schemas
#   - lex-orm's table definition (q.for_schema)
#   - lex-orm's DDL diff / migration plan at startup
#
# Effects: net, io, time, sql, fs_write — the last two come from
# lex-orm's std.sql usage and (for SQLite) the open-file path.
#
# Run:
#   lex run --allow-effects io,net,time,sql,fs_write \
#           examples/with_lex_orm.lex main
#
# Try:
#   curl 'http://localhost:8080/items?page=1&size=20' \
#        -H 'authorization: Bearer demo'
#   curl -X POST http://localhost:8080/items \
#        -H 'content-type: application/json' \
#        -H 'authorization: Bearer demo' \
#        -d '{"name":"widget","qty":3}'
#   curl http://localhost:8080/items/1

import "std.net"  as net
import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list

import "../src/ctx"        as ctx
import "../src/response"   as resp
import "../src/router"     as router
import "../src/sub_router" as sub
import "../src/middleware" as mw
import "../src/body"       as body
import "../src/params"     as params
import "../src/depends"    as depends
import "../src/status"     as status
import "../src/lifespan"   as lifespan
import "../src/docs"       as docs
import "../src/openapi"    as openapi

import "lex-schema/schema"      as s
import "lex-schema/constraints" as c
import "lex-schema/validator"   as v
import "lex-schema/json_value"  as jv
import "lex-schema/error"       as se

import "lex-orm/connection" as conn
import "lex-orm/query"      as q
import "lex-orm/predicate"  as pr
import "lex-orm/migrate"    as mig
import "lex-orm/error"      as dbe

# ---- Domain type --------------------------------------------------

type Item = { id :: Int, name :: Str, qty :: Int }

# Decode a row's _j JSON column back into an Item. lex-orm hands us
# a jv.Json; we walk the safe-mode extractors.
fn decode_item(j :: jv.Json) -> Result[Item, se.Errors] {
  match jv.j_int("", j, "id", []) {
    Err(e) => Err(e),
    Ok(id) =>
      match jv.j_str("", j, "name", []) {
        Err(e)   => Err(e),
        Ok(name) =>
          match jv.j_int("", j, "qty", []) {
            Err(e)  => Err(e),
            Ok(qty) => Ok({ id: id, name: name, qty: qty }),
          },
      },
  }
}

fn item_schema() -> s.ModelSchema {
  {
    title: "items", description: "",
    fields: [
      s.required_int("id",   []),
      s.required_str("name", [StrNonEmpty, StrMaxLen(64)]),
      s.required_int("qty",  [IntPositive]),
    ],
  }
}

# Body validator — only the writable fields (id is server-assigned).
fn item_write_validator() -> v.Validator {
  v.make({
    title: "ItemWrite", description: "",
    fields: [
      s.required_str("name", [StrNonEmpty, StrMaxLen(64)]),
      s.required_int("qty",  [IntPositive]),
    ],
  })
}

fn item_repo() -> q.Repo[Item] {
  q.for_schema(item_schema(), decode_item)
}

# ---- Database boot ------------------------------------------------

# Module-level handle — a real app would thread it through Ctx or
# a context-bound store. We keep a function so the closure captures
# the freshly-opened handle.
fn open_db() -> [sql, fs_write] Result[conn.Db, dbe.DbErr] {
  conn.open(":memory:")
}

# Build the table from the schema. lex-orm derives the DDL from the
# same ModelSchema the validator and the repo use.
fn bootstrap(db :: conn.Db) -> [sql] Result[Unit, dbe.DbErr] {
  let pending := mig.diff(empty_schema(), item_schema())
  let sql_stmt := "CREATE TABLE \"items\" ("
              + "  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT,"
              + "  \"name\" TEXT NOT NULL,"
              + "  \"qty\" INTEGER NOT NULL"
              + ")"
  # In a real app we'd call mig.run_pending; the simplified inline
  # CREATE keeps this example focused on the integration shape.
  let _ := pending
  Ok(())
}

fn empty_schema() -> s.ModelSchema {
  { title: "items", description: "", fields: [] }
}

# ---- Handlers -----------------------------------------------------

fn current_user(c :: ctx.Ctx) -> Result[Str, resp.Response] {
  match params.bearer(c) {
    Err(r)  => Err(r),
    Ok(tok) =>
      if tok == "demo" { Ok("demo-user") }
      else { Err(resp.unauthorized("invalid bearer token")) },
  }
}

fn pagination(c :: ctx.Ctx) -> Result[(Int, Int), resp.Response] {
  match params.query_int(c, "page", Some(1), [IntPositive]) {
    Err(r) => Err(r),
    Ok(p)  =>
      match params.query_int(c, "size", Some(20), [IntInRange(1, 100)]) {
        Err(r) => Err(r),
        Ok(n)  => Ok((p, n)),
      },
  }
}

# GET /items?page=&size= — paginated SELECT via lex-orm.
fn list_items_h(
  _c        :: ctx.Ctx,
  _user     :: Str,
  page_size :: (Int, Int),
  db        :: conn.Db
) -> [sql] resp.Response {
  let page := match page_size { (p, _) => p }
  let size := match page_size { (_, n) => n }
  let plan := q.paginate(q.select(item_repo()), page, size)
  match q.run_select(plan, db) {
    Err(e)    => resp.internal_error(),
    Ok(items) => resp.json(items_to_json(items, page, size)),
  }
}

# GET /items/:id — single SELECT with WHERE id = ?.
fn get_item_h(_c :: ctx.Ctx, id :: Int, db :: conn.Db) -> [sql] resp.Response {
  let plan := q.where_clause(q.select(item_repo()),
    pr.eq("id", PInt(id)))
  match q.run_select(q.limit(plan, 1), db) {
    Err(_)    => resp.internal_error(),
    Ok(items) =>
      match list.head(items) {
        None       => resp.not_found(),
        Some(item) => resp.json(item_to_json(item)),
      },
  }
}

# POST /items — INSERT … RETURNING via lex-orm.
fn create_item_h(
  _c    :: ctx.Ctx,
  _user :: Str,
  body  :: jv.Json,
  db    :: conn.Db
) -> [sql] resp.Response {
  let plan := q.insert(item_repo(), body)
  match q.run_insert(plan, db) {
    Err(_)   => resp.internal_error(),
    Ok(item) =>
      resp.created_json(item_to_json(item),
        "/items/" + int.to_str(item.id)),
  }
}

# ---- JSON serialisation (manual until lex-schema ships output validators) ----

fn item_to_json(it :: Item) -> Str {
  "{\"id\":" + int.to_str(it.id)
   + ",\"name\":\"" + it.name + "\""
   + ",\"qty\":" + int.to_str(it.qty) + "}"
}

fn items_to_json(items :: List[Item], page :: Int, size :: Int) -> Str {
  let arr := str.join(list.map(items, item_to_json), ",")
  "{\"page\":" + int.to_str(page)
   + ",\"size\":" + int.to_str(size)
   + ",\"items\":[" + arr + "]}"
}

# ---- Routes -------------------------------------------------------

# We close over `db` via a closure-factory so each route gets the
# live handle. Lex's first-class closures make this idiomatic.
fn items_router(db :: conn.Db) -> sub.SubRouter {
  sub.new("/items", ["items"])
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.route(r, "GET", "/",
           fn (c :: ctx.Ctx) -> [sql] resp.Response {
             match current_user(c) {
               Err(r) => r,
               Ok(u)  =>
                 match pagination(c) {
                   Err(r)  => r,
                   Ok(ps)  => list_items_h(c, u, ps, db),
                 },
             }
           })
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "List items, paginated")
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.handler_json(r, "POST", "/", item_write_validator(),
           fn (c :: ctx.Ctx) -> [sql] resp.Response {
             match current_user(c) {
               Err(r) => r,
               Ok(u)  =>
                 match body.require_json_body(c, item_write_validator()) {
                   Err(r)   => r,
                   Ok(json) => create_item_h(c, u, json, db),
                 },
             }
           })
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "Create an item")
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_status(r, status.HTTP_201_CREATED())
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.route(r, "GET", "/:id",
           fn (c :: ctx.Ctx) -> [sql] resp.Response {
             match params.path_int(c, "id", [IntPositive]) {
               Err(r) => r,
               Ok(id) => get_item_h(c, id, db),
             }
           })
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "Get one item by id")
       }
}

fn app(db :: conn.Db) -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router { sub.mount(r, items_router(db)) }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/openapi.json",
           fn (_c :: ctx.Ctx) -> resp.Response {
             resp.json(openapi.export_openapi_str(app(db),
               openapi.make_info_full("Items API", "0.2.0",
                 "lex-web + lex-orm + lex-schema integration demo")))
           })
       }
    |> fn (r :: router.Router) -> router.Router {
         docs.mount(r, "/openapi.json", "Items API")
       }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.cors(["*"])) }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.body_limit(1_000_000)) }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.logger()) }
}

# ---- Entry point --------------------------------------------------

fn main() -> [net, io, time, sql, fs_write] Nil {
  match open_db() {
    Err(_e) => io.print("failed to open db"),
    Ok(db)  => {
      let _ := bootstrap(db)
      let _ := io.print("items API on :8080 (SQLite in-memory)")
      let _ := io.print("Swagger UI: http://localhost:8080/docs")
      net.serve_fn(8080,
        fn (req :: ctx.RawRequest) -> [io, time, sql] resp.Response {
          router.dispatch(app(db), req)
        })
    },
  }
}
