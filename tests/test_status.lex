# Tests for src/status.lex — HTTP status constants and predicates.

import "std.list" as list

import "../src/status" as status

fn test_2xx_constants() -> Result[Unit, Str] {
  if status.HTTP_200_OK() == 200
     and status.HTTP_201_CREATED() == 201
     and status.HTTP_204_NO_CONTENT() == 204 { Ok(()) }
  else { Err("2xx constants wrong") }
}

fn test_4xx_constants() -> Result[Unit, Str] {
  if status.HTTP_404_NOT_FOUND() == 404
     and status.HTTP_422_UNPROCESSABLE_ENTITY() == 422
     and status.HTTP_429_TOO_MANY_REQUESTS() == 429 { Ok(()) }
  else { Err("4xx constants wrong") }
}

fn test_predicates_success() -> Result[Unit, Str] {
  if status.is_success(200) and status.is_success(299)
     and not status.is_success(199)
     and not status.is_success(300) { Ok(()) }
  else { Err("is_success boundary wrong") }
}

fn test_predicates_error() -> Result[Unit, Str] {
  if status.is_client_error(404) and status.is_server_error(500)
     and status.is_error(404) and status.is_error(500)
     and not status.is_error(200) { Ok(()) }
  else { Err("error predicates wrong") }
}

fn test_predicates_redirect() -> Result[Unit, Str] {
  if status.is_redirect(301) and status.is_redirect(308)
     and not status.is_redirect(299)
     and not status.is_redirect(400) { Ok(()) }
  else { Err("is_redirect boundary wrong") }
}

fn suite() -> List[Result[Unit, Str]] {
  [
    test_2xx_constants(),
    test_4xx_constants(),
    test_predicates_success(),
    test_predicates_error(),
    test_predicates_redirect(),
  ]
}

fn run_all() -> () {
  assert list.fold(suite(), 0,
    fn (n :: Int, r :: Result[Unit, Str]) -> Int {
      match r { Ok(_) => n, Err(_) => n + 1 }
    }) == 0
}
