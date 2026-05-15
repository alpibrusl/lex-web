# Tests for src/depends.lex — Dep[T] composition + inject helpers.

import "std.list" as list
import "std.map"  as map
import "std.int"  as int
import "std.str"  as str

import "../src/ctx"      as ctx
import "../src/response" as resp
import "../src/depends"  as depends
import "../src/testing"  as t

# ---- Test deps ---------------------------------------------------

fn dep_const_int(_c :: ctx.Ctx) -> Result[Int, resp.Response] { Ok(7) }

fn dep_const_str(_c :: ctx.Ctx) -> Result[Str, resp.Response] { Ok("hi") }

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
  if r.status == 200 and r.body == "7" { Ok(()) }
  else { Err("inject1 ok body wrong") }
}

fn test_inject1_short_circuits() -> Result[Unit, Str] {
  let c := ctx.from_request(t.get("/"), map.new())
  let r := depends.inject1(c, dep_fail, handler1)
  if r.status == 401 { Ok(()) } else { Err("expected 401") }
}

# ---- inject2 -----------------------------------------------------

fn test_inject2_ok() -> Result[Unit, Str] {
  let c := ctx.from_request(t.get("/"), map.new())
  let r := depends.inject2(c, dep_const_int, dep_const_str, handler2)
  if r.status == 200 and r.body == "hi:7" { Ok(()) }
  else { Err("inject2 ok body wrong") }
}

fn test_inject2_first_fails() -> Result[Unit, Str] {
  let c := ctx.from_request(t.get("/"), map.new())
  let r := depends.inject2(c, dep_fail, dep_const_str,
    fn (_cc :: ctx.Ctx, _n :: Int, _s :: Str) -> resp.Response {
      resp.text("unreached")
    })
  if r.status == 401 { Ok(()) } else { Err("expected 401") }
}

# ---- bind / map / pure -------------------------------------------

fn test_bind_chains() -> Result[Unit, Str] {
  let r := depends.bind(Ok(3),
    fn (n :: Int) -> Result[Int, resp.Response] { Ok(n + 1) })
  match r {
    Ok(4) => Ok(()),
    _     => Err("bind chain wrong"),
  }
}

fn test_map_passes_err() -> Result[Unit, Str] {
  let r := depends.map(Err(resp.unauthorized("x")),
    fn (n :: Int) -> Int { n + 1 })
  match r {
    Err(_) => Ok(()),
    Ok(_)  => Err("expected err"),
  }
}

fn test_pure_lifts() -> Result[Unit, Str] {
  match depends.pure(99) {
    Ok(99) => Ok(()),
    _      => Err("pure broken"),
  }
}

# ---- Suite -------------------------------------------------------

fn suite() -> List[Result[Unit, Str]] {
  [
    test_inject1_ok(),
    test_inject1_short_circuits(),
    test_inject2_ok(),
    test_inject2_first_fails(),
    test_bind_chains(),
    test_map_passes_err(),
    test_pure_lifts(),
  ]
}

fn run_all() -> () {
  assert list.fold(suite(), 0,
    fn (n :: Int, r :: Result[Unit, Str]) -> Int {
      match r { Ok(_) => n, Err(_) => n + 1 }
    }) == 0
}
