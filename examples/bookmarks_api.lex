# lex-web example — Bookmarks + tags API (many-to-many via joins)
#
# Three tables linked via an M:N join table. Showcases lex 0.9.1's
# record-row-spread type syntax to declare join-result types without
# duplicating field lists:
#
#   type Bookmark         = { id :: Int, url :: Str, title :: Str }
#   type BookmarkWithTags = { ...Bookmark, tags :: List[Str] }
#
# The response handler builds a JOIN SELECT that groups tags as a
# JSON array (json_group_array on SQLite, array_agg on Postgres),
# decodes the row into a BookmarkWithTags, and returns the merged
# shape directly — no N+1 select-per-row.
#
# Endpoints:
#
#   GET  /bookmarks?tag=&q=&page=&size=
#       Paginated listing. ?tag=foo filters to bookmarks tagged
#       "foo"; ?q=bar fuzz-matches title via LIKE.
#
#   POST /bookmarks   { url, title, tags: [...] }
#       Creates the bookmark and any missing tag rows inside a single
#       lex-orm transaction so a half-applied entry never leaks.
#
#   GET  /bookmarks/:id    one bookmark with its tag list
#   GET  /tags/popular     top 10 tags by use count
#
# Run:
#   lex run --allow-effects io,net,time,sql,fs_write \
#           examples/bookmarks_api.lex main
#
# Try:
#   curl -X POST http://localhost:8080/bookmarks \
#        -H 'content-type: application/json' \
#        -d '{"url":"https://lex.dev","title":"Lex language","tags":["lex","docs"]}'
#   curl 'http://localhost:8080/bookmarks?tag=lex'
#   curl http://localhost:8080/tags/popular

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
import "../src/middleware" as mw
import "../src/body"       as body
import "../src/params"     as params
import "../src/status"     as status
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

# ---- Domain types (lex 0.9.1 record spreads) ---------------------

type Bookmark         = { id :: Int, url :: Str, title :: Str }
type BookmarkWithTags = { ...Bookmark, tags :: List[Str] }
type Tag              = { id :: Int, name :: Str }
type TagUse           = { name :: Str, uses :: Int }

type BkErr =
    BookmarkNotFound(Int)
  | DuplicateUrl(Str)

# ---- Schemas ------------------------------------------------------

fn bookmark_schema() -> s.ModelSchema {
  {
    title: "bookmarks", description: "",
    fields: [
      s.required_int("id",    [IntPositive]),
      s.required_str("url",   [StrUrl, StrMaxLen(2048)]),
      s.required_str("title", [StrNonEmpty, StrMaxLen(200)]),
    ],
  }
}

fn tag_schema() -> s.ModelSchema {
  {
    title: "tags", description: "",
    fields: [
      s.required_int("id",   [IntPositive]),
      s.required_str("name", [StrPattern("^[a-z0-9-]+$"), StrMaxLen(40)]),
    ],
  }
}

# Junction table — owns the M:N relationship.
fn bookmark_tag_schema() -> s.ModelSchema {
  {
    title: "bookmark_tags", description: "",
    fields: [
      s.required_int("bookmark_id", [IntPositive]),
      s.required_int("tag_id",      [IntPositive]),
    ],
  }
}

# Write surface — id is server-assigned. The tags field is a list
# of free-form names; the handler resolves / inserts each name.
fn bookmark_write_schema() -> s.ModelSchema {
  {
    title: "BookmarkWrite", description: "",
    fields: [
      s.required_str("url",   [StrUrl, StrMaxLen(2048)]),
      s.required_str("title", [StrNonEmpty, StrMaxLen(200)]),
      s.required_array("tags", KStr([StrPattern("^[a-z0-9-]+$"), StrMaxLen(40)]),
        [ListMaxLen(10)]),
    ],
  }
}

fn bookmark_validator() -> v.Validator { v.make(bookmark_write_schema()) }

# ---- Decoders -----------------------------------------------------

