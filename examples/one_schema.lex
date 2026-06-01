# one_schema.lex -- "one schema, every artifact" theatrical demo
#
# A single `ModelSchema` drives:
#   - validation (all errors at once)
#   - pure SQL query building (no DB, no session)
#   - DDL + schema diff / migration
#   - TypeScript codegen
#   - Python codegen
#   - OpenAPI export
#
# Run:
#   lex run --allow-effects io examples/one_schema.lex main

import "std.io"   as io
import "std.list" as list
import "std.int"  as int
import "std.str"  as str

import "lex-schema/schema"      as s
import "lex-schema/constraints" as c
import "lex-schema/validator"   as v
import "lex-schema/json_value"  as jv
import "lex-schema/error"       as se

import "lex-orm/query"      as q
import "lex-orm/predicate"  as pr
import "lex-orm/migrate"    as mig
import "lex-orm/connection" as conn

# io.print does not add a trailing newline; ln appends one so the
# fmt post-processor sees clean line boundaries.
fn ln(s2 :: Str) -> [io] Unit {
  io.print(s2 + "\n")
}

# ---- Domain type --------------------------------------------------
type Order = {
  id         :: Str,
  symbol     :: Str,
  side       :: Str,
  quantity   :: Int,
  price      :: Str,
  account_id :: Str,
}

# Decode a jv.Json into an Order -- nested match chain.
fn decode_order(j :: jv.Json) -> Result[Order, se.Errors] {
  match jv.j_str("", j, "id", []) {
    Err(e) => Err(e),
    Ok(id) => match jv.j_str("", j, "symbol", []) {
      Err(e) => Err(e),
      Ok(symbol) => match jv.j_str("", j, "side", []) {
        Err(e) => Err(e),
        Ok(side) => match jv.j_int("", j, "quantity", []) {
          Err(e) => Err(e),
          Ok(quantity) => match jv.j_str("", j, "price", []) {
            Err(e) => Err(e),
            Ok(price) => match jv.j_str("", j, "account_id", []) {
              Err(e) => Err(e),
              Ok(account_id) => Ok({
                id:         id,
                symbol:     symbol,
                side:       side,
                quantity:   quantity,
                price:      price,
                account_id: account_id,
              }),
            },
          },
        },
      },
    },
  }
}

# ---- Schema definitions -------------------------------------------
fn order_schema() -> s.ModelSchema {
  {
    title:       "Order",
    description: "A trading order.",
    fields: [
      s.required_str("id",         [StrUuid]),
      s.required_str("symbol",     [StrNonEmpty, StrMaxLen(10)]),
      s.required_str("side",       [StrOneOf(["buy", "sell"])]),
      s.required_int("quantity",   [IntPositive, IntMax(10000)]),
      s.required_str("price",      [StrNonEmpty]),
      s.required_str("account_id", [StrNonEmpty]),
    ],
  }
}

fn order_schema_v2() -> s.ModelSchema {
  {
    title:       "Order",
    description: "A trading order.",
    fields: [
      s.required_str("id",         [StrUuid]),
      s.required_str("symbol",     [StrNonEmpty, StrMaxLen(10)]),
      s.required_str("side",       [StrOneOf(["buy", "sell"])]),
      s.required_int("quantity",   [IntPositive, IntMax(10000)]),
      s.required_str("price",      [StrNonEmpty]),
      s.required_str("account_id", [StrNonEmpty]),
      s.required_str("status",     [StrOneOf(["pending", "filled", "cancelled"])]),
    ],
  }
}

fn order_validator() -> v.Validator {
  v.make(order_schema())
}

# ---- SqlParam renderer (pure) -------------------------------------
fn param_to_str(p :: SqlParam) -> Str {
  match p {
    PStr(s2) => "\"" + s2 + "\"",
    PInt(n)  => int.to_str(n),
    PNull    => "null",
  }
}

fn params_to_str(ps :: List[SqlParam]) -> Str {
  "[" + str.join(list.map(ps, param_to_str), ", ") + "]"
}

# ---- Section 1 -- Schema summary ----------------------------------
fn section_schema() -> [io] Unit {
  let __1 := ln("")
  let __2 := ln("  -- Order schema ------------------------------------------------")
  let __3 := ln("  6 fields . defined once . derived everywhere")
  let __4 := ln("")
  let __5 := ln("    id           Str   [uuid]")
  let __6 := ln("    symbol       Str   [non-empty, max 10]")
  let __7 := ln("    side         Str   [one of: buy, sell]")
  let __8 := ln("    quantity     Int   [positive, max 10000]")
  let __9 := ln("    price        Str   [non-empty]")
  let __10 := ln("    account_id   Str   [non-empty]")
  let __11 := ln("")
  ()
}

# ---- Section 2 -- Validation --------------------------------------
fn section_validation() -> [io] Unit {
  let val := order_validator()

  let __h := ln("  -- Validation --------------------------------------------------")

  # Valid order
  let valid_json := "{\"id\":\"550e8400-e29b-41d4-a716-446655440000\",\"symbol\":\"MSFT\",\"side\":\"buy\",\"quantity\":100,\"price\":\"125.50\",\"account_id\":\"ACC-1\"}"
  let __v1 := ln("  Valid order:")
  let __v2 := ln("  " + valid_json)
  let __v3 := match v.validate_str(val, valid_json) {
    Ok(_)     => ln("  ok -- all fields pass"),
    Err(errs) => ln("  unexpected errors: " + se.format(errs)),
  }
  let __v4 := ln("")

  # Invalid order -- 4 simultaneous errors
  let bad_json := "{\"id\":\"not-a-uuid\",\"symbol\":\"TOOLONGSYMBOL\",\"side\":\"short\",\"quantity\":-5,\"price\":\"99.00\",\"account_id\":\"ACC-1\"}"
  let __b1 := ln("  Invalid order:")
  let __b2 := ln("  " + bad_json)
  let __b3 := match v.validate_str(val, bad_json) {
    Ok(_)     => ln("  unexpected Ok"),
    Err(errs) => {
      let n   := list.len(errs)
      let __e1 := ln("  x  " + int.to_str(n) + " validation errors -- all returned at once")
      let __e2 := list.fold(errs, (), fn (_acc :: Unit, err :: se.Error) -> [io] Unit {
        ln("     " + err.path + ": " + err.code + " -- " + err.message)
      })
      ()
    },
  }
  let __b4 := ln("")
  let __b5 := ln("  -> Python Pydantic v1 would stop after the first error.")
  let __b6 := ln("")
  ()
}

