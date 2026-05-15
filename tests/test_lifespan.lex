# Tests for src/lifespan.lex — startup / shutdown hooks.

import "std.list" as list

import "../src/lifespan" as lifespan

fn noop() -> [io, time] Nil { () }

fn test_empty_lifespan() -> Result[Unit, Str] {
  let l := lifespan.new()
  if lifespan.startup_count(l) == 0
     and lifespan.shutdown_count(l) == 0 { Ok(()) }
  else { Err("new lifespan should be empty") }
}

fn test_register_startup() -> Result[Unit, Str] {
  let l := lifespan.on_startup(lifespan.new(), noop)
  let l2 := lifespan.on_startup(l, noop)
  if lifespan.startup_count(l2) == 2 { Ok(()) }
  else { Err("startup_count wrong") }
}

fn test_register_shutdown() -> Result[Unit, Str] {
  let l := lifespan.on_shutdown(lifespan.new(), noop)
  if lifespan.shutdown_count(l) == 1 { Ok(()) }
  else { Err("shutdown_count wrong") }
}

fn test_independent_counts() -> Result[Unit, Str] {
  let l := lifespan.new()
            |> fn (x :: lifespan.Lifespan) -> lifespan.Lifespan {
                 lifespan.on_startup(x, noop)
               }
            |> fn (x :: lifespan.Lifespan) -> lifespan.Lifespan {
                 lifespan.on_shutdown(x, noop)
               }
            |> fn (x :: lifespan.Lifespan) -> lifespan.Lifespan {
                 lifespan.on_shutdown(x, noop)
               }
  if lifespan.startup_count(l) == 1
     and lifespan.shutdown_count(l) == 2 { Ok(()) }
  else { Err("startup/shutdown counts independent") }
}

fn suite() -> List[Result[Unit, Str]] {
  [
    test_empty_lifespan(),
    test_register_startup(),
    test_register_shutdown(),
    test_independent_counts(),
  ]
}

fn run_all() -> () {
  assert list.fold(suite(), 0,
    fn (n :: Int, r :: Result[Unit, Str]) -> Int {
      match r { Ok(_) => n, Err(_) => n + 1 }
    }) == 0
}
