# Tests for src/params.lex — typed query/path/header parameter
# extractors. Failures must surface as a 422 problem+json response,
# successes as the typed value.

import "std.list" as list

import "std.map" as map

import "../src/ctx" as ctx

import "../src/params" as params

import "../src/testing" as t

# ---- Helpers -----------------------------------------------------
fn ctx_for(req :: ctx.RawRequest) -> ctx.Ctx {
  ctx.from_request(req, map.new())
}

fn ctx_for_with_path(req :: ctx.RawRequest, path_params :: List[(Str, Str)]) -> ctx.Ctx {
  ctx.from_request(req, map.from_list(path_params))
}

# ---- Query params ------------------------------------------------
fn test_query_int_present() -> Result[Unit, Str] {
  let c := ctx_for(t.request("GET", "/", "", "page=3"))
  match params.query_int(c, "page", Some(1), [IntPositive]) {
    Ok(3) => Ok(()),
    Ok(_) => Err("wrong int"),
    Err(_) => Err("expected ok"),
  }
}

fn test_query_int_default() -> Result[Unit, Str] {
  let c := ctx_for(t.get("/"))
  match params.query_int(c, "page", Some(7), [IntPositive]) {
    Ok(7) => Ok(()),
    Ok(_) => Err("wrong default"),
    Err(_) => Err("expected default"),
  }
}

fn test_query_int_missing_no_default() -> Result[Unit, Str] {
  let c := ctx_for(t.get("/"))
  match params.query_int(c, "page", None, []) {
    Err(r) => if r.status == 422 {
      Ok(())
    } else {
      Err("expected 422")
    },
    Ok(_) => Err("expected error"),
  }
}

fn test_query_int_invalid() -> Result[Unit, Str] {
  let c := ctx_for(t.request("GET", "/", "", "page=abc"))
  match params.query_int(c, "page", None, []) {
    Err(r) => if r.status == 422 {
      Ok(())
    } else {
      Err("expected 422")
    },
    Ok(_) => Err("should not parse"),
  }
}

fn test_query_int_constraint_fail() -> Result[Unit, Str] {
  let c := ctx_for(t.request("GET", "/", "", "page=-5"))
  match params.query_int(c, "page", None, [IntPositive]) {
    Err(r) => if r.status == 422 {
      Ok(())
    } else {
      Err("expected 422")
    },
    Ok(_) => Err("should fail constraint"),
  }
}

fn test_query_str_default() -> Result[Unit, Str] {
  let c := ctx_for(t.get("/"))
  match params.query_str(c, "name", Some("anon"), []) {
    Ok(v) => if v == "anon" {
      Ok(())
    } else {
      Err("wrong default")
    },
    Err(_) => Err("expected default"),
  }
}

fn test_query_optional_int_absent_is_ok_none() -> Result[Unit, Str] {
  let c := ctx_for(t.get("/"))
  match params.query_optional_int(c, "limit", []) {
    Ok(None) => Ok(()),
    Ok(Some(_)) => Err("expected None"),
    Err(_) => Err("must not error on absent"),
  }
}

fn test_query_bool_truthy() -> Result[Unit, Str] {
  let c := ctx_for(t.request("GET", "/", "", "debug=yes"))
  match params.query_bool(c, "debug", Some(false)) {
    Ok(true) => Ok(()),
    _ => Err("expected true"),
  }
}

# ---- Path params -------------------------------------------------
fn test_path_int_ok() -> Result[Unit, Str] {
  let c := ctx_for_with_path(t.get("/users/42"), [("id", "42")])
  match params.path_int(c, "id", []) {
    Ok(42) => Ok(()),
    _ => Err("path_int failed"),
  }
}

fn test_path_int_invalid() -> Result[Unit, Str] {
  let c := ctx_for_with_path(t.get("/users/abc"), [("id", "abc")])
  match params.path_int(c, "id", []) {
    Err(r) => if r.status == 422 {
      Ok(())
    } else {
      Err("expected 422")
    },
    _ => Err("expected error"),
  }
}

# ---- Bearer ------------------------------------------------------
fn test_bearer_present() -> Result[Unit, Str] {
  let req := t.request_with_headers("GET", "/", "", "", [("authorization", "Bearer abc123")])
  let c := ctx_for(req)
  match params.bearer(c) {
    Ok(tok) => if tok == "abc123" {
      Ok(())
    } else {
      Err("wrong token")
    },
    Err(_) => Err("expected ok"),
  }
}

fn test_bearer_missing() -> Result[Unit, Str] {
  let c := ctx_for(t.get("/"))
  match params.bearer(c) {
    Err(r) => if r.status == 401 {
      Ok(())
    } else {
      Err("expected 401")
    },
    Ok(_) => Err("should fail without header"),
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> List[Result[Unit, Str]] {
  [test_query_int_present(), test_query_int_default(), test_query_int_missing_no_default(), test_query_int_invalid(), test_query_int_constraint_fail(), test_query_str_default(), test_query_optional_int_absent_is_ok_none(), test_query_bool_truthy(), test_path_int_ok(), test_path_int_invalid(), test_bearer_present(), test_bearer_missing()]
}

fn run_all() -> Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __lex_discard_1 := 1 / 0
    ()
  }
}

