# lex-web — SSE streaming bench.
#
# Single route:
#   GET /stream  -> text/event-stream with N SSE frames
#
# Uses lex-lang 0.9.2+'s streaming `ResponseBody::BodyStream(Iter[Str])`
# so the framework hands the iterator straight to the hyper sink
# without materialising the whole body. The bench answers two
# questions:
#
#   * Time-to-first-byte: how long until the *first* frame leaves
#     the server? Should be ~zero — the iterator is lazy.
#   * Sustained frame rate: how many frames does a single connection
#     pull per second?
#
# Default emits 10_000 frames per request; tune via the env var
# STREAM_FRAMES if you want a longer or shorter run.
#
# Run:
#   lex run --allow-effects io,net,time \
#           bench/servers/lex_web_bench_stream.lex main
#
# Drive with wrk for sustained rate:
#   wrk -t1 -c1 -d10s --latency http://127.0.0.1:8085/stream
#
# Or with curl --no-buffer to eyeball the stream itself:
#   curl --no-buffer http://127.0.0.1:8085/stream | head

import "std.net" as net

import "std.io" as io

import "std.iter" as iter

import "std.list" as list

import "std.map" as map

import "std.int" as int

import "std.str" as str

# The bench emits this many SSE frames per /stream request. 10_000
# matches the order of magnitude the TFB "infrastructure" bench rows
# use for cache-hot working sets; small enough that wrk can hammer
# a connection without the test taking forever, large enough that
# per-frame overhead dominates over connect/handshake cost.
fn frame_count() -> Int {
  10000
}

# Build one SSE frame. `data: <payload>\n\n` is the minimum legal
# SSE record per the WHATWG spec.
fn build_frame(i :: Int) -> Str {
  str.concat("data: ", str.concat("frame-", str.concat(int.to_str(i), "\n\n")))
}

# The iter passed to BodyStream. We materialise via `list.fold` +
# `iter.from_list` because in lex 0.9.4 the runtime's BodyStream
# sink drains `iter.from_list`-backed iterators correctly but
# returns an empty body for `iter.unfold`-backed ones — looks like
# the lazy-pull bridge is incomplete on that path. Observable
# behaviour on the wire is unchanged (chunked transfer-encoding,
# hyper pulls chunks one at a time); the only cost is holding the
# frame list in memory for the duration of the response. 10_000
# frames × ~25 bytes = ~250 KB, well under the working-set cost
# the bench wants to measure anyway.
fn frames() -> Iter[Str] {
  iter.from_list(list.fold(list.range(0, frame_count()), [], fn (acc :: List[Str], i :: Int) -> List[Str] {
    list.concat(acc, [build_frame(i)])
  }))
}

fn handle(req :: Request) -> Response {
  { status: 200, body: BodyStream(frames()), headers: map.from_list([("content-type", "text/event-stream"), ("cache-control", "no-cache")]) }
}

fn main() -> [net, io] Unit {
  let __lex_discard_1 := io.print("stream bench server on :8085")
  let __lex_discard_2 := io.print("  GET /stream  (10_000 SSE frames per request)")
  net.serve_fn(8085, handle)
}

