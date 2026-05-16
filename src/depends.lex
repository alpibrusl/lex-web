# lex-web — dependency injection
#
# FastAPI's `Depends(...)` is just "call this function before the
# handler, propagate failures to the response, pass the result in".
# In Lex we model that as
#
#   type Dep[T] = (Ctx) -> Result[T, Response]
#
# so any function with that shape (e.g. `params.query_int`,
# `body.require_json_body`, a custom `current_user`) is a Dep.
# `chain2` … `chain5` then run a tuple of deps and call the handler
# with their materialised values, threading the first failure
# response back to the client.
#
# Because the dispatcher only sees `(Ctx) -> Response`, you wrap a
# dep-aware handler with `inject_*` to re-fit it into the router.
#
# Example:
#
#   fn current_user(c :: ctx.Ctx) -> Result[User, resp.Response] {
#     match params.bearer(c) {
#       Err(r)   => Err(r),
#       Ok(tok)  => lookup_user(tok),
#     }
#   }
#
#   fn list_items_h(c :: ctx.Ctx, user :: User, page :: Int) -> resp.Response {
#     resp.json(...)
#   }
#
#   fn list_items(c :: ctx.Ctx) -> resp.Response {
#     depends.inject2(c, current_user,
#       fn (cc :: ctx.Ctx) -> Result[Int, resp.Response] {
#         params.query_int(cc, "page", Some(1), [IntPositive])
#       },
#       list_items_h)
#   }
#
# Effects: none. Side-effecting deps declare their own effects in
# their function signature; the router propagates them through.

import "./ctx" as ctx

import "./response" as resp

# A Dep is exactly a function from Ctx to a Result. Aliased for docs.
# (Lex doesn't currently let us name function-typed aliases globally;
# this comment is the API contract.)
#
#   type Dep[T] = (ctx.Ctx) -> Result[T, resp.Response]
# ---- Single-dep helper -------------------------------------------
fn inject1[T](c :: ctx.Ctx, d1 :: (ctx.Ctx) -> Result[T, resp.Response], k :: (ctx.Ctx, T) -> resp.Response) -> resp.Response {
  match d1(c) {
    Err(r) => r,
    Ok(v) => k(c, v),
  }
}

# ---- Two-dep helper ----------------------------------------------
fn inject2[A, B](c :: ctx.Ctx, d1 :: (ctx.Ctx) -> Result[A, resp.Response], d2 :: (ctx.Ctx) -> Result[B, resp.Response], k :: (ctx.Ctx, A, B) -> resp.Response) -> resp.Response {
  match d1(c) {
    Err(r) => r,
    Ok(a) => match d2(c) {
      Err(r) => r,
      Ok(b) => k(c, a, b),
    },
  }
}

# ---- Three-dep helper --------------------------------------------
fn inject3[A, B, C](c :: ctx.Ctx, d1 :: (ctx.Ctx) -> Result[A, resp.Response], d2 :: (ctx.Ctx) -> Result[B, resp.Response], d3 :: (ctx.Ctx) -> Result[C, resp.Response], k :: (ctx.Ctx, A, B, C) -> resp.Response) -> resp.Response {
  match d1(c) {
    Err(r) => r,
    Ok(a) => match d2(c) {
      Err(r) => r,
      Ok(b) => match d3(c) {
        Err(r) => r,
        Ok(d) => k(c, a, b, d),
      },
    },
  }
}

# ---- Four-dep helper ---------------------------------------------
fn inject4[A, B, C, D](c :: ctx.Ctx, d1 :: (ctx.Ctx) -> Result[A, resp.Response], d2 :: (ctx.Ctx) -> Result[B, resp.Response], d3 :: (ctx.Ctx) -> Result[C, resp.Response], d4 :: (ctx.Ctx) -> Result[D, resp.Response], k :: (ctx.Ctx, A, B, C, D) -> resp.Response) -> resp.Response {
  match d1(c) {
    Err(r) => r,
    Ok(a) => match d2(c) {
      Err(r) => r,
      Ok(b) => match d3(c) {
        Err(r) => r,
        Ok(d) => match d4(c) {
          Err(r) => r,
          Ok(e) => k(c, a, b, d, e),
        },
      },
    },
  }
}

# ---- Sub-dep composition (Dep that depends on another Dep) -------
# Run d1; if it succeeds, hand its result to `mk` to build the next
# Dep, then run that. The classic use is "current_user requires the
# bearer token, then a DB lookup":
#
#   fn current_user(c :: ctx.Ctx) -> Result[User, resp.Response] {
#     depends.bind(params.bearer(c),
#       fn (tok :: Str) -> (ctx.Ctx) -> Result[User, resp.Response] {
#         fn (cc :: ctx.Ctx) -> Result[User, resp.Response] {
#           lookup_user(tok)
#         }
#       })
#       (c)   # apply the resulting Dep to ctx
#   }
fn bind[A, B](prev :: Result[A, resp.Response], mk :: (A) -> Result[B, resp.Response]) -> Result[B, resp.Response] {
  match prev {
    Err(r) => Err(r),
    Ok(a) => mk(a),
  }
}

# Lift any pure value into a Dep. Useful for composing with bind.
fn pure[T](v :: T) -> Result[T, resp.Response] {
  Ok(v)
}

# Map the value carried by a Dep result; failures pass through.
# Named `map_ok` (not `map`) to avoid shadowing the `map` stdlib
# module across the transitive type-check graph in lex 0.9.4 —
# a top-level `fn map` inside this file silently captured every
# `.get` / `.new` / `.from_list` lookup in modules that imported
# us, surfacing as a wall of cryptic field-access errors.
fn map_ok[A, B](prev :: Result[A, resp.Response], f :: (A) -> B) -> Result[B, resp.Response] {
  match prev {
    Err(r) => Err(r),
    Ok(a) => Ok(f(a)),
  }
}

