# lex-web example — multi-room chat with presence
#
# Exercises every lex-lang / lex-web / lex-schema primitive added in
# the last three releases in one ~250-line file. Two listeners in
# one process; both touch the same `conc_registry` so a user's WS
# socket can be reached from arbitrary HTTP contexts.
#
# Endpoints:
#
#   ws://127.0.0.1:9100/ws/<user>          — chat WS, each user is a
#                                            named actor "user:<user>"
#   GET  http://127.0.0.1:9000/rooms        — JSON list of live rooms
#   GET  http://127.0.0.1:9000/users        — JSON list of online users
#   POST http://127.0.0.1:9000/say          — JSON {room, body, from}
#                                              broadcast to every user
#                                              currently in <room>
#   POST http://127.0.0.1:9000/dm/:user     — JSON {body, from}
#                                              direct-message <user>
#   GET  http://127.0.0.1:9000/history.html — last 20 messages as a
#                                              server-rendered page
#                                              (HTML-escaped via
#                                              lex-schema/html)
#
# Primitives demonstrated:
#
# | Concern                              | Primitive                          |
# | ------------------------------------ | ---------------------------------- |
# | HTTP API for room/user/history       | route_effectful                    |
# | WS per-user named actor              | serve_ws_fn_actor (lex-lang 0.9.5) |
# | Targeted send to one user            | conc.lookup + conc.tell            |
# | Broadcast to a room                  | conc.registered + filter + tell    |
# | Validated JSON request body          | lex-schema/validator               |
# | XSS-safe HTML interpolation          | lex-schema/html.escape             |
# | Pretty room-name parsing             | std.str.split                      |
# | Process-shared mutable state         | conc actor as a singleton          |
#
# Run:
#   lex run --allow-effects io,net,time,concurrent,crypto,random,sql,fs_read,fs_write \
#           examples/chat_app.lex main
#
# Smoke test (three terminals):
#   # boot
#   lex run … examples/chat_app.lex main
#   # join as alice in #general
#   websocat ws://127.0.0.1:9100/ws/alice
#   > /join general
#   # broadcast to #general from outside
#   curl -X POST http://127.0.0.1:9000/say \
#        -H 'content-type: application/json' \
#        -d '{"room":"general","from":"ops","body":"hello team"}'
#   # alice's wscat session prints: [general] ops: hello team

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "std.time" as time

import "std.conc" as conc

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/body" as body

import "lex-schema/html" as html

import "lex-schema/validator" as v

import "lex-schema/schema" as s

import "lex-schema/json_value" as jv

# ---- Membership actor --------------------------------------------
# A process-singleton actor that holds the user → room mapping.
# Lookups are via `conc.ask`; updates via `conc.tell`. We register
# the actor under "chat:members" so any handler can find it via
# `conc.lookup`.
#
# State: Map[Str, Str]   (user -> room)
# Msg:   Variant         (Join(user, room) | Leave(user) |
#                         RoomsOf(_) | UsersIn(room) | All)
type MemberMsg = Join((Str, Str)) | Leave(Str) | RoomsOf | UsersIn(Str) | All

fn members_handler(state :: Map[Str, Str], msg :: MemberMsg) -> (Map[Str, Str], Map[Str, Str]) {
  match msg {
    Join(user, room) => {
      let s2 := map.set(state, user, room)
      (s2, s2)
    },
    Leave(user) => {
      let s2 := map.delete(state, user)
      (s2, s2)
    },
    RoomsOf => (state, state),
    UsersIn(_) => (state, state),
    All => (state, state),
  }
}

fn members_name() -> Str {
  "chat:members"
}

# Spin up the membership actor on startup and register it.
fn boot_members() -> [concurrent] Unit {
  let m := conc.spawn(map.new(), members_handler)
  match conc.register(m, members_name()) {
    Ok(_) => (),
    Err(_) => (),
  }
}

