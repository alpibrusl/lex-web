# lex-web — streaming response support
#
# Builds on lex-lang 0.9.2's ResponseBody union:
#
#   type ResponseBody = BodyStr(Str) | BodyIter(Iter[Str])
#
# `net.serve_fn` handlers may return either form. The existing
# `resp.Response` uses `BodyStr` internally and is unchanged.
# This module exposes the `BodyIter` path for:
#
#   - Server-Sent Events (SSE / EventSource)
#   - Newline-delimited JSON (NDJSON) for streaming APIs
#   - Large file chunking without buffering the full body
#
# A streaming handler returns `StreamResponse` instead of `Response`.
# Register via `router.route_stream` and dispatch through
# `router.dispatch_outcome` (#29) — the bridge in `main` matches
# the `DStream(...)` variant and wraps the body in `BodyStream(...)`
# for `net.serve_fn`. See `examples/streaming_api.lex`.
#
# Effects: none (constructors are pure; Iter evaluation is lazy).

import "std.str" as str

import "std.map" as map

import "std.iter" as iter

# A response whose body is a lazy iterator of chunks. net.serve_fn
# streams these to the client as they are produced.
type StreamResponse = { body :: Iter[Str], status :: Int, headers :: Map[Str, Str] }

# ---- SSE (Server-Sent Events) ------------------------------------
# Build a streaming SSE response from an iterator of data strings.
# Sets Content-Type to text/event-stream and disables caching.
# Each `data` string is wrapped in the SSE wire format automatically.
fn event_stream(events :: Iter[Str]) -> StreamResponse {
  let chunks := iter.map(events, fn (data :: Str) -> Str {
    sse_event(data)
  })
  { body: chunks, status: 200, headers: map.from_list([("content-type", "text/event-stream; charset=utf-8"), ("cache-control", "no-cache"), ("connection", "keep-alive")]) }
}

# Format one SSE data frame: `data: <payload>\n\n`
fn sse_event(data :: Str) -> Str {
  str.concat("data: ", str.concat(data, "\n\n"))
}

# Format a named SSE event: `event: <name>\ndata: <data>\n\n`
fn sse_named_event(name :: Str, data :: Str) -> Str {
  str.concat("event: ", str.concat(name, str.concat("\ndata: ", str.concat(data, "\n\n"))))
}

# Format an SSE comment (keepalive ping): `: <text>\n\n`
fn sse_comment(text :: Str) -> Str {
  str.concat(": ", str.concat(text, "\n\n"))
}

# ---- NDJSON streaming --------------------------------------------
# Build a streaming NDJSON response from an iterator of JSON strings.
# Each string is emitted as one line followed by `\n`.
fn ndjson_stream(lines :: Iter[Str]) -> StreamResponse {
  let chunks := iter.map(lines, fn (line :: Str) -> Str {
    str.concat(line, "\n")
  })
  { body: chunks, status: 200, headers: map.from_list([("content-type", "application/x-ndjson; charset=utf-8")]) }
}

# ---- Lazy chunk helpers ------------------------------------------
# Build an Iter[Str] from a seed and step, suitable for passing to
# event_stream / ndjson_stream. The step returns None to terminate.
#
#   let counter := stream.unfold(0, fn (n :: Int) -> Option[(Str, Int)] {
#     if n >= 10 { None }
#     else { Some((int.to_str(n), n + 1)) }
#   })
fn unfold[S](seed :: S, step :: (S) -> Option[(Str, S)]) -> Iter[Str] {
  iter.unfold(seed, step)
}