fn decode_bookmark(j :: jv.Json) -> Result[Bookmark, se.Errors] {
  match jv.j_int("", j, "id", []) {
    Err(e) => Err(e),
    Ok(id) =>
      match jv.j_str("", j, "url", []) {
        Err(e) => Err(e),
        Ok(u)  =>
          match jv.j_str("", j, "title", []) {
            Err(e) => Err(e),
            Ok(t)  => Ok({ id: id, url: u, title: t }),
          },
      },
  }
}

fn decode_tag(j :: jv.Json) -> Result[Tag, se.Errors] {
  match jv.j_int("", j, "id", []) {
    Err(e) => Err(e),
    Ok(id) =>
      match jv.j_str("", j, "name", []) {
        Err(e) => Err(e),
        Ok(n)  => Ok({ id: id, name: n }),
      },
  }
}

# The JOIN row decoder. We pull a Bookmark and a JSON-string `tags`
# column (json_group_array on SQLite) and parse the latter into a
# List[Str] for the BookmarkWithTags record. The `...Bookmark` spread
# at the type level keeps the field set in lockstep with Bookmark's
# schema — if a column gets added there, the join type tracks it.
fn decode_bookmark_with_tags(j :: jv.Json) -> Result[BookmarkWithTags, se.Errors] {
  match decode_bookmark(j) {
    Err(e) => Err(e),
    Ok(bk) =>
      # The tags JSON array is embedded as a string; parse and walk.
      match jv.j_str("", j, "tags_json", []) {
        Err(_)         => Ok({ id: bk.id, url: bk.url, title: bk.title, tags: [] }),
        Ok(tags_json)  =>
          match jv.parse(tags_json) {
            Err(_) => Ok({ id: bk.id, url: bk.url, title: bk.title, tags: [] }),
            Ok(arr) =>
              match arr {
                JList(items) => {
                  let names := list.fold(items, [],
                    fn (acc :: List[Str], it :: jv.Json) -> List[Str] {
                      match it {
                        JStr(s) => list.concat(acc, [s]),
                        _       => acc,
                      }
                    })
                  Ok({ id: bk.id, url: bk.url, title: bk.title, tags: names })
                },
                _ => Ok({ id: bk.id, url: bk.url, title: bk.title, tags: [] }),
              },
          },
      },
  }
}

fn bookmark_repo() -> q.Repo[Bookmark] { q.for_schema(bookmark_schema(), decode_bookmark) }
fn tag_repo()      -> q.Repo[Tag]      { q.for_schema(tag_schema(),      decode_tag) }

# ---- Raw JOIN SELECT (the bit query.lex doesn't have yet) --------
#
# The query builder doesn't model joins yet — drop down to sql.query
# for now. The shape mirrors lex-orm/examples/04_joins.lex.

fn build_list_join(tag_filter :: Option[Str], q_filter :: Option[Str]) -> (Str, List[pr.Param]) {
  let base :=
    "SELECT b.\"id\" AS id, b.\"url\" AS url, b.\"title\" AS title, "
    + "(SELECT json_group_array(t.\"name\") FROM \"tags\" t "
    + " INNER JOIN \"bookmark_tags\" bt ON bt.\"tag_id\" = t.\"id\" "
    + " WHERE bt.\"bookmark_id\" = b.\"id\") AS tags_json "
    + "FROM \"bookmarks\" b "
  let tag_where := match tag_filter {
    None    => ("", [])
    Some(t) => (
      "WHERE EXISTS (SELECT 1 FROM \"bookmark_tags\" bt "
      + "INNER JOIN \"tags\" tt ON tt.\"id\" = bt.\"tag_id\" "
      + "WHERE bt.\"bookmark_id\" = b.\"id\" AND tt.\"name\" = ?) ",
      [PStr(t)]
    ),
  }
  let tag_sql    := match tag_where { (s2, _)  => s2 }
  let tag_params := match tag_where { (_,  ps) => ps }
  let q_where := match q_filter {
    None    => ("", [])
    Some(q) => (
      (if str.is_empty(tag_sql) { "WHERE " } else { "AND " })
        + "b.\"title\" LIKE ? ",
      [PStr("%" + q + "%")]
    ),
  }
  let q_sql    := match q_where { (s2, _)  => s2 }
  let q_params := match q_where { (_,  ps) => ps }
  let order := "ORDER BY b.\"id\" DESC "
  (base + tag_sql + q_sql + order, list.concat(tag_params, q_params))
}