# ---- Section 3 -- Pure query building -----------------------------
fn section_queries() -> [io] Unit {
  let repo := q.for_schema(order_schema(), decode_order)

  let __h  := ln("  -- Pure query building -----------------------------------------")
  let __h2 := ln("  SELECT -- no database, no session, no connection needed")
  let __h3 := ln("")

  # SELECT with two WHERE clauses and LIMIT
  let sel :=
    q.limit(
      q.where_clause(
        q.where_clause(q.select(repo), pr.eq("account_id", PStr("ACC-1"))),
        pr.eq("side", PStr("buy"))
      ),
      20
    )
  let built := q.build_select(sel)
  let __s1 := ln("  sql:    " + built.sql)
  let __s2 := ln("  params: " + params_to_str(built.params))
  let __s3 := ln("")

  # INSERT
  let valid_json_val := JObj([
    ("id",         JStr("550e8400-e29b-41d4-a716-446655440000")),
    ("symbol",     JStr("MSFT")),
    ("side",       JStr("buy")),
    ("quantity",   JInt(100)),
    ("price",      JStr("125.50")),
    ("account_id", JStr("ACC-1")),
  ])
  let ins      := q.insert(repo, valid_json_val)
  let built_ins := q.build_insert(ins)
  let __i1 := ln("  INSERT RETURNING:")
  let __i2 := ln("  sql:    " + built_ins.sql + " RETURNING *")
  let __i3 := ln("  params: " + params_to_str(built_ins.params))
  let __i4 := ln("")
  let __i5 := ln("  -> SQLAlchemy: session.add(obj); session.commit() -- needs a live session + transaction.")
  let __i6 := ln("  -> lex-orm:   build_insert(q) returns {sql, params} -- pure, testable, no DB.")
  let __i7 := ln("")
  ()
}

# ---- Section 4 -- DDL from schema ---------------------------------
fn section_ddl() -> [io] Unit {
  let __h := ln("  -- Schema-driven DDL -------------------------------------------")

  let ddl     := mig.to_create_table(order_schema(), DbSqlite(()))
  let __d1 := ln(ddl)
  let __d2 := ln("")

  let changes := mig.diff(order_schema(), order_schema_v2())
  let alter   := mig.to_alter_table("Order", changes, DbSqlite(()))
  let __d3 := ln("  Schema evolution  diff(v1, v2):")
  let __d4 := ln(alter)
  let __d5 := ln("")
  let __d6 := ln("  -> SQLAlchemy+Alembic: write a new migration file per change.")
  let __d7 := ln("  -> lex-orm: diff(old, new) computes ALTER TABLE from the schema types.")
  let __d8 := ln("")
  ()
}

# ---- Section 5 -- Codegen -----------------------------------------
fn section_codegen() -> [io] Unit {
  let val := order_validator()

  let __h := ln("  -- Codegen -----------------------------------------------------")

  let ts := v.export_typescript(val)
  let py := v.export_python(val)

  let __t1 := ln("  TypeScript:")
  let __t2 := ln(ts)
  let __t3 := ln("")
  let __t4 := ln("  Python:")
  let __t5 := ln(py)
  let __t6 := ln("")
  let __t7 := ln("  -> Python: maintain TypeScript types manually or add a codegen build step.")
  let __t8 := ln("  -> Lex:    export_typescript(validator) -- derived from the same constraints, always in sync.")
  let __t9 := ln("")
  ()
}

# ---- Section 6 -- Summary table -----------------------------------
fn section_summary() -> [io] Unit {
  let __h  := ln("  -- Summary -----------------------------------------------------")
  let __h2 := ln("  One schema definition in lex. In Python: five separate files.")
  let __h3 := ln("")
  let __t0 := ln("  Artifact                    Python                   Lex")
  let __t1 := ln("  --------------------------  -----------------------  --------------")
  let __t2 := ln("  Request validation          Pydantic model           order_schema")
  let __t3 := ln("  Response shaping            Pydantic model (or 2nd)  order_schema")
  let __t4 := ln("  Database model              SQLAlchemy ORM class     order_schema")
  let __t5 := ln("  OpenAPI spec                FastAPI auto-gen         order_schema")
  let __t6 := ln("  TypeScript client types     manual / tsc plugin      order_schema")
  let __t7 := ln("  Migration                   Alembic revision file    diff(v1, v2)")
  let __t8 := ln("  Effect enforcement          none                     [sql] in sig")
  let __t9 := ln("")
  ()
}

# ---- Entry point --------------------------------------------------
fn main() -> [fs_write, io, sql] Unit {
  let __1 := ln("")
  let __2 := ln("  lex-web . one schema, every artifact")
  let __3 := ln("  A single ModelSchema drives validation, DDL, queries, and codegen.")
  let __4 := ln("")
  let __5 := section_schema()
  let __6 := section_validation()
  let __7 := section_queries()
  let __8 := section_ddl()
  let __9 := section_codegen()
  let __10 := section_summary()
  ()
}
