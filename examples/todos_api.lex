# lex-web example — Todos API (full e2e: web + schema + orm)
#
# A persisted task tracker that covers the realistic CRUD shape:
#
#   GET    /tasks?status=&q=&page=&size=   (filter + search + paginate)
#   POST   /tasks                          (validated body, 201 + Location)
#   GET    /tasks/:id                      (single)
#   PATCH  /tasks/:id/done                 (status transition)
#   DELETE /tasks/:id                      (soft-delete via status="archived")
#   GET    /healthz
#   GET    /docs                           (Swagger UI)
#   GET    /openapi.json
#
# Stack split:
#
#   lex-schema  — one ModelSchema drives the body validator, the OpenAPI
#                  requestBody schema, the lex-orm Repo, AND the CREATE
#                  TABLE statement (via sdk.to_sql_ddl).
#   lex-orm     — Repo[Task], paginate / where_clause / set_col / patterns
#                  for filter+search, plus run_count for the paging total.
#   lex-web     — sub_router with /tasks prefix + tags, params (typed
#                  query + path), exceptions for typed errors, lifespan
#                  to bootstrap the table at startup, docs.mount.
#
# Run:
#   lex run --allow-effects io,net,time,sql,fs_write \
#           examples/todos_api.lex main
#
# Try:
#   curl -X POST http://localhost:8080/tasks \
#        -H 'content-type: application/json' \
#        -H 'authorization: Bearer demo' \
#        -d '{"title":"buy milk","priority":2}'
#   curl 'http://localhost:8080/tasks?status=open&q=milk' \
#        -H 'authorization: Bearer demo'
#   curl -X PATCH http://localhost:8080/tasks/1/done \
#        -H 'authorization: Bearer demo'

import "std.net"  as net
import "std.io"   as io
import "std.str"  as str
import "std.int"  as int
import "std.list" as list
import "std.map"  as map
import "std.sql"  as sql

import "../src/ctx"        as ctx
import "../src/response"   as resp
import "../src/router"     as router
import "../src/sub_router" as sub
import "../src/middleware" as mw
import "../src/body"       as body
import "../src/params"     as params
import "../src/status"     as status
import "../src/lifespan"   as lifespan
import "../src/exceptions" as exc
import "../src/docs"       as docs
import "../src/openapi"    as openapi

import "lex-schema/schema"      as s
import "lex-schema/constraints" as c
import "lex-schema/validator"   as v
import "lex-schema/json_value"  as jv
import "lex-schema/error"       as se
import "lex-schema/sdk"         as sdk

import "lex-orm/connection" as conn
import "lex-orm/query"      as q
import "lex-orm/predicate"  as pr
import "lex-orm/error"      as dbe

# ---- Domain & schema ----------------------------------------------

type Task = {
  id       :: Int,
  title    :: Str,
  status   :: Str,         # "open" | "done" | "archived"
  priority :: Int,
}

type TaskErr =
    TaskNotFound(Int)
  | TaskAlreadyDone(Int)

# The full schema (id is server-assigned) — drives the Repo and the
# CREATE TABLE. Status defaults to "open" at the application layer.
fn task_schema() -> s.ModelSchema {
  {
    title: "tasks", description: "",
    fields: [
      s.required_int("id",       [IntPositive]),
      s.required_str("title",    [StrNonEmpty, StrMaxLen(200)]),
      s.required_str("status",   [StrOneOf(["open", "done", "archived"])]),
      s.required_int("priority", [IntInRange(1, 5)]),
    ],
  }
}

# The write surface: clients pick title + priority. id and status
# are server-assigned, so they're absent from the write validator.
fn task_write_schema() -> s.ModelSchema {
  {
    title: "TaskWrite", description: "",
    fields: [
      s.required_str("title",    [StrNonEmpty, StrMaxLen(200)]),
      s.required_int("priority", [IntInRange(1, 5)]),
    ],
  }
}

fn task_validator() -> v.Validator { v.make(task_write_schema()) }

fn decode_task(j :: jv.Json) -> Result[Task, se.Errors] {
  match jv.j_int("", j, "id", []) {
    Err(e) => Err(e),
    Ok(id) =>
      match jv.j_str("", j, "title", []) {
        Err(e)    => Err(e),
        Ok(title) =>
          match jv.j_str("", j, "status", []) {
            Err(e)     => Err(e),
            Ok(status) =>
              match jv.j_int("", j, "priority", []) {
                Err(e)    => Err(e),
                Ok(prio)  => Ok({
                  id: id, title: title, status: status, priority: prio
                }),
              },
          },
      },
  }
}

fn task_repo() -> q.Repo[Task] { q.for_schema(task_schema(), decode_task) }

# ---- Auth dep (same pattern as fastapi_style.lex) -----------------

fn current_user(c :: ctx.Ctx) -> Result[Str, resp.Response] {
  match params.bearer(c) {
    Err(r)  => Err(r),
    Ok(tok) =>
      if tok == "demo" { Ok("demo-user") }
      else { Err(resp.unauthorized("invalid bearer token")) },
  }
}