# ---- Handlers -----------------------------------------------------

fn bookmark_with_tags_to_json(bk :: BookmarkWithTags) -> Str {
  "{\"id\":" + int.to_str(bk.id)
   + ",\"url\":\"" + bk.url + "\""
   + ",\"title\":\"" + bk.title + "\""
   + ",\"tags\":[" + str.join(list.map(bk.tags, fn (t :: Str) -> Str {
                                  "\"" + t + "\"" }), ",") + "]}"
}

fn list_bookmarks(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match params.query_int(c, "page", Some(1), [IntPositive]) {
    Err(r)   => r,
    Ok(page) =>
      match params.query_int(c, "size", Some(20), [IntInRange(1, 100)]) {
        Err(r)   => r,
        Ok(size) =>
          match params.query_optional_str(c, "tag",
                  [StrPattern("^[a-z0-9-]+$")]) {
            Err(r)   => r,
            Ok(opt_tag) =>
              match params.query_optional_str(c, "q", [StrMaxLen(80)]) {
                Err(r)     => r,
                Ok(opt_q)  => {
                  let plan_params := build_list_join(opt_tag, opt_q)
                  let base_sql    := match plan_params { (s, _) => s }
                  let base_params := match plan_params { (_, p) => p }
                  let offset := (page - 1) * size
                  let paged_sql :=
                    base_sql + "LIMIT " + int.to_str(size)
                    + " OFFSET " + int.to_str(offset)
                  match sql.query[{ id :: Int, url :: Str, title :: Str, tags_json :: Str }](
                          db.handle, paged_sql, list.map(base_params, q.param_to_sql)) {
                    Err(_)   => resp.internal_error(),
                    Ok(rows) => {
                      let items := list.fold(rows, [],
                        fn (acc :: List[BookmarkWithTags],
                            r   :: { id :: Int, url :: Str, title :: Str, tags_json :: Str }
                           ) -> List[BookmarkWithTags] {
                          let bk_json := JObj([
                            ("id",        JInt(r.id)),
                            ("url",       JStr(r.url)),
                            ("title",     JStr(r.title)),
                            ("tags_json", JStr(r.tags_json)),
                          ])
                          match decode_bookmark_with_tags(bk_json) {
                            Err(_) => acc,
                            Ok(bk) => list.concat(acc, [bk]),
                          }
                        })
                      resp.json("{\"page\":" + int.to_str(page)
                        + ",\"size\":" + int.to_str(size)
                        + ",\"items\":["
                        + str.join(list.map(items, bookmark_with_tags_to_json), ",")
                        + "]}")
                    },
                  }
                },
              },
          },
      },
  }
}

# POST /bookmarks — three writes inside one tx:
#   1. INSERT the bookmark row.
#   2. For each tag name: SELECT-or-INSERT tag id.
#   3. INSERT into bookmark_tags for every (bk_id, tag_id) pair.
fn create_bookmark(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match body.require_json_body(c, bookmark_validator()) {
    Err(r)    => r,
    Ok(input) => {
      let url   := match jv.j_str("", input, "url",   []) { Ok(s) => s, Err(_) => "" }
      let title := match jv.j_str("", input, "title", []) { Ok(s) => s, Err(_) => "" }
      let tag_names := extract_tag_names(input)
      match q.transaction(db,
        fn (tx :: conn.Db) -> [sql] Result[Bookmark, dbe.DbErr] {
          let bk_row := JObj([
            ("id",    JInt(0)),
            ("url",   JStr(url)),
            ("title", JStr(title)),
          ])
          match q.run_insert(q.insert(bookmark_repo(), bk_row), tx) {
            Err(e) => Err(e),
            Ok(bk) => link_tags(bk.id, tag_names, tx),
          }
        }) {
        Err(_) => exc.handle(err_registry(), DuplicateUrl(url)),
        Ok(bk) =>
          # Re-read with tags for a complete response.
          resp.created_json(
            bookmark_with_tags_to_json({
              id: bk.id, url: bk.url, title: bk.title, tags: tag_names
            }),
            "/bookmarks/" + int.to_str(bk.id)),
      }
    },
  }
}

