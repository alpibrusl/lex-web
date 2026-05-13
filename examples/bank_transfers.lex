# lex-web example — Bank Transfers API (atomic transactions e2e)
#
# The killer feature of an ORM is *transactions*. This example
# models money movement between two accounts as a single SQL
# transaction so a partial failure leaves the books balanced:
#
#   POST /transfers           { from, to, amount_cents }
#     -> 201 + transfer record
#     -> 409 if either side would overdraft (with the structured
#        reason) — the debit is rolled back, the credit never runs
#     -> 404 if either account doesn't exist
#
#   GET /accounts/:id         account balance + recent transfers
#
# Two tables, one source of truth per shape: lex-schema's ModelSchema
# drives both the lex-orm Repo and the lex-web request validator.
# The transfer happens inside `q.transaction` so the debit / credit
# / journal write either all commit or all roll back.
#
# Run:
#   lex run --allow-effects io,net,time,sql,fs_write \
#           examples/bank_transfers.lex main
#
# Try:
#   curl http://localhost:8080/accounts/1                        # balance
#   curl -X POST http://localhost:8080/transfers \
#        -H 'content-type: application/json' \
#        -d '{"from_id":1,"to_id":2,"amount_cents":2500,"memo":"coffee"}'
#   curl http://localhost:8080/accounts/2

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

# ---- Schemas ------------------------------------------------------

type Account  = { id :: Int, owner :: Str, balance_cents :: Int }
type Transfer = { id :: Int, from_id :: Int, to_id :: Int, amount_cents :: Int, memo :: Str }

type TransferErr =
    AccountNotFound(Int)
  | InsufficientFunds(Int)
  | SameAccount

fn account_schema() -> s.ModelSchema {
  {
    title: "accounts", description: "",
    fields: [
      s.required_int("id",            [IntPositive]),
      s.required_str("owner",         [StrNonEmpty, StrMaxLen(80)]),
      s.required_int("balance_cents", [IntNonNegative]),
    ],
  }
}

fn transfer_schema() -> s.ModelSchema {
  {
    title: "transfers", description: "",
    fields: [
      s.required_int("id",           [IntPositive]),
      s.required_int("from_id",      [IntPositive]),
      s.required_int("to_id",        [IntPositive]),
      s.required_int("amount_cents", [IntPositive]),
      s.required_str("memo",         [StrMaxLen(120)]),
    ],
  }
}

# Write surface — id is server-assigned.
fn transfer_write_schema() -> s.ModelSchema {
  {
    title: "TransferRequest", description: "",
    fields: [
      s.required_int("from_id",      [IntPositive]),
      s.required_int("to_id",        [IntPositive]),
      s.required_int("amount_cents", [IntInRange(1, 100_000_00)]),  # ≤ $100k
      s.required_str("memo",         [StrMaxLen(120)]),
    ],
  }
}

fn transfer_validator() -> v.Validator { v.make(transfer_write_schema()) }

fn decode_account(j :: jv.Json) -> Result[Account, se.Errors] {
  match jv.j_int("", j, "id", []) {
    Err(e) => Err(e),
    Ok(id) =>
      match jv.j_str("", j, "owner", []) {
        Err(e) => Err(e),
        Ok(o)  =>
          match jv.j_int("", j, "balance_cents", []) {
            Err(e) => Err(e),
            Ok(b)  => Ok({ id: id, owner: o, balance_cents: b }),
          },
      },
  }
}

fn decode_transfer(j :: jv.Json) -> Result[Transfer, se.Errors] {
  match jv.j_int("", j, "id", []) {
    Err(e) => Err(e),
    Ok(id) =>
      match jv.j_int("", j, "from_id", []) {
        Err(e)  => Err(e),
        Ok(fid) =>
          match jv.j_int("", j, "to_id", []) {
            Err(e)  => Err(e),
            Ok(tid) =>
              match jv.j_int("", j, "amount_cents", []) {
                Err(e)  => Err(e),
                Ok(amt) =>
                  match jv.j_str("", j, "memo", []) {
                    Err(e)  => Err(e),
                    Ok(m)   => Ok({
                      id: id, from_id: fid, to_id: tid,
                      amount_cents: amt, memo: m
                    }),
                  },
              },
          },
      },
  }
}

fn account_repo()  -> q.Repo[Account]  { q.for_schema(account_schema(),  decode_account) }
fn transfer_repo() -> q.Repo[Transfer] { q.for_schema(transfer_schema(), decode_transfer) }

# ---- The transfer transaction ------------------------------------
#
# The whole point of this example. Three writes:
#
#   1. SELECT balance for from_id (with WHERE for tx isolation)
#   2. DECREMENT from_id balance — fails if balance < amount
#   3. INCREMENT to_id balance
#   4. INSERT a transfers row recording the journal entry
#
# Any failure in 1-4 rolls back via q.transaction; the database
# never sees a half-applied transfer. The handler returns either
# the journal row on success or a typed TransferErr.

