# lex-web example — JSON-RPC over WebSocket
#
# A small JSON-RPC 2.0 server speaking the same protocol shape OCPP,
# LSP, and many real-time APIs use. Handles three methods:
#
#   { "jsonrpc": "2.0", "id": 1, "method": "ping",     "params": [] }
#   { "jsonrpc": "2.0", "id": 2, "method": "echo",     "params": ["hi"] }
#   { "jsonrpc": "2.0", "id": 3, "method": "subtract", "params": [10, 4] }
#
# Wires together: ws.serve (lex-lang v0.9.0 #359), ws path helpers
# (to read the room/channel from /rpc/<room>), and lex-schema's
# safe-mode Json parser for total input handling. The HTTP side
# serves a tiny browser console so you can poke at it without
# wscat — open http://localhost:8080/ and the page connects to
# ws://localhost:9000/rpc/lobby in JS.
#
# Run:
#   lex run --allow-effects io,net,time examples/jsonrpc_ws.lex main
#
# Then visit http://localhost:8080/ in a browser, or:
#   wscat -c ws://localhost:9000/rpc/lobby
#   > {"jsonrpc":"2.0","id":1,"method":"subtract","params":[10,4]}
#   < {"jsonrpc":"2.0","id":1,"result":6}

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/middleware" as mw

import "../src/ws" as ws

import "lex-schema/json_value" as jv

# ---- RPC dispatch -------------------------------------------------
# Parse one inbound frame as JSON-RPC 2.0 and reply. Unknown methods
# return the canonical -32601 error code; bad-shape frames return
# -32600 (Invalid Request).
fn dispatch_rpc(conn :: WsConn, frame :: Str) -> Str {
  match jv.parse(frame) {
    Err(_) => err_response(JNull, -32700, "Parse error"),
    Ok(j) => {
      let id := match jv.get_path(j, "id") {
        Some(v) => v,
        None => JNull,
      }
      let method := match jv.get_path(j, "method") {
        Some(JStr(m)) => m,
        _ => "",
      }
      let params := match jv.get_path(j, "params") {
        Some(JList(xs)) => xs,
        _ => [],
      }
      if str.is_empty(method) {
        err_response(id, -32600, "Invalid Request")
      } else {
        run_method(id, method, params, conn)
      }
    },
  }
}

fn run_method(id :: jv.Json, method :: Str, params :: List[jv.Json], conn :: WsConn) -> Str {
  if method == "ping" {
    ok_response(id, JStr("pong"))
  } else {
    if method == "echo" {
      match list.head(params) {
        None => err_response(id, -32602, "Invalid params"),
        Some(p) => ok_response(id, p),
      }
    } else {
      if method == "subtract" {
        match (list.head(params), list.head(list.tail(params))) {
          (Some(JInt(a)), Some(JInt(b))) => ok_response(id, JInt(a - b)),
          _ => err_response(id, -32602, "Invalid params"),
        }
      } else {
        if method == "whoami" {
          ok_response(id, JStr(ws.last_segment(conn.path)))
        } else {
          err_response(id, -32601, "Method not found")
        }
      }
    }
  }
}

fn ok_response(id :: jv.Json, result :: jv.Json) -> Str {
  jv.stringify(JObj([("jsonrpc", JStr("2.0")), ("id", id), ("result", result)]))
}

fn err_response(id :: jv.Json, code :: Int, message :: Str) -> Str {
  jv.stringify(JObj([("jsonrpc", JStr("2.0")), ("id", id), ("error", JObj([("code", JInt(code)), ("message", JStr(message))]))]))
}

# ---- WebSocket handler -------------------------------------------
fn on_message(conn :: WsConn, msg :: WsMessage) -> WsAction {
  match msg {
    WsText(frame) => ws.send(dispatch_rpc(conn, frame)),
    WsClose => WsNoOp,
    _ => WsNoOp,
  }
}

# ---- HTTP side — browser console ---------------------------------
# Tiny HTML page that opens a WS to /rpc/lobby and lets you fire
# canned RPC calls. Keeps the demo self-contained — no curl/wscat
# install needed to play with the server.
fn console_html() -> Str {
  "<!doctype html><html><head><meta charset=utf-8><title>Lex JSON-RPC</title></head><body><h1>Lex JSON-RPC over WS</h1><pre id=log></pre><script>const ws=new WebSocket('ws://'+location.hostname+':9000/rpc/lobby');const log=document.getElementById('log');ws.onopen=()=>{log.textContent+='OPEN\\n';['ping','whoami'].forEach((m,i)=>ws.send(JSON.stringify({jsonrpc:'2.0',id:i+1,method:m,params:[]})));ws.send(JSON.stringify({jsonrpc:'2.0',id:99,method:'subtract',params:[10,4]}))};ws.onmessage=e=>{log.textContent+='<- '+e.data+'\\n'};</script></body></html>"
}

fn http_app() -> router.Router {
  (router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/", fn (_c :: ctx.Ctx) -> resp.Response {
      resp.html(console_html())
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.logger())
  }
}

fn handle_http(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(http_app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

# ---- Entry point --------------------------------------------------
# Two servers: 8080 for the browser console, 9000 for the WS RPC endpoint.
fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Unit {
  let __lex_discard_1 := io.print("HTTP   :8080  http://localhost:8080/")
  let __lex_discard_2 := io.print("WS-RPC :9000  ws://localhost:9000/rpc/<room>")
  let __lex_discard_3 := io.print("Try wscat: > {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":[]}")
  let __lex_discard_4 := ws.serve(9000, "jsonrpc-2.0", on_message)
  net.serve_fn(8080, handle_http)
}

