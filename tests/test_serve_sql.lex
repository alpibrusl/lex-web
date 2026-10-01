# serve_with keeps the caller's effect row (#61). The handler declares only
# [sql], so serving it needs `net` and `sql` and nothing else. CI runs
#
#   lex run --allow-effects net,sql tests/test_serve_sql.lex main
#
# curls it, and checks that a grant without `sql` is refused. The old literal
# `[E]` signature rejected a [sql] handler at type-check time.

import "std.map" as map

import "../src/serve" as web_serve

fn handler(req :: Request) -> [sql] Response {
  { status: 200, body: BodyStr("ok"), headers: map.new() }
}

fn main() -> [net, sql] Nil {
  web_serve.serve_with(8123, handler, { http2: false, inline_vm: false, host: "127.0.0.1" })
}

