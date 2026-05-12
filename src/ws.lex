# lex-web — WebSocket support
#
# Thin wrapper over the net.serve_ws primitive (lex-lang#359).
#
# Usage pattern (OCPP, LSP, or any WS protocol):
#
#   import "../src/ws" as ws
#
#   fn on_message(conn :: ws.Conn, msg :: ws.Message) -> [io] ws.Action {
#     match msg {
#       WsText(frame) => WsReply(handle_frame(conn, frame)),
#       WsClose       => WsIgnore,
#       _             => WsIgnore,
#     }
#   }
#
#   fn main() -> [net] Nil {
#     ws.serve(9000, "ocpp1.6", "on_message")
#   }
#
# Effects:
#   ws.serve        — [net]
#   message handler — declared by the handler itself (e.g. [io])
#
# Blocked on lex-lang#359 (net.serve_ws primitive).
# The types and helpers below are defined now so lex-ocpp and other
# consumers can be written against a stable surface.

import "std.str"  as str
import "std.list" as list

# ---- Connection handle -------------------------------------------

# Opaque per-connection context passed to every message handler.
# `id`          — stable string identity for this connection (use as
#                 a store key for per-connection state).
# `path`        — HTTP upgrade request path (e.g. "/ocpp/charger-01").
# `subprotocol` — negotiated Sec-WebSocket-Protocol value.
type Conn = {
  id          :: Str,
  path        :: Str,
  subprotocol :: Str,
}

# ---- Incoming message types --------------------------------------

# Text covers all JSON-over-WS protocols (OCPP, JSON-RPC, LSP).
# Binary is for binary-framed protocols.
# WsPing is received when the client sends a ping frame.
# WsClose is received when the client initiates a graceful close.
type Message =
    WsText(Str)
  | WsBinary(List[Int])
  | WsPing
  | WsClose

# ---- Handler response actions ------------------------------------

# What the runtime should do after the handler returns.
# WsReply(s)  — send a UTF-8 text frame back to the client.
# WsHangup    — close this connection gracefully.
# WsIgnore    — nothing to send (fire-and-forget; pings auto-ponged).
type Action =
    WsReply(Str)
  | WsHangup
  | WsIgnore

# ---- Convenience constructors ------------------------------------

fn reply(frame :: Str) -> Action { WsReply(frame) }
fn hangup() -> Action { WsHangup }
fn ignore() -> Action { WsIgnore }

# ---- Path helpers ------------------------------------------------

# Extract the last segment of the upgrade path.
# last_segment("/ocpp/charger-42") == "charger-42"
fn last_segment(path :: Str) -> Str {
  let segs := list.filter(str.split(path, "/"),
    fn (s :: Str) -> Bool { not str.is_empty(s) })
  match list.fold(segs, None,
    fn (acc :: Option[Str], s :: Str) -> Option[Str] { Some(s) })
  {
    Some(s) => s,
    None    => "",
  }
}

# Extract a named segment by 0-based index.
# segment("/ocpp/charger-42", 1) == Some("charger-42")
fn segment(path :: Str, idx :: Int) -> Option[Str] {
  let segs := list.filter(str.split(path, "/"),
    fn (s :: Str) -> Bool { not str.is_empty(s) })
  let pair := list.fold(segs, (0, None),
    fn (acc :: (Int, Option[Str]), s :: Str) -> (Int, Option[Str]) {
      let i := match acc { (n, _) => n }
      let v := match acc { (_, o) => o }
      if i == idx { (i + 1, Some(s)) }
      else { (i + 1, v) }
    })
  match pair { (_, o) => o }
}

# ---- Frame helpers -----------------------------------------------

# Unwrap a WsText frame; return None for non-text messages.
fn text_frame(msg :: Message) -> Option[Str] {
  match msg {
    WsText(s) => Some(s),
    _         => None,
  }
}

# True if the message is a graceful close request from the client.
fn is_close(msg :: Message) -> Bool {
  match msg { WsClose => true, _ => false }
}
