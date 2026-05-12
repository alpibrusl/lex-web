# lex-web — middleware
#
# Middleware is represented as a MiddlewareKind variant stored in
# the Router's middleware list. The router calls run_pre / run_post
# at dispatch time.
#
# Pre-middleware runs before the matched handler:
#   - MwBodyLimit — short-circuits with 413 if body exceeds limit
#
# Post-middleware runs after the handler returns a Response:
#   - MwCors      — adds Access-Control-* headers
#   - MwRequestId — echoes the generated request ID header
#   - MwLogger    — logs `METHOD path -> status` to stdout [io]
#
# Effects: run_pre is pure. run_post is [io] because MwLogger
# writes to stdout. Stacks without MwLogger will still compile
# as [io]; a future version will split the effect once higher-kinded
# middleware types are well-supported in lex-lang.

import "std.str"  as str
import "std.int"  as int
import "std.list" as list
import "std.map"  as map
import "std.io"   as io
import "std.time" as time

import "./ctx"      as ctx
import "./response" as resp

# ---- Middleware kind ---------------------------------------------

type MiddlewareKind =
    MwCors(List[Str])
  | MwBodyLimit(Int)
  | MwRequestId
  | MwLogger

# Convenience constructors matching the proposed web.use() surface.
fn cors(origins :: List[Str]) -> MiddlewareKind { MwCors(origins) }
fn body_limit(max_bytes :: Int) -> MiddlewareKind { MwBodyLimit(max_bytes) }
fn request_id() -> MiddlewareKind { MwRequestId }
fn logger() -> MiddlewareKind { MwLogger }

# ---- Pre-middleware result ----------------------------------------

# Short means stop immediately and return the given response.
# Continue means pass the (possibly modified) Ctx to the handler.
type PreResult =
    Short(resp.Response)
  | Continue(ctx.Ctx)

# ---- Pre-middleware pass -----------------------------------------

# Walk all middlewares; stop at the first Short result.
fn run_pre(
  mws :: List[MiddlewareKind],
  c   :: ctx.Ctx
) -> PreResult {
  list.fold(mws, Continue(c),
    fn (acc :: PreResult, kind :: MiddlewareKind) -> PreResult {
      match acc {
        Short(_)     => acc,
        Continue(c2) => apply_pre(kind, c2),
      }
    })
}

fn apply_pre(
  kind :: MiddlewareKind,
  c    :: ctx.Ctx
) -> PreResult {
  match kind {
    MwBodyLimit(max) =>
      if str.len(c.body) > max { Short(resp.payload_too_large()) }
      else { Continue(c) },
    _ => Continue(c),
  }
}

# ---- Post-middleware pass ----------------------------------------

# Walk all middlewares in order and thread the Response through
# each post-step. Logger emits to stdout.
fn run_post(
  mws      :: List[MiddlewareKind],
  c        :: ctx.Ctx,
  response :: resp.Response
) -> [io] resp.Response {
  list.fold(mws, response,
    fn (r :: resp.Response, kind :: MiddlewareKind) -> [io] resp.Response {
      apply_post(kind, c, r)
    })
}

fn apply_post(
  kind     :: MiddlewareKind,
  c        :: ctx.Ctx,
  response :: resp.Response
) -> [io] resp.Response {
  match kind {
    MwCors(origins) => {
      let origin_hdr := str.join(origins, ", ")
      response
        |> fn (r :: resp.Response) -> resp.Response {
             resp.with_header(r, "access-control-allow-origin", origin_hdr)
           }
        |> fn (r :: resp.Response) -> resp.Response {
             resp.with_header(r, "access-control-allow-methods",
               "GET, POST, PUT, PATCH, DELETE, OPTIONS")
           }
        |> fn (r :: resp.Response) -> resp.Response {
             resp.with_header(r, "access-control-allow-headers",
               "content-type, authorization")
           }
    },
    MwRequestId => {
      let rid := make_request_id()
      resp.with_header(response, "x-request-id", rid)
    },
    MwLogger => {
      let line := str.concat(c.method,
                   str.concat(" ",
                     str.concat(c.path,
                       str.concat(" -> ",
                         int.to_str(response.status)))))
      let _ := io.print(line)
      response
    },
    MwBodyLimit(_) => response,
  }
}

# ---- Request ID --------------------------------------------------

# Simple time-based ID. Not cryptographically random; good enough
# for tracing logs. Replace with crypto.random_bytes once available.
fn make_request_id() -> [io] Str {
  let now := time.now()
  str.concat("req-", int.to_str(now))
}
