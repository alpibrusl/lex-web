# Tests for src/depends.lex — Dep[T] composition + inject helpers.

import "std.list" as list

import "std.map" as map

import "std.int" as int

import "std.str" as str

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/depends" as depends

import "../src/testing" as t

# ---- Test deps ---------------------------------------------------
fn dep_const_int(_c :: ctx.Ctx) -> Result[Int, resp.Response] {
  Ok(7)
}

fn dep_const_str(_c :: ctx.Ctx) -> Result[Str, resp.Response] {
  Ok("hi")
}

fn dep_fail(_c :: ctx.Ctx) -> Result[Int, resp.Response] {
  Err(resp.unauthorized("nope"))
}

fn handler1(_c :: ctx.Ctx, n :: Int) -> resp.Response {
  resp.text(int.to_str(n))
}

fn handler2(_c :: ctx.Ctx, n :: Int, s :: Str) -> resp.Response {
  resp.text(str.concat(s, str.concat(":", int.to_str(n))))
}

# ---- inject1 -----------------------------------------------------
fn test_inject1_ok() -> Result[Unit, Str] {
  let c := ctx.from_request(t.get("/"), map.new())
  let r := depends.inject1(c, dep_const_int, handler1)
  if r.status == 200 and r.body == "7" {
    Ok(())
  } else {
    Err("inject1 ok body wrong")
  }
}

fn test_inject1_short_circuits() -> Result[Unit, Str] {
  let c := ctx.from_request(t.get("/"), map.new())
  let r := depends.inject1(c, dep_fail, handler1)
  if r.status == 401 {
    Ok(())
  } else {
    Err("expected 401")
  }
}

# ---- inject2 -----------------------------------------------------
fn test_inject2_ok() -> Result[Unit, Str] {
  let c := ctx.from_request(t.get("/"), map.new())
  let r := depends.inject2(c, dep_const_int, dep_const_str, handler2)
  if r.status == 200 and r.body == "hi:7" {
    Ok(())
  } else {
    Err("inject2 ok body wrong")
  }
}

fn test_inject2_first_fails() -> Result[Unit, Str] {
  let c := ctx.from_request(t.get("/"), map.new())
  let r := depends.inject2(c, dep_fail, dep_const_str, fn (_cc :: ctx.Ctx, _n :: Int, _s :: Str) -> resp.Response {
    resp.text("unreached")
  })
  if r.status == 401 {
    Ok(())
  } else {
    Err("expected 401")
  }
}

# ---- bind / map / pure -------------------------------------------
fn test_bind_chains() -> Result[Unit, Str] {
  let r := depends.bind(Ok(3), fn (n :: Int) -> Result[Int, resp.Response] {
    Ok(n + 1)
  })
  match r {
    Ok(4) => Ok(()),
    _ => Err("bind chain wrong"),
  }
}

fn test_map_passes_err() -> Result[Unit, Str] {
  let r := depends.map_ok(Err(resp.unauthorized("x")), fn (n :: Int) -> Int {
    n + 1
  })
  match r {
    Err(_) => Ok(()),
    Ok(_) => Err("expected err"),
  }
}

fn test_pure_lifts() -> Result[Unit, Str] {
  match depends.pure(99) {
    Ok(99) => Ok(()),
    _ => Err("pure broken"),
  }
}

# ---- cached_str -------------------------------------------------
# Counter so we can observe whether the fallback ran. Lex doesn't
# have mutable state directly, but we can use a `conc` actor or
# (simpler for a test) a closure over a List wrapper. The
# cleanest test shape: track WHICH branch fired via the value
# returned, so we don't need a counter.
#
# Fallback dep that always returns Ok("computed"). If the cache
# hits, this never runs; cached_str returns Ok("from-state").
fn fallback_computed(_c :: ctx.Ctx) -> Result[Str, resp.Response] {
  Ok("computed")
}

fn fallback_errors(_c :: ctx.Ctx) -> Result[Str, resp.Response] {
  Err(resp.bad_request("fallback ran"))
}

fn cached_str_hits_state_when_present() -> Result[Unit, Str] {
  let c := ctx.set_state(ctx.from_request({ method: "GET", path: "/", body: "", query: "", headers: map.new() }, map.new()), "user-id", "from-state")
  match depends.cached_str(c, "user-id", fallback_errors) {
    Ok(v) => if v == "from-state" {
      Ok(())
    } else {
      Err(str.concat("got: ", v))
    },
    Err(_) => Err("fallback ran despite state hit"),
  }
}

fn cached_str_runs_fallback_on_miss() -> Result[Unit, Str] {
  let c := ctx.from_request({ method: "GET", path: "/", body: "", query: "", headers: map.new() }, map.new())
  match depends.cached_str(c, "missing", fallback_computed) {
    Ok(v) => if v == "computed" {
      Ok(())
    } else {
      Err(str.concat("got: ", v))
    },
    Err(_) => Err("fallback errored"),
  }
}

# cached_str does NOT write the fallback's result to state — Lex
# Ctx is immutable from the dep's perspective. A second call with
# the same name still hits the fallback (no auto-write-back).
fn cached_str_does_not_write_back_to_state() -> Result[Unit, Str] {
  let c := ctx.from_request({ method: "GET", path: "/", body: "", query: "", headers: map.new() }, map.new())
  let _first := depends.cached_str(c, "k", fallback_computed)
  match ctx.get_state(c, "k") {
    None => Ok(()),
    Some(_) => Err("cached_str unexpectedly wrote to state"),
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> List[Result[Unit, Str]] {
  [test_inject1_ok(), test_inject1_short_circuits(), test_inject2_ok(), test_inject2_first_fails(), test_bind_chains(), test_map_passes_err(), test_pure_lifts(), cached_str_hits_state_when_present(), cached_str_runs_fallback_on_miss(), cached_str_does_not_write_back_to_state()]
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

