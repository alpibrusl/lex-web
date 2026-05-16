# lex-web — WebSocket support
#
# Thin wrapper over net.serve_ws_fn (lex-lang v0.9.0 / #359).
#
# WsConn, WsMessage, and WsAction are global builtin types —
# no import needed. This module adds the serve() entry point,
# convenience constructors, and path helpers.
#
# Global types (from lex-lang v0.9.0):
#   WsConn    = { id :: Str, path :: Str, subprotocol :: Str }
#   WsMessage = WsText(Str) | WsBinary(List[Int]) | WsPing | WsClose
#   WsAction  = WsSend(Str) | WsSendBinary(List[Int]) | WsNoOp
#
# Effects:
#   ws.serve — [net]
#   ws.dial  — [net, E]   (E from caller-supplied callbacks)
#   message handler — declared by the handler itself

import "std.str" as str

import "std.list" as list

import "std.net" as net

# ---- Entry point ---------------------------------------------------
# Start a WebSocket server on `port` negotiating `subprotocol`
# (pass "" for no subprotocol). `handler` is called for every
# inbound frame; return WsNoOp to send nothing.
fn serve(port :: Int, subprotocol :: Str, handler :: (WsConn, WsMessage) -> WsAction) -> [net] Nil {
  net.serve_ws_fn(port, subprotocol, handler)
}

# ---- Convenience constructors -------------------------------------
fn send(frame :: Str) -> WsAction {
  WsSend(frame)
}

fn send_binary(bytes :: List[Int]) -> WsAction {
  WsSendBinary(bytes)
}

fn noop() -> WsAction {
  WsNoOp
}

# ---- Path helpers ------------------------------------------------
# Extract the last non-empty segment of the upgrade path.
# last_segment("/ocpp/charger-42") == "charger-42"
fn last_segment(path :: Str) -> Str {
  let segs := list.filter(str.split(path, "/"), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
  match list.fold(segs, None, fn (acc :: Option[Str], s :: Str) -> Option[Str] {
    Some(s)
  }) {
    Some(s) => s,
    None => "",
  }
}

# Extract a named segment by 0-based index.
# segment("/ocpp/charger-42", 1) == Some("charger-42")
fn segment(path :: Str, idx :: Int) -> Option[Str] {
  let segs := list.filter(str.split(path, "/"), fn (s :: Str) -> Bool {
    not str.is_empty(s)
  })
  let pair := list.fold(segs, (0, None), fn (acc :: (Int, Option[Str]), s :: Str) -> (Int, Option[Str]) {
    let i := match acc {
      (n, _) => n,
    }
    let v := match acc {
      (_, o) => o,
    }
    if i == idx {
      (i + 1, Some(s))
    } else {
      (i + 1, v)
    }
  })
  match pair {
    (_, o) => o,
  }
}

# ---- Frame helpers -----------------------------------------------
# Unwrap a WsText frame; return None for non-text messages.
fn text_frame(msg :: WsMessage) -> Option[Str] {
  match msg {
    WsText(s) => Some(s),
    _ => None,
  }
}

# True if the message is a graceful close request from the client.
fn is_close(msg :: WsMessage) -> Bool {
  match msg {
    WsClose => true,
    _ => false,
  }
}

# ---- Client-side (dial) -------------------------------------------
# Open an outbound WebSocket connection to `url` (ws:// or wss://).
# `subprotocol` is e.g. "ocpp1.6" or "" for none.
# `on_open` fires once after the handshake; return a WsAction to send an
# immediate frame or WsNoOp.
# `on_message` is called for every inbound frame; return a WsAction reply.
# Returns Err(Str) if the connection fails or drops with an error.
fn dial[E](url :: Str, subprotocol :: Str, on_open :: () -> [E] WsAction, on_message :: (WsMessage) -> [E] WsAction) -> [net, E] Result[Unit, Str] {
  net.dial_ws(url, subprotocol, on_open, on_message)
}

