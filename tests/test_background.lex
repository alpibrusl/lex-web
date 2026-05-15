# Tests for src/background.lex — background task queue.
# Pure tests only: we exercise the data-flow shape, not the
# effectful run_all (which would require [io,time] in the test
# runner).

import "std.list" as list

import "../src/response"   as resp
import "../src/background" as bg

fn noop() -> [io, time] Nil { () }

fn test_from_response_empty() -> Result[Unit, Str] {
  let reply := bg.from_response(resp.text("hi"))
  if bg.pending(reply) == 0
     and reply.response.status == 200 { Ok(()) }
  else { Err("from_response not empty") }
}

fn test_with_task_appends_one() -> Result[Unit, Str] {
  let reply := bg.with_task(resp.text("ok"), bg.task("t1", noop))
  if bg.pending(reply) == 1
     and reply.response.body == "ok" { Ok(()) }
  else { Err("with_task did not append") }
}

fn test_add_task_chains() -> Result[Unit, Str] {
  let r0 := bg.from_response(resp.no_content())
  let r1 := bg.add_task(r0, bg.task("t1", noop))
  let r2 := bg.add_task(r1, bg.task("t2", noop))
  if bg.pending(r2) == 2
     and r2.response.status == 204 { Ok(()) }
  else { Err("add_task chain wrong") }
}

fn test_add_tasks_bulk() -> Result[Unit, Str] {
  let r := bg.add_tasks(bg.from_response(resp.text("x")),
    [bg.task("a", noop), bg.task("b", noop), bg.task("c", noop)])
  if bg.pending(r) == 3 { Ok(()) }
  else { Err("add_tasks bulk wrong") }
}

fn test_task_name_preserved() -> Result[Unit, Str] {
  let tk := bg.task("welcome-email", noop)
  if tk.name == "welcome-email" { Ok(()) }
  else { Err("task name lost") }
}

fn suite() -> List[Result[Unit, Str]] {
  [
    test_from_response_empty(),
    test_with_task_appends_one(),
    test_add_task_chains(),
    test_add_tasks_bulk(),
    test_task_name_preserved(),
  ]
}

fn run_all() -> () {
  assert list.fold(suite(), 0,
    fn (n :: Int, r :: Result[Unit, Str]) -> Int {
      match r { Ok(_) => n, Err(_) => n + 1 }
    }) == 0
}
