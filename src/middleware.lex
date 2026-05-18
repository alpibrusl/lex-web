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
#   - MwCustom       — user-defined hooks (#27)
#
# Post-middleware runs after the handler returns a Response:
#   - MwCors      — adds Access-Control-* headers
#   - MwRequestId — attaches a cryptographically random request ID
#                    (x-request-id header). Requires [crypto, random] effect.
#   - MwLogger    — logs `[timestamp] METHOD path -> status` [io, time]
#   - MwGzip      — sets Content-Encoding: gzip when the client
#                    accepts gzip and the body crosses a threshold
#                    (actual compression deferred to std.gzip landing)
#   - MwCustom    — user-defined hooks (#27)
#
# Effects:
#   run_pre / run_post — [io, time, crypto, random, sql, fs_read,
#                         fs_write, net, concurrent] (HEff effect row)
#                         — widened so user MwCustom hooks can do
#                         I/O, talk to a DB, drive an actor, etc.
#                         The built-in variants emit narrower effects
#                         but sign the wider contract.
#   apply_pre  — pure (built-in variants only; MwCustom dispatched
#                 directly inside run_pre, not via apply_pre)
#   apply_post — [io, time, crypto, random] (built-in variants only)

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.map" as map

import "std.io" as io

import "std.time" as time

import "std.crypto" as crypto

import "./ctx" as ctx

import "./response" as resp

# ---- Pre-middleware result ----------------------------------------
# Short means stop immediately and return the given response.
# Continue means pass the (possibly modified) Ctx to the handler.
# Declared above MiddlewareKind so MwCustom's closure types can
# reference it.
type PreResult = Short(resp.Response) | Continue(ctx.Ctx)

type CustomMw = { name :: Str, before :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] PreResult, after :: (ctx.Ctx, resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response }

type MiddlewareKind = MwCors(List[Str]) | MwBodyLimit(Int) | MwRequestId | MwLogger | MwGzip(Int) | MwTrustedHost(List[Str]) | MwCustom(CustomMw)

fn cors(origins :: List[Str]) -> MiddlewareKind {
  MwCors(origins)
}

fn body_limit(max_bytes :: Int) -> MiddlewareKind {
  MwBodyLimit(max_bytes)
}

fn request_id() -> MiddlewareKind {
  MwRequestId
}

fn logger() -> MiddlewareKind {
  MwLogger
}

# Mark gzip on responses larger than `min_bytes`. Compression of
# the body itself is gated on lex-lang exposing std.gzip; until
# then this middleware only annotates the response header so the
# rest of the negotiation flow is wired correctly.
fn gzip(min_bytes :: Int) -> MiddlewareKind {
  MwGzip(min_bytes)
}

# Allow only requests whose Host header matches one of `hosts`.
# Unknown hosts get a 400. Use `["*"]` (or an empty list) to skip.
fn trusted_host(hosts :: List[Str]) -> MiddlewareKind {
  MwTrustedHost(hosts)
}

# User-defined middleware (#27). `name` shows up in trace output;
# `before` is the pre-handler hook and `after` is the post-handler
# hook. Both sign the HEff effect row so they can do real work
# (logging, DB lookups, rate-limit state via a `conc` actor, etc.).
# A do-nothing before is `fn (c :: ctx.Ctx) -> [HEff] PreResult { Continue(c) }`;
# a do-nothing after is `fn (_c, r) -> [HEff] resp.Response { r }`.
fn custom(name :: Str, before :: (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] PreResult, after :: (ctx.Ctx, resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response) -> MiddlewareKind {
  MwCustom({ name: name, before: before, after: after })
}

# `run_pre` aggregates over the middleware stack. Built-in variants
# go through the pure `apply_pre`; MwCustom is dispatched directly
# here so its effectful `before` closure runs under the HEff effect
# row. Effect row widened from pure → HEff for the same reason.
fn run_pre(mws :: List[MiddlewareKind], c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] PreResult {
  list.fold(mws, Continue(c), fn (acc :: PreResult, kind :: MiddlewareKind) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] PreResult {
    match acc {
      Short(_) => acc,
      Continue(c2) => match kind {
        MwCustom(m) => m.before(c2),
        _ => apply_pre(kind, c2),
      },
    }
  })
}