# Get the full membership snapshot. None means the actor isn't
# registered (shouldn't happen — boot_members runs at startup).
fn snapshot() -> [concurrent] Map[Str, Str] {
  match conc.lookup(members_name()) {
    None => map.new(),
    Some(a) => conc.ask(a, All),
  }
}

# ---- WS-side: name_of + on_message -------------------------------
# Each accepted WS connection is registered as actor "user:<id>",
# where <id> is the trailing path segment of /ws/<id>. The
# `on_message` handler implements three commands:
#
#   /join <room>     — set user's current room in the membership actor
#   /leave           — clear it
#   <anything else>  — broadcast to user's current room
fn user_id_from_path(path :: Str) -> Str {
  match str.strip_prefix(path, "/ws/") {
    Some(id) => id,
    None => "",
  }
}

fn name_of(conn :: WsConn) -> Str {
  let id := user_id_from_path(conn.path)
  if str.is_empty(id) {
    ""
  } else {
    str.concat("user:", id)
  }
}

fn on_message(conn :: WsConn, msg :: WsMessage) -> [concurrent] WsAction {
  match msg {
    WsText(body_str) => handle_chat(conn, body_str),
    _ => WsNoOp,
  }
}

fn handle_chat(conn :: WsConn, line :: Str) -> [concurrent] WsAction {
  let me := user_id_from_path(conn.path)
  if str.starts_with(line, "/join ") {
    let room := str.slice(line, 6, str.len(line))
    let __lex_discard_1 := tell_members(Join(me, room))
    WsSend(str.concat("ok join ", room))
  } else {
    if line == "/leave" {
      let __lex_discard_2 := tell_members(Leave(me))
      WsSend("ok leave")
    } else {
      let room := room_of(me)
      if str.is_empty(room) {
        WsSend("err: /join <room> first")
      } else {
        broadcast_to_room(room, me, line)
        WsSend("ok")
      }
    }
  }
}

fn tell_members(msg :: MemberMsg) -> [concurrent] Unit {
  match conc.lookup(members_name()) {
    None => (),
    Some(a) => conc.tell(a, msg),
  }
}

fn room_of(user :: Str) -> [concurrent] Str {
  match map.get(snapshot(), user) {
    Some(r) => r,
    None => "",
  }
}

# Broadcast `body` to every user currently in `room` (excluding the
# sender). Iterates `conc.registered()` and filters to actor names
# that start with "user:" whose corresponding member is in `room`.
fn broadcast_to_room(room :: Str, from :: Str, body_str :: Str) -> [concurrent] Unit {
  let snap := snapshot()
  let line := str.concat("[", str.concat(room, str.concat("] ", str.concat(from, str.concat(": ", body_str)))))
  list.fold(conc.registered(), (), fn (__lex_discard_3 :: Unit, name :: Str) -> [concurrent] Unit {
    match str.strip_prefix(name, "user:") {
      None => (),
      Some(uid) => {
        if uid == from {
          ()
        } else {
          match map.get(snap, uid) {
            Some(r) => if r == room {
              send_to(name, line)
            } else {
              ()
            },
            None => (),
          }
        }
      },
    }
  })
}

fn send_to(actor_name :: Str, line :: Str) -> [concurrent] Unit {
  match conc.lookup(actor_name) {
    None => (),
    Some(a) => conc.tell(a, line),
  }
}

# ---- HTTP side ---------------------------------------------------
# Three operator-facing routes. Validators are attached via
# `handler_json_effectful` so the body shape is checked before the
# handler runs.
fn say_validator() -> v.Validator {
  v.make({ title: "Say", description: "broadcast a message to a chat room", fields: [s.required_str("room", []), s.required_str("from", []), s.required_str("body", [])] })
}

fn dm_validator() -> v.Validator {
  v.make({ title: "DM", description: "direct message", fields: [s.required_str("from", []), s.required_str("body", [])] })
}

