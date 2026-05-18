# lex-web — HTTP listener entry points
#
# Thin wrappers over the lex-lang `net.serve_*` builtins — the same
# shape as `ws.lex`'s `serve` (a passthrough that gives lex-web a
# coherent namespace for all transport entry points). Three variants
# mirror the lex-lang surface:
#
#   serve(port, handler)                — HTTP/1.1, wraps `net.serve_fn`
#   serve_with(port, handler, opts)     — HTTP/1.1 or 2, wraps `net.serve_fn_with` (#23)
#   serve_quic(port, tls, handler)      — HTTP/3 over QUIC, wraps `net.serve_quic_fn` (#24)
#
# Hand-roll the dispatch closure the same way the existing examples
# do; the router still owns request dispatch:
#
#   fn handle(req :: ctx.RawRequest) -> [io, time] resp.Response {
#     router.dispatch(app(), req)
#   }
#   fn main() -> [net, io, time] Nil {
#     let opts := { http2: true, inline_vm: false, host: "0.0.0.0" }
#     web_serve.serve_with(8080, handle, opts)
#   }
#
# `opts` is the lex-lang `ServeOpts` record literal:
#   { http2 :: Bool, inline_vm :: Bool, host :: Str }
#
# `tls` is built via `std.tls`:
#   tls.from_pem_files(cert_path, key_path)   — read a real cert
#   tls.self_signed(hostname)                 — dev/test only
#
# Why not auto-wrap `router.Router` -> handler? Lex's type-checker
# doesn't bridge `ctx.RawRequest` (lex-web's local record) with the
# global builtin `Request` type across closure-capture boundaries
# when the wrapping fn takes a Router param. The existing examples
# work around it by inlining the closure in `main`; this module
# follows the same convention — passes the handler through, doesn't
# build it.
#
# Requires lex-lang 0.9.6+ for serve_with / serve_quic. The base
# `serve` helper works on 0.9.0+.
#
# Effects:
#   serve       — [net, E]
#   serve_with  — [net, E]
#   serve_quic  — [net, E]
#
# `E` is the effect row the caller's handler emits — propagated
# back to the `main` site so the user's effect signature is honest
# about what the handlers can do.

import "std.net" as net

# HTTP/1.1 listener (no opts). Equivalent to `net.serve_fn` —
# included for namespace parity with `serve_with` and `serve_quic`.
fn serve[E](
  port    :: Int,
  handler :: (Request) -> [E] Response,
) -> [net, E] Nil {
  net.serve_fn(port, handler)
}

# HTTP/1.1 or HTTP/2 listener with explicit opts. Enables HTTP/2
# (`http2: true`), the inline-VM execution mode (`inline_vm: true`,
# faster for handlers that return in microseconds), or a custom
# bind host (`host: "127.0.0.1"` for loopback-only). lex-web#23.
#
# Build the opts inline as a record literal or get the defaults
# via `net.default_opts()`.
fn serve_with[E](
  port    :: Int,
  handler :: (Request) -> [E] Response,
  opts    :: { http2 :: Bool, inline_vm :: Bool, host :: Str },
) -> [net, E] Nil {
  net.serve_fn_with(port, handler, opts)
}

# HTTP/3 server over QUIC. TLS is mandatory in HTTP/3 — `tls` is
# an opaque `TlsConfig` value built by `std.tls`:
#
#   import "std.tls" as tls
#   match tls.self_signed("localhost") {
#     Ok(t)  => web_serve.serve_quic(4433, t, handle),
#     Err(_) => (),
#   }
#
# Requires the `lex` binary to be built with the `quic` feature
# (`cargo build --release --features quic`). The default release
# build omits it; without the feature the runtime returns a clear
# "compiled without quic" error at startup. lex-web#24.
#
# The QUIC listener binds UDP — port choice is independent of any
# TCP listener you may also have running. Production deployments
# typically pair an HTTP/1.1+2 listener on TCP:443 with an HTTP/3
# listener on UDP:443.
fn serve_quic[E](
  port    :: Int,
  tls     :: TlsConfig,
  handler :: (Request) -> [E] Response,
) -> [net, E] Nil {
  net.serve_quic_fn(port, tls, handler)
}