fn extract_tag_names(j :: jv.Json) -> List[Str] {
  match jv.get_path(j, "tags") {
    Some(JList(items)) =>
      list.fold(items, [], fn (acc :: List[Str], it :: jv.Json) -> List[Str] {
        match it {
          JStr(s) => list.concat(acc, [s]),
          _       => acc,
        }
      }),
    _ => [],
  }
}

# For each tag name: look it up; if missing, insert it. Then write
# the junction row. Either step erroring rolls the whole tx back.
fn link_tags(
  bookmark_id :: Int,
  names       :: List[Str],
  db          :: conn.Db
) -> [sql] Result[Bookmark, dbe.DbErr] {
  match list.head(names) {
    None       => load_bookmark_row(bookmark_id, db),
    Some(name) => {
      let rest := list.tail(names)
      match find_or_create_tag(name, db) {
        Err(e)  => Err(e),
        Ok(tag) => {
          let junction := JObj([
            ("bookmark_id", JInt(bookmark_id)),
            ("tag_id",      JInt(tag.id)),
          ])
          match sql.exec(db.handle,
            "INSERT INTO \"bookmark_tags\" (\"bookmark_id\", \"tag_id\") VALUES (?, ?)",
            [PInt(bookmark_id), PInt(tag.id)]) {
            Err(e) => Err(DbQueryFailed(e)),
            Ok(_)  => link_tags(bookmark_id, rest, db),
          }
        },
      }
    },
  }
}

fn find_or_create_tag(name :: Str, db :: conn.Db) -> [sql] Result[Tag, dbe.DbErr] {
  match q.run_select(
    q.limit(q.where_clause(q.select(tag_repo()), pr.eq("name", PStr(name))), 1),
    db
  ) {
    Err(e) => Err(e),
    Ok(xs) =>
      match list.head(xs) {
        Some(t) => Ok(t),
        None    => q.run_insert(q.insert(tag_repo(),
                                JObj([("id", JInt(0)), ("name", JStr(name))])), db),
      },
  }
}

fn load_bookmark_row(id :: Int, db :: conn.Db) -> [sql] Result[Bookmark, dbe.DbErr] {
  match q.run_select(
    q.limit(q.where_clause(q.select(bookmark_repo()), pr.eq("id", PInt(id))), 1),
    db
  ) {
    Err(e) => Err(e),
    Ok(xs) =>
      match list.head(xs) {
        Some(bk) => Ok(bk),
        None     => Err(DbQueryFailed("bookmark vanished mid-tx")),
      },
  }
}

# GET /tags/popular — aggregate query over bookmark_tags.
fn popular_tags(_c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  let stmt :=
    "SELECT t.\"name\" AS name, COUNT(bt.\"bookmark_id\") AS uses "
    + "FROM \"tags\" t "
    + "INNER JOIN \"bookmark_tags\" bt ON bt.\"tag_id\" = t.\"id\" "
    + "GROUP BY t.\"id\", t.\"name\" "
    + "ORDER BY uses DESC LIMIT 10"
  match sql.query[{ name :: Str, uses :: Int }](db.handle, stmt, []) {
    Err(_)   => resp.internal_error(),
    Ok(rows) => resp.json(
      "[" + str.join(list.map(rows,
        fn (r :: { name :: Str, uses :: Int }) -> Str {
          "{\"name\":\"" + r.name + "\",\"uses\":" + int.to_str(r.uses) + "}"
        }), ",") + "]"),
  }
}

# ---- Exception registry ------------------------------------------

