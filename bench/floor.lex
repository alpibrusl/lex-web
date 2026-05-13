# lex-web — minimal floor bench (no router, no DB)
#
# Bypasses lex-web's local Request/Response types entirely and
# uses the globals defined by lex-lang v0.9.0+. Measures the
# absolute floor: net.serve_fn dispatch + body construction.
#
# Run:
#   lex run --allow-effects io,net bench/floor.lex main
#
# Try (from another terminal):
#   curl http://localhost:8080/plaintext
#   curl http://localhost:8080/json
#   wrk -t4 -c256 -d15s http://localhost:8080/plaintext
#   wrk -t4 -c256 -d15s http://localhost:8080/json

import "std.net" as net
import "std.io"  as io
import "std.map" as map

# Single closure dispatching by req.path. No router, no middleware,
# no validation — the cheapest possible path lex-web can support.

fn handle(req :: Request) -> Response {
  if req.path == "/plaintext" {
    {
      status:  200,
      body:    "Hello, World!",
      headers: map.from_list([("content-type", "text/plain; charset=utf-8")]),
    }
  } else {
    if req.path == "/json" {
      {
        status:  200,
        body:    "{\"message\":\"Hello, World!\"}",
        headers: map.from_list([("content-type", "application/json")]),
      }
    } else {
      {
        status:  404,
        body:    "not found",
        headers: map.from_list([("content-type", "text/plain; charset=utf-8")]),
      }
    }
  }
}

fn main() -> [net, io] Nil {
  let _ := io.print("bench floor on :8080 — /plaintext, /json")
  net.serve_fn(8080, handle)
}
