# lex-web — exception handlers
#
# FastAPI lets the application register `@app.exception_handler(SomeExc)`
# functions. Lex doesn't have exceptions, but the same intent — "map a
# typed error value to a Response" — is just as useful for handling
# domain errors (NotFound, Conflict, …).
#
# ExceptionRegistry is a list of (matcher, handler) pairs the caller
# walks via `handle_or_default`. Each matcher inspects a typed error
# `AppError` value (a user-defined ADT) and returns Some(Response) if
# it knows how to render it. The first matcher that returns Some wins.
#
# Usage:
#
#   type AppError = NotFound(Str) | Conflict(Str) | RateLimited(Int)
#
#   fn registry() -> exceptions.Registry[AppError] {
#     exceptions.new()
#       |> fn (r :: exceptions.Registry[AppError]) -> exceptions.Registry[AppError] {
#            exceptions.add(r,
#              fn (e :: AppError) -> Option[resp.Response] {
#                match e {
#                  NotFound(what) =>
#                    Some(resp.json_status(404,
#                       str.concat("{\"error\":\"not found\",\"what\":\"",
#                                  str.concat(what, "\"}")))),
#                  _ => None,
#                }
#              })
#          }
#   }
#
# Effects: none.

import "std.list" as list

import "./response" as resp

# A Matcher inspects an AppError and returns Some(Response) when it
# recognises it; None lets the next matcher try.
#
#   type Matcher[E] = (E) -> Option[resp.Response]

type Registry[E] = {
  matchers :: List[(E) -> Option[resp.Response]],
  fallback :: (E) -> resp.Response,
}

# ---- Construction ------------------------------------------------

fn new[E]() -> Registry[E] {
  { matchers: [], fallback: default_fallback }
}

fn with_fallback[E](
  r        :: Registry[E],
  fallback :: (E) -> resp.Response
) -> Registry[E] {
  { matchers: r.matchers, fallback: fallback }
}

fn add[E](
  r       :: Registry[E],
  matcher :: (E) -> Option[resp.Response]
) -> Registry[E] {
  { matchers: list.concat(r.matchers, [matcher]), fallback: r.fallback }
}

# ---- Resolution --------------------------------------------------

# Walk the matchers in registration order; return the first hit, or
# the registry's fallback for unknown errors.
fn handle[E](r :: Registry[E], err :: E) -> resp.Response {
  let attempt := list.fold(r.matchers, None,
    fn (acc :: Option[resp.Response], m :: (E) -> Option[resp.Response]) -> Option[resp.Response] {
      match acc {
        Some(_) => acc,
        None    => m(err),
      }
    })
  match attempt {
    Some(resp_) => resp_,
    None        => r.fallback(err),
  }
}

# Convenience: turn a Result into a Response by handing the Err to
# the registry. The Ok value is mapped through `to_response` (often
# `resp.json` composed with stringification).
fn handle_result[E, T](
  r           :: Registry[E],
  result      :: Result[T, E],
  to_response :: (T) -> resp.Response
) -> resp.Response {
  match result {
    Ok(v)   => to_response(v),
    Err(e)  => handle(r, e),
  }
}

fn default_fallback[E](_e :: E) -> resp.Response {
  resp.internal_error()
}
