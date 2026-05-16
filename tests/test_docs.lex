# Tests for src/docs.lex — Swagger UI / ReDoc HTML pages.

import "std.list" as list

import "std.str" as str

import "../src/ctx" as ctx

import "../src/router" as router

import "../src/docs" as docs

import "../src/testing" as t

fn test_swagger_html_contains_url() -> Result[Unit, Str] {
  let html := docs.swagger_ui_html("/openapi.json", "My API")
  if str.contains(html, "/openapi.json") and str.contains(html, "My API") and str.contains(html, "swagger-ui") {
    Ok(())
  } else {
    Err("swagger HTML missing pieces")
  }
}

fn test_redoc_html_contains_url() -> Result[Unit, Str] {
  let html := docs.redoc_html("/openapi.json", "My API")
  if str.contains(html, "spec-url=\"/openapi.json\"") and str.contains(html, "redoc") {
    Ok(())
  } else {
    Err("redoc HTML missing pieces")
  }
}

fn test_mount_serves_docs() -> Result[Unit, Str] {
  let app := docs.mount(router.new(), "/openapi.json", "Test")
  let r := router.dispatch_pure(app, t.get("/docs"))
  if r.status == 200 and str.contains(r.body, "swagger-ui") {
    Ok(())
  } else {
    Err("/docs did not serve swagger HTML")
  }
}

fn test_mount_serves_redoc() -> Result[Unit, Str] {
  let app := docs.mount(router.new(), "/openapi.json", "Test")
  let r := router.dispatch_pure(app, t.get("/redoc"))
  if r.status == 200 and str.contains(r.body, "redoc") {
    Ok(())
  } else {
    Err("/redoc did not serve redoc HTML")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_swagger_html_contains_url(), test_redoc_html_contains_url(), test_mount_serves_docs(), test_mount_serves_redoc()]
}

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