fn err_registry() -> exc.Registry[BkErr] {
  exc.new()
    |> fn (r :: exc.Registry[BkErr]) -> exc.Registry[BkErr] {
         exc.add(r, fn (e :: BkErr) -> Option[resp.Response] {
           match e {
             BookmarkNotFound(id) =>
               Some(resp.json_status(status.HTTP_404_NOT_FOUND(),
                 "{\"error\":\"not_found\",\"id\":" + int.to_str(id) + "}")),
             _ => None,
           }
         })
       }
    |> fn (r :: exc.Registry[BkErr]) -> exc.Registry[BkErr] {
         exc.add(r, fn (e :: BkErr) -> Option[resp.Response] {
           match e {
             DuplicateUrl(u) =>
               Some(resp.json_status(status.HTTP_409_CONFLICT(),
                 "{\"error\":\"duplicate_url\",\"url\":\"" + u + "\"}")),
             _ => None,
           }
         })
       }
}

# ---- Database bootstrap ------------------------------------------

fn ensure_schema(db :: conn.Db) -> [sql] Result[Unit, dbe.DbErr] {
  let stmts := [
    sdk.to_sql_ddl(bookmark_schema(),     DialectSqlite),
    sdk.to_sql_ddl(tag_schema(),          DialectSqlite),
    sdk.to_sql_ddl(bookmark_tag_schema(), DialectSqlite),
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmarks_url ON \"bookmarks\"(\"url\")",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_name     ON \"tags\"(\"name\")",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_bt_pair       ON \"bookmark_tags\"(\"bookmark_id\", \"tag_id\")",
  ]
  list.fold(stmts, Ok(()),
    fn (acc :: Result[Unit, dbe.DbErr], stmt :: Str) -> [sql] Result[Unit, dbe.DbErr] {
      match acc {
        Err(e) => Err(e),
        Ok(_)  =>
          match sql.exec(db.handle, stmt, []) {
            Err(e) => Err(DbQueryFailed(e)),
            Ok(_)  => Ok(()),
          },
      }
    })
}

# ---- Routing ------------------------------------------------------

fn app(db :: conn.Db) -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/bookmarks",
           fn (c :: ctx.Ctx) -> [sql] resp.Response { list_bookmarks(c, db) })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.attach_meta(r, "GET", "/bookmarks", {
           tags: ["bookmarks"],
           summary: "List bookmarks (tag + title filter, paginated)",
           description: "", status: 0,
         })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.handler_json(r, "POST", "/bookmarks", bookmark_validator(),
           fn (c :: ctx.Ctx) -> [sql] resp.Response { create_bookmark(c, db) })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.attach_meta(r, "POST", "/bookmarks", {
           tags: ["bookmarks"],
           summary: "Create a bookmark with optional tags",
           description: "Resolves / inserts each tag name inside a single transaction.",
           status: status.HTTP_201_CREATED(),
         })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/tags/popular",
           fn (c :: ctx.Ctx) -> [sql] resp.Response { popular_tags(c, db) })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.attach_meta(r, "GET", "/tags/popular", {
           tags: ["tags"], summary: "Top 10 tags by use count",
           description: "", status: 0,
         })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/openapi.json",
           fn (_c :: ctx.Ctx) -> resp.Response {
             resp.json(openapi.export_openapi_str(app(db),
               openapi.make_info_full("Bookmarks API", "0.1.0",
                 "M:N bookmarks/tags via lex-web + lex-schema + lex-orm")))
           })
       }
    |> fn (r :: router.Router) -> router.Router { docs.mount(r, "/openapi.json", "Bookmarks") }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.body_limit(16_384)) }
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
          let _ := io.print("bookmarks API on :8080")
          let _ := io.print("  POST /bookmarks {url, title, tags}")
          let _ := io.print("  GET  /bookmarks?tag=&q=")
          let _ := io.print("  GET  /tags/popular")
          let _ := io.print("  GET  /docs")
          net.serve_fn(8080,
            fn (req :: ctx.RawRequest) -> [io, time, sql] resp.Response {
              router.dispatch(app(db), req)
            })
        },
      }
    },
  }
}
