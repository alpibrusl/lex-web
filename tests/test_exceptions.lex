# Tests for src/exceptions.lex — typed-error registry.

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/response" as resp

import "../src/exceptions" as ex

type AppError = NotFound(Str) | Conflict(Str) | RateLimited

fn match_not_found(e :: AppError) -> Option[resp.Response] {
  match e {
    NotFound(what) => Some(resp.json_status(404, str.concat("{\"error\":\"not found\",\"what\":\"", str.concat(what, "\"}")))),
    _ => None,
  }
}

fn match_conflict(e :: AppError) -> Option[resp.Response] {
  match e {
    Conflict(what) => Some(resp.json_status(409, str.concat("{\"error\":\"conflict\",\"what\":\"", str.concat(what, "\"}")))),
    _ => None,
  }
}

fn registry() -> { matchers :: List[(AppError) -> Option[resp.Response]], fallback :: (AppError) -> resp.Response } {
  (ex.new() |> fn (r :: { matchers :: List[(AppError) -> Option[resp.Response]], fallback :: (AppError) -> resp.Response }) -> { matchers :: List[(AppError) -> Option[resp.Response]], fallback :: (AppError) -> resp.Response } {
    ex.add(r, match_not_found)
  }) |> fn (r :: { matchers :: List[(AppError) -> Option[resp.Response]], fallback :: (AppError) -> resp.Response }) -> { matchers :: List[(AppError) -> Option[resp.Response]], fallback :: (AppError) -> resp.Response } {
    ex.add(r, match_conflict)
  }
}

fn test_first_matcher_wins() -> Result[Unit, Str] {
  let r := ex.handle(registry(), NotFound("user"))
  if r.status == 404 and str.contains(r.body, "user") {
    Ok(())
  } else {
    Err("not_found matcher missed")
  }
}

fn test_second_matcher() -> Result[Unit, Str] {
  let r := ex.handle(registry(), Conflict("name taken"))
  if r.status == 409 and str.contains(r.body, "name taken") {
    Ok(())
  } else {
    Err("conflict matcher missed")
  }
}

fn test_default_fallback_500() -> Result[Unit, Str] {
  let r := ex.handle(registry(), RateLimited)
  if r.status == 500 {
    Ok(())
  } else {
    Err("expected default 500 fallback")
  }
}

fn test_custom_fallback() -> Result[Unit, Str] {
  let reg := ex.with_fallback(registry(), fn (_e :: AppError) -> resp.Response {
    resp.json_status(503, "{}")
  })
  let r := ex.handle(reg, RateLimited)
  if r.status == 503 {
    Ok(())
  } else {
    Err("custom fallback ignored")
  }
}

fn test_handle_result_ok() -> Result[Unit, Str] {
  let r := ex.handle_result(registry(), Ok(7), fn (n :: Int) -> resp.Response {
    resp.text(int.to_str(n))
  })
  if r.status == 200 and r.body == "7" {
    Ok(())
  } else {
    Err("handle_result ok branch wrong")
  }
}

fn test_handle_result_err() -> Result[Unit, Str] {
  let r := ex.handle_result(registry(), Err(NotFound("post")), fn (_v :: Int) -> resp.Response {
    resp.text("unreached")
  })
  if r.status == 404 {
    Ok(())
  } else {
    Err("handle_result err branch wrong")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_first_matcher_wins(), test_second_matcher(), test_default_fallback_500(), test_custom_fallback(), test_handle_result_ok(), test_handle_result_err()]
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

