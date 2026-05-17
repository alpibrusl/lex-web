# lex-web example — CSMS-style outbound WS sends via serve_ws_fn_actor.
#
# Mirrors the OCPP "Central System → Charge Point" flow that motivated
# alpibrusl/lex-web#4. Each WebSocket connection is registered as a
# named actor in the conc registry; an HTTP endpoint on the *same
# process* looks the actor up and pushes a frame into the socket.
#
# Topology:
#
#   ws://127.0.0.1:9001/ws/<charger_id>     ← charge points dial here
#   http://127.0.0.1:9000/remote/<id>       ← operator console hits this
#
# Hitting POST /remote/cp001 pushes a frame to whichever charger is
# connected under name "charger:cp001"; the dialled WS client sees it
# arrive on the wire.
#
# Run:
#   lex run --allow-effects io,net,time,concurrent,crypto,random,sql,fs_read,fs_write \
#           examples/csms_outbound.lex main
#
# Smoke-test (two terminals):
#   # terminal 1 — boot the example
#   lex run … examples/csms_outbound.lex main
#   # terminal 2 — dial as cp001 (websocat / wscat)
#   websocat ws://127.0.0.1:9001/ws/cp001
#   # terminal 3 — push a "RemoteStartTransaction" via the operator http port
#   curl -X POST http://127.0.0.1:9000/remote/cp001
#   # terminal 2 sees: [2,"m1","RemoteStartTransaction",{"connectorId":1}]

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.conc" as conc

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

# ---- WS side ------------------------------------------------------
# name_of derives a registry name from the URL path.
# `/ws/cp001` -> `charger:cp001`. Empty string opts out of registration.
fn name_of(conn :: WsConn) -> Str {
  match str.strip_prefix(conn.path, "/ws/") {
    Some(id) => str.concat("charger:", id),
    None => "",
  }
}

# Inbound handler: log the body, send back an OCPP-style ACK. Real
# CSMS code would parse the Call / CallResult / CallError frame here.
fn on_message(_c :: WsConn, msg :: WsMessage) -> WsAction {
  match msg {
    WsText(body) => WsSend(str.concat("[3,\"ack\",", str.concat(body, "]"))),
    _ => WsNoOp,
  }
}

# ---- HTTP side ----------------------------------------------------
# A single operator-facing route: POST /remote/<id> pushes the
# canonical RemoteStartTransaction frame into the named WS actor.
fn build_app() -> router.Router {
  router.new() |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "POST", "/remote/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
      remote_start(c)
    })
  }
}

fn remote_start(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("missing :id"),
    Some(cp_id) => {
      let name := str.concat("charger:", cp_id)
      match conc.lookup(name) {
        None => resp.json_status(404, str.concat("{\"error\":\"offline\",\"charger\":\"", str.concat(cp_id, "\"}"))),
        Some(actor) => {
          let frame := str.concat("[2,\"m1\",\"RemoteStartTransaction\",{\"connectorId\":1,\"chargerId\":\"", str.concat(cp_id, "\"}]"))
          let __lex_discard_1 := conc.tell(actor, frame)
          resp.json(str.concat("{\"sent\":true,\"charger\":\"", str.concat(cp_id, "\"}")))
        },
      }
    },
  }
}

# ---- main ---------------------------------------------------------
# Spawn the WS listener in a thread, the HTTP listener stays on main.
# Both register against the same process-global conc_registry.
fn main() -> [io, net, concurrent, time, crypto, random, sql, fs_read, fs_write] Unit {
  let __lex_discard_2 := io.print("CSMS example — WS on :9001, HTTP on :9000")
  let __lex_discard_3 := io.print("  charge points: ws://127.0.0.1:9001/ws/<id>")
  let __lex_discard_4 := io.print("  operator API:  POST http://127.0.0.1:9000/remote/<id>")
  let __lex_discard_5 := conc.spawn(0, fn (_s :: Int, _m :: Int) -> [io, net, concurrent, time, crypto, random, sql, fs_read, fs_write] (Int, Int) {
    let __lex_discard_6 := net.serve_ws_fn_actor(9001, "ocpp1.6", name_of, on_message)
    (0, 0)
  })
  let r := build_app()
  let handler := fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
    let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
    let resp_v := router.dispatch(r, raw)
    { status: resp_v.status, body: BodyStr(resp_v.body), headers: resp_v.headers }
  }
  net.serve_fn(9000, handler)
}

