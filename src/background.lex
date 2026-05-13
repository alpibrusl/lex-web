# lex-web — background tasks
#
# FastAPI lets a handler attach a callable + args to a `BackgroundTasks`
# object; the framework then runs them after the response is sent. We
# model the same pattern with a `BackgroundTask` value (closure + name)
# and a `Reply = (Response, List[BackgroundTask])` shape that handlers
# can return through `dispatch_with_bg`.
#
# Plain `dispatch` is unchanged — handlers that don't need background
# tasks keep their `(Ctx) -> Response` signature. Handlers that *do*
# return a `Reply`, and the caller threads tasks through:
#
#   fn send_welcome(c :: ctx.Ctx) -> background.Reply {
#     let r := resp.created_json("{\"ok\":true}", "/users/42")
#     background.with_task(r,
#       background.task("welcome-email",
#         fn () -> [io, time] Nil { io.print("sent welcome email") }))
#   }
#
#   fn handle(req :: ctx.RawRequest) -> [io, time] resp.Response {
#     match send_welcome(ctx.from_request(req, map.new())) {
#       reply => {
#         let _ := background.run_all(reply.tasks)
#         reply.response
#       }
#     }
#   }
#
# Effects: `task` and `with_task` are pure. `run_all` and `run_one`
# carry [io, time] because tasks usually do.

import "std.list" as list

import "./response" as resp

type BackgroundTask = {
  name :: Str,
  run  :: () -> [io, time] Nil,
}

# Response + queued tasks, returned by background-aware handlers.
type Reply = {
  response :: resp.Response,
  tasks    :: List[BackgroundTask],
}

# ---- Construction ------------------------------------------------

fn task(name :: Str, fn_body :: () -> [io, time] Nil) -> BackgroundTask {
  { name: name, run: fn_body }
}

# Wrap a Response in an empty Reply.
fn from_response(r :: resp.Response) -> Reply {
  { response: r, tasks: [] }
}

# Append a task to an existing Reply (or build one from a Response).
fn with_task(r :: resp.Response, t :: BackgroundTask) -> Reply {
  { response: r, tasks: [t] }
}

fn add_task(reply :: Reply, t :: BackgroundTask) -> Reply {
  { response: reply.response, tasks: list.concat(reply.tasks, [t]) }
}

fn add_tasks(reply :: Reply, ts :: List[BackgroundTask]) -> Reply {
  { response: reply.response, tasks: list.concat(reply.tasks, ts) }
}

# ---- Execution ---------------------------------------------------

# Run a single task. Used by run_all; exposed for callers that want
# to drive tasks from a thread pool / dedicated runtime.
fn run_one(t :: BackgroundTask) -> [io, time] Nil { t.run() }

# Run every queued task in registration order. Failures propagate
# (the runtime decides whether to abort the loop).
fn run_all(tasks :: List[BackgroundTask]) -> [io, time] Nil {
  list.fold(tasks, (),
    fn (_acc :: Nil, t :: BackgroundTask) -> [io, time] Nil { t.run() })
}

# Number of pending tasks — useful in tests and metrics.
fn pending(reply :: Reply) -> Int { list.len(reply.tasks) }