fn do_transfer(
  from_id :: Int,
  to_id   :: Int,
  amount  :: Int,
  memo    :: Str,
  db      :: conn.Db
) -> [sql] Result[Transfer, TransferErr] {
  if from_id == to_id { Err(SameAccount) }
  else {
    q.transaction(db,
      fn (tx :: conn.Db) -> [sql] Result[Transfer, dbe.DbErr] {
        match load_account(from_id, tx) {
          Err(_) => Err(DbQueryFailed("from-load")),
          Ok(None) => Err(DbQueryFailed("from-missing")),
          Ok(Some(a_from)) =>
            if a_from.balance_cents < amount {
              # Conventional way to signal "abort the tx with a
              # business-level reason" — surface a DbErr the outer
              # function maps to the typed TransferErr. The tx
              # rolls back; no debit lands.
              Err(DbQueryFailed("insufficient"))
            } else {
              match load_account(to_id, tx) {
                Err(_)        => Err(DbQueryFailed("to-load")),
                Ok(None)      => Err(DbQueryFailed("to-missing")),
                Ok(Some(_a))  =>
                  match adjust_balance(from_id, 0 - amount, tx) {
                    Err(e) => Err(e),
                    Ok(_)  =>
                      match adjust_balance(to_id, amount, tx) {
                        Err(e) => Err(e),
                        Ok(_)  => insert_transfer(from_id, to_id, amount, memo, tx),
                      },
                  },
              }
            },
        }
      }) |> fn (r :: Result[Transfer, dbe.DbErr]) -> Result[Transfer, TransferErr] {
        match r {
          Ok(t)  => Ok(t),
          Err(DbQueryFailed("insufficient"))  => Err(InsufficientFunds(from_id)),
          Err(DbQueryFailed("from-missing"))  => Err(AccountNotFound(from_id)),
          Err(DbQueryFailed("to-missing"))    => Err(AccountNotFound(to_id)),
          Err(_) => Err(InsufficientFunds(from_id)),  # generic fallback
        }
      }
  }
}

fn load_account(id :: Int, db :: conn.Db) -> [sql] Result[Option[Account], dbe.DbErr] {
  match q.run_select(
    q.limit(q.where_clause(q.select(account_repo()), pr.eq("id", PInt(id))), 1),
    db
  ) {
    Err(e) => Err(e),
    Ok(xs) => Ok(list.head(xs)),
  }
}

# Atomic balance adjustment — delta can be negative.
fn adjust_balance(
  id    :: Int,
  delta :: Int,
  db    :: conn.Db
) -> [sql] Result[Unit, dbe.DbErr] {
  # We use raw SQL here because the query builder doesn't yet
  # support `SET balance = balance + ?`. The placeholder is still
  # safely bound through sql.exec.
  let stmt := "UPDATE \"accounts\" SET \"balance_cents\" = \"balance_cents\" + ? WHERE \"id\" = ?"
  match sql.exec(db.handle, stmt, [PInt(delta), PInt(id)]) {
    Err(e) => Err(DbQueryFailed(e)),
    Ok(_)  => Ok(()),
  }
}

fn insert_transfer(
  from_id :: Int,
  to_id   :: Int,
  amount  :: Int,
  memo    :: Str,
  db      :: conn.Db
) -> [sql] Result[Transfer, dbe.DbErr] {
  let row := JObj([
    ("id",           JInt(0)),       # AUTOINCREMENT overwrites
    ("from_id",      JInt(from_id)),
    ("to_id",        JInt(to_id)),
    ("amount_cents", JInt(amount)),
    ("memo",         JStr(memo)),
  ])
  q.run_insert(q.insert(transfer_repo(), row), db)
}

# ---- Exception registry ------------------------------------------

fn err_registry() -> exc.Registry[TransferErr] {
  exc.new()
    |> fn (r :: exc.Registry[TransferErr]) -> exc.Registry[TransferErr] {
         exc.add(r, fn (e :: TransferErr) -> Option[resp.Response] {
           match e {
             AccountNotFound(id) =>
               Some(resp.json_status(status.HTTP_404_NOT_FOUND(),
                 "{\"error\":\"account_not_found\",\"id\":" + int.to_str(id) + "}")),
             _ => None,
           }
         })
       }
    |> fn (r :: exc.Registry[TransferErr]) -> exc.Registry[TransferErr] {
         exc.add(r, fn (e :: TransferErr) -> Option[resp.Response] {
           match e {
             InsufficientFunds(id) =>
               Some(resp.json_status(status.HTTP_409_CONFLICT(),
                 "{\"error\":\"insufficient_funds\",\"from_id\":" + int.to_str(id) + "}")),
             _ => None,
           }
         })
       }
    |> fn (r :: exc.Registry[TransferErr]) -> exc.Registry[TransferErr] {
         exc.add(r, fn (e :: TransferErr) -> Option[resp.Response] {
           match e {
             SameAccount =>
               Some(resp.bad_request("from_id and to_id must differ")),
             _ => None,
           }
         })
       }
}

# ---- Handlers -----------------------------------------------------

fn transfer_to_json(t :: Transfer) -> Str {
  "{\"id\":" + int.to_str(t.id)
   + ",\"from_id\":" + int.to_str(t.from_id)
   + ",\"to_id\":" + int.to_str(t.to_id)
   + ",\"amount_cents\":" + int.to_str(t.amount_cents)
   + ",\"memo\":\"" + t.memo + "\"}"
}