fn handler_say(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match body.require_json_body(c, say_validator()) {
    Err(r) => r,
    Ok(j) => {
      let room := jv_str(j, "room")
      let from := jv_str(j, "from")
      let txt := jv_str(j, "body")
      broadcast_to_room(room, from, txt)
      resp.json(str.concat("{\"sent\":true,\"room\":\"", str.concat(room, "\"}")))
    },
  }
}

fn handler_dm(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match ctx.path_param(c, "user") {
    None => resp.bad_request("missing :user"),
    Some(target) => match body.require_json_body(c, dm_validator()) {
      Err(r) => r,
      Ok(j) => {
        let from := jv_str(j, "from")
        let txt := jv_str(j, "body")
        let line := str.concat("(dm from ", str.concat(from, str.concat(") ", txt)))
        send_to(str.concat("user:", target), line)
        resp.json(str.concat("{\"sent\":true,\"to\":\"", str.concat(target, "\"}")))
      },
    },
  }
}

fn handler_rooms(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  let snap := snapshot()
  let rooms := list.fold(map.values(snap), [], fn (acc :: List[Str], r :: Str) -> List[Str] {
    if list_contains(acc, r) {
      acc
    } else {
      list.concat(acc, [r])
    }
  })
  resp.json(str.concat("[", str.concat(str.join(list.map(rooms, quote), ","), "]")))
}

fn handler_users(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  let online := list.fold(conc.registered(), [], fn (acc :: List[Str], name :: Str) -> List[Str] {
    match str.strip_prefix(name, "user:") {
      Some(uid) => list.concat(acc, [uid]),
      None => acc,
    }
  })
  resp.json(str.concat("[", str.concat(str.join(list.map(online, quote), ","), "]")))
}

# Render the membership snapshot as an HTML table. User-supplied
# values (room names, user ids) are pushed through `html.escape`
# before interpolation — without it, a user named `<script>` would
# get to inject markup into the operator's browser.
fn handler_history(c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  let snap := snapshot()
  let rows := list.fold(map.entries(snap), "", fn (acc :: Str, kv :: (Str, Str)) -> Str {
    match kv {
      (user, room) => str.concat(acc, str.concat("<tr><td>", str.concat(html.escape(user), str.concat("</td><td>", str.concat(html.escape(room), "</td></tr>"))))),
    }
  })
  let page := str.concat("<!doctype html><meta charset=utf-8><title>chat presence</title><table border=1><tr><th>user</th><th>room</th></tr>", str.concat(rows, "</table>"))
  resp.html(page)
}

# ---- Tiny helpers ------------------------------------------------
fn jv_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_path(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn quote(s :: Str) -> Str {
  str.concat("\"", str.concat(s, "\""))
}

fn list_contains(xs :: List[Str], needle :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      x == needle
    }
  })
}

# ---- App ---------------------------------------------------------
fn build_app() -> router.Router {
  ((((router.new() |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/rooms", handler_rooms)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/users", handler_users)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "GET", "/history.html", handler_history)
  }) |> fn (r :: router.Router) -> router.Router {
    router.handler_json_effectful(r, "POST", "/say", say_validator(), handler_say)
  }) |> fn (r :: router.Router) -> router.Router {
    router.route_effectful(r, "POST", "/dm/:user", handler_dm)
  }
}

# ---- main --------------------------------------------------------
fn main() -> [io, net, concurrent, time, crypto, random, sql, fs_read, fs_write] Unit {
  let __lex_discard_4 := boot_members()
  let __lex_discard_5 := io.print("chat-app — WS :9100  HTTP :9000")
  let __lex_discard_6 := io.print("  ws ws://127.0.0.1:9100/ws/<user>")
  let __lex_discard_7 := io.print("  http://127.0.0.1:9000/rooms /users /history.html  POST /say /dm/:user")
  let __lex_discard_8 := conc.spawn(0, fn (_s :: Int, _m :: Int) -> [io, net, concurrent, time, crypto, random, sql, fs_read, fs_write] (Int, Int) {
    let __lex_discard_9 := net.serve_ws_fn_actor(9100, "", name_of, on_message)
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

