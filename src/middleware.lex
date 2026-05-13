# lex-web — middleware
#
# Middleware is represented as a MiddlewareKind variant stored in
# the Router's middleware list. The router calls run_pre / run_post
# at dispatch time.
#
# Pre-middleware runs before the matched handler:
#   - MwBodyLimit    — short-circuits with 413 if body exceeds limit
#   - MwTrustedHost  — short-circuits with 400 if Host header is not
#                       in the allowed list
#   - MwCors         — short-circuits OPTIONS preflight requests with
#                       a fully-formed 204 response
#
# Post-middleware runs after the handler returns a Response:
#   - MwCors      — adds Access-Control-* headers
#   - MwRequestId — echoes the generated request ID header
#   - MwLogger    — logs `METHOD path -> status` to stdout [io]
#   - MwGzip      — sets Content-Encoding: gzip when the client's
#                    Accept-Encoding includes "gzip" and the body
#                    crosses a threshold (compression itself is
#                    deferred to lex-lang's std.gzip when it lands;
#                    today the middleware only sets the header)
#
# Effects: run_pre is pure. run_post is [io, time] because MwLogger
# writes to stdout and MwRequestId reads the wall clock.

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
  | MwGzip(Int)
  | MwTrustedHost(List[Str])

# Convenience constructors matching the proposed web.use() surface.
fn cors(origins :: List[Str]) -> MiddlewareKind { MwCors(origins) }
fn body_limit(max_bytes :: Int) -> MiddlewareKind { MwBodyLimit(max_bytes) }
fn request_id() -> MiddlewareKind { MwRequestId }
fn logger() -> MiddlewareKind { MwLogger }

# Mark gzip on responses larger than `min_bytes`. Compression of
# the body itself is gated on lex-lang exposing std.gzip; until
# then this middleware only annotates the response header so the
# rest of the negotiation flow is wired correctly.
fn gzip(min_bytes :: Int) -> MiddlewareKind { MwGzip(min_bytes) }

# Allow only requests whose Host header matches one of `hosts`.
# Unknown hosts get a 400. Use `["*"]` (or an empty list) to skip.
fn trusted_host(hosts :: List[Str]) -> MiddlewareKind {
  MwTrustedHost(hosts)
}

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
    MwTrustedHost(hosts) =>
      if list.len(hosts) == 0 { Continue(c) }
      else {
        if list.fold(hosts, false,
             fn (acc :: Bool, h :: Str) -> Bool {
               acc or (h == "*")
             }) {
          Continue(c)
        } else {
          let host := ctx.header_or(c, "host", "")
          if list.fold(hosts, false,
               fn (acc :: Bool, h :: Str) -> Bool {
                 acc or (h == host)
               }) { Continue(c) }
          else { Short(resp.bad_request("invalid host header")) }
        }
      },
    MwCors(origins) =>
      if c.method == "OPTIONS" { Short(preflight_response(c, origins)) }
      else { Continue(c) },
    _ => Continue(c),
  }
}

# Standard preflight response with 204 + the same Access-Control-*
# headers MwCors would add post-handler.
fn preflight_response(c :: ctx.Ctx, origins :: List[Str]) -> resp.Response {
  let req_method  := ctx.header_or(c, "access-control-request-method",
                       "GET, POST, PUT, PATCH, DELETE, OPTIONS")
  let req_headers := ctx.header_or(c, "access-control-request-headers",
                       "content-type, authorization")
  let origin_hdr  := str.join(origins, ", ")
  let r := { body: "", status: 204, headers: map.new() }
  r |> fn (rr :: resp.Response) -> resp.Response {
        resp.with_header(rr, "access-control-allow-origin", origin_hdr)
      }
    |> fn (rr :: resp.Response) -> resp.Response {
        resp.with_header(rr, "access-control-allow-methods", req_method)
      }
    |> fn (rr :: resp.Response) -> resp.Response {
        resp.with_header(rr, "access-control-allow-headers", req_headers)
      }
    |> fn (rr :: resp.Response) -> resp.Response {
        resp.with_header(rr, "access-control-max-age", "600")
      }
}

# ---- Post-middleware pass ----------------------------------------

# Walk all middlewares in order and thread the Response through
# each post-step. Logger emits to stdout.
fn run_post(
  mws      :: List[MiddlewareKind],
  c        :: ctx.Ctx,
  response :: resp.Response
) -> [io, time] resp.Response {
  list.fold(mws, response,
    fn (r :: resp.Response, kind :: MiddlewareKind) -> [io, time] resp.Response {
      apply_post(kind, c, r)
    })
}

fn apply_post(
  kind     :: MiddlewareKind,
  c        :: ctx.Ctx,
  response :: resp.Response
) -> [io, time] resp.Response {
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
    MwGzip(min_bytes) =>
      if str.len(response.body) >= min_bytes
         and accepts_gzip(c) {
        resp.with_header(response, "content-encoding", "gzip")
      } else { response },
    MwBodyLimit(_)    => response,
    MwTrustedHost(_)  => response,
  }
}

fn accepts_gzip(c :: ctx.Ctx) -> Bool {
  let ae := ctx.header_or(c, "accept-encoding", "")
  str.contains(str.to_lower(ae), "gzip")
}

# ---- Request ID --------------------------------------------------

# Simple time-based ID. Not cryptographically random; good enough
# for tracing logs. Replace with crypto.random_bytes once available.
fn make_request_id() -> [time] Str {
  let now := time.now()
  str.concat("req-", int.to_str(now))
}