# Pure dispatch for built-in middleware variants. MwCustom is
# reached only via run_pre's direct dispatch above — the arm here
# is a defensive no-op (Continue) in case anyone calls apply_pre
# with an MwCustom value out of band.
fn apply_pre(kind :: MiddlewareKind, c :: ctx.Ctx) -> PreResult {
  match kind {
    MwBodyLimit(max) => if str.len(c.body) > max {
      Short(resp.payload_too_large())
    } else {
      Continue(c)
    },
    MwTrustedHost(hosts) => if list.len(hosts) == 0 {
      Continue(c)
    } else {
      if list.fold(hosts, false, fn (acc :: Bool, h :: Str) -> Bool {
        acc or h == "*"
      }) {
        Continue(c)
      } else {
        let host := ctx.header_or(c, "host", "")
        if list.fold(hosts, false, fn (acc :: Bool, h :: Str) -> Bool {
          acc or h == host
        }) {
          Continue(c)
        } else {
          Short(resp.bad_request("invalid host header"))
        }
      }
    },
    MwCors(origins) => if c.method == "OPTIONS" {
      Short(preflight_response(c, origins))
    } else {
      Continue(c)
    },
    _ => Continue(c),
  }
}

# Standard preflight response with 204 + the same Access-Control-*
# headers MwCors would add post-handler.
fn preflight_response(c :: ctx.Ctx, origins :: List[Str]) -> resp.Response {
  let req_method := ctx.header_or(c, "access-control-request-method", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
  let req_headers := ctx.header_or(c, "access-control-request-headers", "content-type, authorization")
  let origin_hdr := str.join(origins, ", ")
  let r := { body: "", status: 204, headers: map.new() }
  (((r |> fn (rr :: resp.Response) -> resp.Response {
    resp.with_header(rr, "access-control-allow-origin", origin_hdr)
  }) |> fn (rr :: resp.Response) -> resp.Response {
    resp.with_header(rr, "access-control-allow-methods", req_method)
  }) |> fn (rr :: resp.Response) -> resp.Response {
    resp.with_header(rr, "access-control-allow-headers", req_headers)
  }) |> fn (rr :: resp.Response) -> resp.Response {
    resp.with_header(rr, "access-control-max-age", "600")
  }
}

# ---- Post-middleware pass ----------------------------------------
# Walk all middlewares in order and thread the Response through
# each post-step. Logger emits to stdout with a timestamp. Built-in
# variants go through `apply_post`; MwCustom is dispatched directly
# here so its effectful `after` closure runs under the HEff effect
# row. Effect row widened from [io, time, crypto, random] → HEff
# for the same reason.
fn run_post(mws :: List[MiddlewareKind], c :: ctx.Ctx, response :: resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  list.fold(mws, response, fn (r :: resp.Response, kind :: MiddlewareKind) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
    match kind {
      MwCustom(m) => m.after(c, r),
      _ => apply_post(kind, c, r),
    }
  })
}

# Dispatch for built-in middleware variants. MwCustom is reached
# only via run_post's direct dispatch above — the arm here is a
# defensive no-op (return response unchanged) in case anyone calls
# apply_post with an MwCustom value out of band.
fn apply_post(kind :: MiddlewareKind, c :: ctx.Ctx, response :: resp.Response) -> [io, time, crypto, random] resp.Response {
  match kind {
    MwCors(origins) => {
      let origin_hdr := str.join(origins, ", ")
      ((response |> fn (r :: resp.Response) -> resp.Response {
        resp.with_header(r, "access-control-allow-origin", origin_hdr)
      }) |> fn (r :: resp.Response) -> resp.Response {
        resp.with_header(r, "access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
      }) |> fn (r :: resp.Response) -> resp.Response {
        resp.with_header(r, "access-control-allow-headers", "content-type, authorization")
      }
    },
    MwRequestId => {
      let rid := make_request_id()
      resp.with_header(response, "x-request-id", rid)
    },
    MwLogger => {
      let ts := time.now_str()
      let line := str.concat(ts, str.concat(" ", str.concat(c.method, str.concat(" ", str.concat(c.path, str.concat(" -> ", int.to_str(response.status)))))))
      let __lex_discard_1 := io.print(line)
      response
    },
    MwGzip(min_bytes) => if str.len(response.body) >= min_bytes and accepts_gzip(c) {
      resp.with_header(response, "content-encoding", "gzip")
    } else {
      response
    },
    MwBodyLimit(_) => response,
    MwTrustedHost(_) => response,
    MwCustom(_) => response,
  }
}

fn accepts_gzip(c :: ctx.Ctx) -> Bool {
  let ae := ctx.header_or(c, "accept-encoding", "")
  str.contains(str.to_lower(ae), "gzip")
}

# ---- Request ID --------------------------------------------------
# Cryptographically random 16-byte ID (32 hex chars). Unlike a
# time-based ID this is collision-resistant and unpredictable,
# making it safe to expose in logs or response headers.
fn make_request_id() -> [crypto, random] Str {
  crypto.random_str_hex(16)
}