# ---- Pagination & filters -----------------------------------------

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

# Build the WHERE filters from optional status + q query params.
# Returns the list of predicates to attach to the select chain.
fn build_filters(c :: ctx.Ctx) -> Result[List[pr.Predicate], resp.Response] {
  let preds := []
  match params.query_optional_str(c, "status", [StrOneOf(["open", "done", "archived"])]) {
    Err(r)  => Err(r),
    Ok(opt) => {
      let stage1 := match opt {
        None    => preds,
        Some(s) => list.concat(preds, [pr.eq("status", PStr(s))]),
      }
      match params.query_optional_str(c, "q", [StrMaxLen(80)]) {
        Err(r)  => Err(r),
        Ok(opt) =>
          match opt {
            None    => Ok(stage1),
            # SQL LIKE pattern injection-safe through ?-binding.
            Some(q) => Ok(list.concat(stage1,
              [pr.like("title", PStr("%" + q + "%"))])),
          },
      }
    },
  }
}

# ---- Exception registry ------------------------------------------

fn err_registry() -> exc.Registry[TaskErr] {
  exc.new()
    |> fn (r :: exc.Registry[TaskErr]) -> exc.Registry[TaskErr] {
         exc.add(r, fn (e :: TaskErr) -> Option[resp.Response] {
           match e {
             TaskNotFound(id) =>
               Some(resp.json_status(status.HTTP_404_NOT_FOUND(),
                 "{\"error\":\"task_not_found\",\"id\":" + int.to_str(id) + "}")),
             _ => None,
           }
         })
       }
    |> fn (r :: exc.Registry[TaskErr]) -> exc.Registry[TaskErr] {
         exc.add(r, fn (e :: TaskErr) -> Option[resp.Response] {
           match e {
             TaskAlreadyDone(id) =>
               Some(resp.json_status(status.HTTP_409_CONFLICT(),
                 "{\"error\":\"already_done\",\"id\":" + int.to_str(id) + "}")),
             _ => None,
           }
         })
       }
}

# ---- Handlers -----------------------------------------------------

fn task_to_json(t :: Task) -> Str {
  "{\"id\":" + int.to_str(t.id)
   + ",\"title\":\"" + t.title + "\""
   + ",\"status\":\"" + t.status + "\""
   + ",\"priority\":" + int.to_str(t.priority) + "}"
}

fn list_tasks(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match current_user(c) {
    Err(r) => r,
    Ok(_)  =>
      match pagination(c) {
        Err(r)   => r,
        Ok(page_size) =>
          match build_filters(c) {
            Err(r)    => r,
            Ok(preds) => {
              let page := match page_size { (p, _) => p }
              let size := match page_size { (_, n) => n }
              let base := list.fold(preds, q.select(task_repo()),
                fn (acc :: q.SelectQuery[Task], p :: pr.Predicate) -> q.SelectQuery[Task] {
                  q.where_clause(acc, p)
                })
              let plan := q.paginate(q.order_by(base, "id", Desc), page, size)
              match q.run_select(plan, db) {
                Err(_)    => resp.internal_error(),
                Ok(items) =>
                  match q.run_count(base, db) {
                    Err(_)    => resp.internal_error(),
                    Ok(total) =>
                      resp.json("{\"page\":" + int.to_str(page)
                        + ",\"size\":" + int.to_str(size)
                        + ",\"total\":" + int.to_str(total)
                        + ",\"items\":[" + str.join(list.map(items, task_to_json), ",") + "]}"),
                  },
              }
            },
          },
      },
  }
}

fn get_task(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match current_user(c) {
    Err(r) => r,
    Ok(_)  =>
      match params.path_int(c, "id", [IntPositive]) {
        Err(r) => r,
        Ok(id) =>
          match q.run_select(
            q.limit(q.where_clause(q.select(task_repo()), pr.eq("id", PInt(id))), 1),
            db
          ) {
            Err(_)    => resp.internal_error(),
            Ok(items) =>
              match list.head(items) {
                None    => exc.handle(err_registry(), TaskNotFound(id)),
                Some(t) => resp.json(task_to_json(t)),
              },
          },
      },
  }
}

fn create_task(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match current_user(c) {
    Err(r) => r,
    Ok(_)  =>
      match body.require_json_body(c, task_validator()) {
        Err(r)   => r,
        Ok(body) => {
          # Inject server-assigned fields. id will be re-bound by the
          # database's autoincrement via the RETURNING clause.
          let payload := jv.set_field(body, "id", JInt(next_id_placeholder()))
          let payload2 := jv.set_field(payload, "status", JStr("open"))
          match q.run_insert(q.insert(task_repo(), payload2), db) {
            Err(_)   => resp.internal_error(),
            Ok(task) =>
              resp.created_json(task_to_json(task),
                "/tasks/" + int.to_str(task.id)),
          }
        },
      },
  }
}

