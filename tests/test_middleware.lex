# Tests for src/middleware.lex — pre/post middleware application.
#
# Logger is tested in isolation; the [io] effect is confined to
# that specific test. The rest of the suite is pure.

import "std.list" as list
import "std.str"  as str
import "std.map"  as map
import "std.io"   as io

import "../src/ctx"        as ctx
import "../src/response"   as resp
import "../src/middleware" as mw
import "../src/testing"    as t

# ---- Helpers -----------------------------------------------------

fn bare_ctx(path :: Str, body :: Str) -> ctx.Ctx {
  ctx.from_request(
    { method: "GET", path: path, body: body, query: "" },
    map.new())
}

# ---- body_limit --------------------------------------------------

fn body_limit_allows_small_body() -> Result[Unit, Str] {
  let c := bare_ctx("/", "hello")
  match mw.apply_pre(mw.body_limit(1024), c) {
    mw.Continue(_) => Ok(()),
    mw.Short(_)    => Err("should not short-circuit small body"),
  }
}

fn body_limit_blocks_large_body() -> Result[Unit, Str] {
  let big := str.repeat("x", 2000)
  let c   := bare_ctx("/", big)
  match mw.apply_pre(mw.body_limit(1024), c) {
    mw.Short(r)   => t.assert_status(r, 413),
    mw.Continue(_) => Err("expected 413 short-circuit"),
  }
}

fn body_limit_exact_boundary_allowed() -> Result[Unit, Str] {
  # Body of exactly max_bytes is allowed (limit is exclusive of equal).
  # We use limit=5 and a 5-char body.
  let c := bare_ctx("/", "hello")
  match mw.apply_pre(mw.body_limit(5), c) {
    mw.Continue(_) => Ok(()),
    mw.Short(_)    => Err("exact limit should not block"),
  }
}

fn run_pre_stops_at_first_short() -> Result[Unit, Str] {
  let big := str.repeat("x", 2000)
  let c   := bare_ctx("/", big)
  let mws := [mw.body_limit(100), mw.body_limit(10000)]
  match mw.run_pre(mws, c) {
    mw.Short(r)    => t.assert_status(r, 413),
    mw.Continue(_) => Err("expected short-circuit from first middleware"),
  }
}

# ---- cors --------------------------------------------------------

fn cors_adds_origin_header() -> Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.json("{}")
  let r2 := mw.apply_post(mw.cors(["https://example.com"]), c, r)
  t.assert_header_contains(r2, "access-control-allow-origin", "example.com")
}

fn cors_adds_methods_header() -> Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.json("{}")
  let r2 := mw.apply_post(mw.cors(["*"]), c, r)
  t.assert_header_present(r2, "access-control-allow-methods")
}

fn cors_preserves_existing_headers() -> Result[Unit, Str] {
  let c  := bare_ctx("/", "")
  let r  := resp.with_header(resp.json("{}"), "x-custom", "kept")
  let r2 := mw.apply_post(mw.cors(["*"]), c, r)
  t.assert_header(r2, "x-custom", "kept")
}

# ---- request_id --------------------------------------------------

fn request_id_adds_header() -> [io] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.json("{}")
  let r2 := mw.apply_post(mw.request_id(), c, r)
  t.assert_header_present(r2, "x-request-id")
}

# ---- non-matching kinds are no-ops for opposite phase -----------

fn body_limit_is_noop_in_post() -> [io] Result[Unit, Str] {
  let c := bare_ctx("/", "")
  let r := resp.json("{\"original\":true}")
  let r2 := mw.apply_post(mw.body_limit(100), c, r)
  t.assert_body_eq(r2, "{\"original\":true}")
}

fn cors_is_noop_in_pre() -> Result[Unit, Str] {
  let c := bare_ctx("/", "small")
  match mw.apply_pre(mw.cors(["*"]), c) {
    mw.Continue(_) => Ok(()),
    mw.Short(_)    => Err("cors should not short-circuit in pre"),
  }
}

# ---- Suite -------------------------------------------------------
# Note: request_id_adds_header and body_limit_is_noop_in_post use
# [io] because apply_post for MwRequestId calls time.now(). The
# full suite is therefore [io].

fn suite() -> [io] List[Result[Unit, Str]] {
  [
    body_limit_allows_small_body(),
    body_limit_blocks_large_body(),
    body_limit_exact_boundary_allowed(),
    run_pre_stops_at_first_short(),
    cors_adds_origin_header(),
    cors_adds_methods_header(),
    cors_preserves_existing_headers(),
    request_id_adds_header(),
    body_limit_is_noop_in_post(),
    cors_is_noop_in_pre(),
  ]
}

fn run_all() -> [io] Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  })
}
