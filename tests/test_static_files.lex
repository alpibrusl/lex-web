# Tests for src/static_files.lex — in-memory static bundle.
# Filesystem-backed serving is not exercised here (would require
# [io] in the test runner).

import "std.list" as list

import "std.map" as map

import "std.str" as str

import "../src/ctx" as ctx

import "../src/router" as router

import "../src/static_files" as sf

import "../src/testing" as t

fn bundle() -> sf.Bundle {
  map.from_list([("index.html", "<h1>home</h1>"), ("css/site.css", "body { margin: 0 }"), ("script.js", "console.log('hi')")])
}

fn app() -> router.Router {
  sf.mount_map(router.new(), "/static", bundle())
}

fn test_serves_html() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.get("/static/index.html"))
  if r.status == 200 and str.contains(r.body, "home") and map.get(r.headers, "content-type") == Some("text/html; charset=utf-8") {
    Ok(())
  } else {
    Err("html not served correctly")
  }
}

fn test_serves_css() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.get("/static/css/site.css"))
  if r.status == 200 and map.get(r.headers, "content-type") == Some("text/css; charset=utf-8") {
    Ok(())
  } else {
    Err("css content-type wrong")
  }
}

fn test_serves_js() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.get("/static/script.js"))
  if r.status == 200 and map.get(r.headers, "content-type") == Some("application/javascript; charset=utf-8") {
    Ok(())
  } else {
    Err("js content-type wrong")
  }
}

fn test_404_unknown() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.get("/static/missing.txt"))
  if r.status == 404 {
    Ok(())
  } else {
    Err("expected 404")
  }
}

fn test_traversal_blocked() -> Result[Unit, Str] {
  let r := router.dispatch_pure(app(), t.get("/static/..%2Fsecret"))
  if r.status == 400 or r.status == 404 {
    Ok(())
  } else {
    Err("traversal not blocked")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_serves_html(), test_serves_css(), test_serves_js(), test_404_unknown(), test_traversal_blocked()]
}

# `lex test` calls run_all and reports the file as failed iff run_all
# panics. Fold the suite into a failure count and force a panic
# (`1 / 0`) when any case failed.
fn run_all() -> Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __lex_discard_1 := 1 / 0
    ()
  }
}