fn mark_done(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match current_user(c) {
    Err(r) => r,
    Ok(_)  =>
      match params.path_int(c, "id", [IntPositive]) {
        Err(r) => r,
        Ok(id) => {
          let plan := q.set_col(
            q.where_update(q.update(task_repo()),
              pr.and_pred(pr.eq("id", PInt(id)),
                          pr.neq("status", PStr("done")))),
            "status", PStr("done"))
          match q.run_update(plan, db) {
            Err(_) => resp.internal_error(),
            Ok(0)  =>
              # Either the row doesn't exist or it's already done —
              # disambiguate with a single read.
              match q.run_count(q.where_clause(q.select(task_repo()),
                                              pr.eq("id", PInt(id))), db) {
                Err(_) => resp.internal_error(),
                Ok(0)  => exc.handle(err_registry(), TaskNotFound(id)),
                Ok(_)  => exc.handle(err_registry(), TaskAlreadyDone(id)),
              },
            Ok(_)  => resp.no_content(),
          }
        },
      },
  }
}

fn archive_task(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match current_user(c) {
    Err(r) => r,
    Ok(_)  =>
      match params.path_int(c, "id", [IntPositive]) {
        Err(r) => r,
        Ok(id) =>
          # Soft-delete = status transition. The row stays for audit;
          # list_tasks filters it out unless explicitly requested.
          match q.run_update(
            q.set_col(q.where_update(q.update(task_repo()),
              pr.eq("id", PInt(id))),
              "status", PStr("archived")),
            db
          ) {
            Err(_) => resp.internal_error(),
            Ok(0)  => exc.handle(err_registry(), TaskNotFound(id)),
            Ok(_)  => resp.no_content(),
          },
      },
  }
}

# ---- Database bootstrap ------------------------------------------

# Generate CREATE TABLE IF NOT EXISTS from the schema. Same schema
# value drives the Repo at runtime and the DDL at startup — one
# source of truth, no field drift.
fn ensure_schema(db :: conn.Db) -> [sql] Result[Unit, dbe.DbErr] {
  let ddl := sdk.to_sql_ddl(task_schema(), DialectSqlite)
  match sql.exec(db.handle, ddl, []) {
    Err(e) => Err(DbQueryFailed(e)),
    Ok(_)  => Ok(()),
  }
}

# Placeholder for id pre-RETURNING. SQLite's AUTOINCREMENT will
# overwrite this; the value is never written. lex-orm v0.2 (issue
# below) will let us declare server-side defaults so this hack
# disappears.
fn next_id_placeholder() -> Int { 0 }

# ---- Routing ------------------------------------------------------

fn tasks_router(db :: conn.Db) -> sub.SubRouter {
  sub.new("/tasks", ["tasks"])
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.route(r, "GET", "/",
           fn (c :: ctx.Ctx) -> [sql] resp.Response { list_tasks(c, db) })
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "List tasks (filter by status, search by title, paginated)")
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.handler_json(r, "POST", "/", task_validator(),
           fn (c :: ctx.Ctx) -> [sql] resp.Response { create_task(c, db) })
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "Create a task")
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_status(r, status.HTTP_201_CREATED())
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.route(r, "GET", "/:id",
           fn (c :: ctx.Ctx) -> [sql] resp.Response { get_task(c, db) })
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "Get a single task by id")
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.route(r, "PATCH", "/:id/done",
           fn (c :: ctx.Ctx) -> [sql] resp.Response { mark_done(c, db) })
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "Mark a task done")
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.route(r, "DELETE", "/:id",
           fn (c :: ctx.Ctx) -> [sql] resp.Response { archive_task(c, db) })
       }
    |> fn (r :: sub.SubRouter) -> sub.SubRouter {
         sub.with_summary(r, "Soft-delete (archive) a task")
       }
}

fn app(db :: conn.Db) -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router { sub.mount(r, tasks_router(db)) }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/healthz",
           fn (_c :: ctx.Ctx) -> resp.Response { resp.json("{\"ok\":true}") })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/openapi.json",
           fn (_c :: ctx.Ctx) -> resp.Response {
             resp.json(openapi.export_openapi_str(app(db),
               openapi.make_info_full("Todos API", "0.1.0",
                 "Tasks tracker built on lex-web + lex-schema + lex-orm")))
           })
       }
    |> fn (r :: router.Router) -> router.Router {
         docs.mount(r, "/openapi.json", "Todos API")
       }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.cors(["*"])) }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.body_limit(8_192)) }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.request_id()) }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.logger()) }
}

# ---- Entry point --------------------------------------------------

fn main() -> [net, io, time, sql, fs_write] Nil {
  match conn.connect_sqlite(":memory:") {
    Err(_) => io.print("failed to open sqlite"),
    Ok(db) => {
      match ensure_schema(db) {
        Err(_) => io.print("schema bootstrap failed"),
        Ok(_)  => {
          let _ := io.print("todos API on :8080 (sqlite in-memory)")
          let _ := io.print("  bearer: demo")
          let _ := io.print("  Swagger UI: http://localhost:8080/docs")
          net.serve_fn(8080,
            fn (req :: ctx.RawRequest) -> [io, time, sql] resp.Response {
              router.dispatch(app(db), req)
            })
        },
      }
    },
  }
}
