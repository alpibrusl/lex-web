# lex-web — startup / shutdown hooks
#
# FastAPI exposes a `lifespan` context manager and the older
# `@app.on_event("startup")` / `@app.on_event("shutdown")` decorators.
# In Lex we model both with two ordered lists of nullary thunks; each
# thunk runs under the effects it declares.
#
# Wire it into your `main`:
#
#   fn ls() -> lifespan.Lifespan {
#     lifespan.new()
#       |> fn (l :: lifespan.Lifespan) -> lifespan.Lifespan {
#            lifespan.on_startup(l, fn () -> [io] Nil { io.print("ready") })
#          }
#       |> fn (l :: lifespan.Lifespan) -> lifespan.Lifespan {
#            lifespan.on_shutdown(l, fn () -> [io] Nil { io.print("bye") })
#          }
#   }
#
#   fn main() -> [net, io, time] Nil {
#     let _ := lifespan.run_startup(ls())
#     net.serve_fn(8080, handle)
#     # net.serve_fn doesn't currently return — shutdown hooks are
#     # for graceful-stop runtimes once lex-lang exposes a signal API.
#   }
#
# Effects: lifespan.run_startup / run_shutdown carry [io, time]
# because user thunks usually do (DB connect, file read, log line).

import "std.list" as list

# A single hook is a parameterless `() -> [io, time] Nil` function.
# We don't name this via `type Hook = ...` because lex 0.9.4 doesn't
# auto-call through type aliases on function types (`expected:
# function, got: Hook`), so the alias would force the call sites to
# either unwrap explicitly or stay structural. We inline the function
# type everywhere instead — a few extra characters but no aliasing
# trap.
type Lifespan = { startup :: List[() -> [io, time] Nil], shutdown :: List[() -> [io, time] Nil] }

# ---- Construction ------------------------------------------------
fn new() -> Lifespan {
  { startup: [], shutdown: [] }
}

fn on_startup(l :: Lifespan, hook :: () -> [io, time] Nil) -> Lifespan {
  { startup: list.concat(l.startup, [hook]), shutdown: l.shutdown }
}

fn on_shutdown(l :: Lifespan, hook :: () -> [io, time] Nil) -> Lifespan {
  { startup: l.startup, shutdown: list.concat(l.shutdown, [hook]) }
}

# ---- Execution ---------------------------------------------------
# Run startup hooks in registration order. Returns Nil; if a hook
# panics, the runtime stops.
fn run_startup(l :: Lifespan) -> [io, time] Nil {
  list.fold(l.startup, (), fn (_acc :: Nil, h :: () -> [io, time] Nil) -> [io, time] Nil {
    h()
  })
}

# Run shutdown hooks in registration order.
fn run_shutdown(l :: Lifespan) -> [io, time] Nil {
  list.fold(l.shutdown, (), fn (_acc :: Nil, h :: () -> [io, time] Nil) -> [io, time] Nil {
    h()
  })
}

# ---- Counts (helpful for tests / debug) --------------------------
fn startup_count(l :: Lifespan) -> Int {
  list.len(l.startup)
}

fn shutdown_count(l :: Lifespan) -> Int {
  list.len(l.shutdown)
}