fn account_to_json(a :: Account, recent :: List[Transfer]) -> Str {
  "{\"id\":" + int.to_str(a.id)
   + ",\"owner\":\"" + a.owner + "\""
   + ",\"balance_cents\":" + int.to_str(a.balance_cents)
   + ",\"recent_transfers\":["
   + str.join(list.map(recent, transfer_to_json), ",")
   + "]}"
}

fn get_account(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match params.path_int(c, "id", [IntPositive]) {
    Err(r) => r,
    Ok(id) =>
      match load_account(id, db) {
        Err(_)   => resp.internal_error(),
        Ok(None) => exc.handle(err_registry(), AccountNotFound(id)),
        Ok(Some(a)) =>
          match q.run_select(
            q.limit(q.order_by(
              q.where_clause(q.select(transfer_repo()),
                pr.or_pred(pr.eq("from_id", PInt(id)),
                           pr.eq("to_id",   PInt(id)))),
              "id", Desc), 10),
            db
          ) {
            Err(_)   => resp.internal_error(),
            Ok(recent) => resp.json(account_to_json(a, recent)),
          },
      },
  }
}

fn post_transfer(c :: ctx.Ctx, db :: conn.Db) -> [sql] resp.Response {
  match body.require_json_body(c, transfer_validator()) {
    Err(r)   => r,
    Ok(body) => {
      let from_id := match jv.j_int("", body, "from_id", []) { Ok(n) => n, Err(_) => 0 }
      let to_id   := match jv.j_int("", body, "to_id",   []) { Ok(n) => n, Err(_) => 0 }
      let amount  := match jv.j_int("", body, "amount_cents", []) { Ok(n) => n, Err(_) => 0 }
      let memo    := match jv.j_str("", body, "memo",   []) { Ok(s) => s, Err(_) => "" }
      match do_transfer(from_id, to_id, amount, memo, db) {
        Err(e) => exc.handle(err_registry(), e),
        Ok(t)  => resp.created_json(transfer_to_json(t),
                    "/transfers/" + int.to_str(t.id)),
      }
    },
  }
}

# ---- Database bootstrap ------------------------------------------

fn ensure_schema(db :: conn.Db) -> [sql] Result[Unit, dbe.DbErr] {
  match sql.exec(db.handle, sdk.to_sql_ddl(account_schema(),  DialectSqlite), []) {
    Err(e) => Err(DbQueryFailed(e)),
    Ok(_)  =>
      match sql.exec(db.handle, sdk.to_sql_ddl(transfer_schema(), DialectSqlite), []) {
        Err(e) => Err(DbQueryFailed(e)),
        Ok(_)  => seed_accounts(db),
      },
  }
}

fn seed_accounts(db :: conn.Db) -> [sql] Result[Unit, dbe.DbErr] {
  let alice := JObj([("id", JInt(0)), ("owner", JStr("alice")), ("balance_cents", JInt(10_000_00))])
  let bob   := JObj([("id", JInt(0)), ("owner", JStr("bob")),   ("balance_cents", JInt(50_00))])
  match q.run_insert(q.insert(account_repo(), alice), db) {
    Err(e) => Err(e),
    Ok(_)  =>
      match q.run_insert(q.insert(account_repo(), bob), db) {
        Err(e) => Err(e),
        Ok(_)  => Ok(()),
      },
  }
}

# ---- Routing ------------------------------------------------------

fn app(db :: conn.Db) -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/accounts/:id",
           fn (c :: ctx.Ctx) -> [sql] resp.Response { get_account(c, db) })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.attach_meta(r, "GET", "/accounts/:id", {
           tags:        ["accounts"],
           summary:     "Account balance + 10 most recent transfers",
           description: "",
           status:      0,
         })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.handler_json(r, "POST", "/transfers", transfer_validator(),
           fn (c :: ctx.Ctx) -> [sql] resp.Response { post_transfer(c, db) })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.attach_meta(r, "POST", "/transfers", {
           tags:        ["transfers"],
           summary:     "Atomic transfer between two accounts",
           description: "Runs SELECT-balance / UPDATE-from / UPDATE-to / INSERT-journal in a single transaction. Any failure rolls back; the books always balance.",
           status:      status.HTTP_201_CREATED(),
         })
       }
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/openapi.json",
           fn (_c :: ctx.Ctx) -> resp.Response {
             resp.json(openapi.export_openapi_str(app(db),
               openapi.make_info_full("Ledger API", "0.1.0",
                 "Atomic money movement on lex-web + lex-orm")))
           })
       }
    |> fn (r :: router.Router) -> router.Router { docs.mount(r, "/openapi.json", "Ledger") }
    |> fn (r :: router.Router) -> router.Router { router.use_mw(r, mw.body_limit(4_096)) }
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
          let _ := io.print("ledger on :8080 (alice=$10000, bob=$50)")
          let _ := io.print("  POST /transfers")
          let _ := io.print("  GET  /accounts/:id")
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
