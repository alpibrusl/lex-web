# Tests for src/multipart.lex (#25).
#
# Each test builds a synthetic Ctx with a Content-Type header
# and a body that mimics what curl / a browser would send for
# multipart/form-data, then asserts the parsed shape.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "../src/ctx" as ctx

import "../src/multipart" as mp

import "../src/testing" as t

# ---- Helpers -----------------------------------------------------
# Default limits — generous enough for tests, tight enough to
# also exercise the limit-check codepath when we cross them.
fn default_limits() -> mp.Limits {
  { max_parts: 8, max_size: 1024 }
}

fn ctx_with_body(ctype :: Str, body :: Str) -> ctx.Ctx {
  let hdrs := map.set(map.new(), "content-type", ctype)
  ctx.from_request({ method: "POST", path: "/upload", body: body, query: "", headers: hdrs }, map.new())
}

fn ctx_no_ctype(body :: Str) -> ctx.Ctx {
  ctx.from_request({ method: "POST", path: "/upload", body: body, query: "", headers: map.new() }, map.new())
}

# Build a well-formed multipart body. Boundary is fixed to
# `BOUND` so test bodies are short and readable.
fn body_one_text(name :: Str, value :: Str) -> Str {
  str.concat("--BOUND\r\nContent-Disposition: form-data; name=\"", str.concat(name, str.concat("\"\r\n\r\n", str.concat(value, "\r\n--BOUND--\r\n"))))
}

fn body_one_file(name :: Str, filename :: Str, ctype :: Str, value :: Str) -> Str {
  str.concat("--BOUND\r\nContent-Disposition: form-data; name=\"", str.concat(name, str.concat("\"; filename=\"", str.concat(filename, str.concat("\"\r\nContent-Type: ", str.concat(ctype, str.concat("\r\n\r\n", str.concat(value, "\r\n--BOUND--\r\n"))))))))
}

# Two-part body: a text field followed by a file field.
fn body_text_and_file() -> Str {
  str.concat("--BOUND\r\nContent-Disposition: form-data; name=\"username\"\r\n\r\n", str.concat("alice", str.concat("\r\n--BOUND\r\nContent-Disposition: form-data; name=\"avatar\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\n", "hello world\r\n--BOUND--\r\n")))
}

fn multipart_ctype() -> Str {
  "multipart/form-data; boundary=BOUND"
}

# ---- Happy paths -------------------------------------------------
fn single_text_field_parses() -> Result[Unit, Str] {
  let c := ctx_with_body(multipart_ctype(), body_one_text("greeting", "hello"))
  match mp.parse(c, default_limits()) {
    Err(e) => Err(str.concat("parse failed: ", e.message)),
    Ok(parts) => match mp.find_text(parts, "greeting") {
      Some(v) => if v == "hello" {
        Ok(())
      } else {
        Err(str.concat("expected greeting=hello, got: ", v))
      },
      None => Err("greeting field not found"),
    },
  }
}

fn single_file_field_parses() -> Result[Unit, Str] {
  let c := ctx_with_body(multipart_ctype(), body_one_file("avatar", "pic.txt", "text/plain", "hi"))
  match mp.parse(c, default_limits()) {
    Err(e) => Err(str.concat("parse failed: ", e.message)),
    Ok(parts) => match mp.find_file(parts, "avatar") {
      Some(f) => if f.filename == "pic.txt" and f.content_type == "text/plain" and f.body == "hi" {
        Ok(())
      } else {
        Err(str.concat("unexpected file shape: filename=", str.concat(f.filename, str.concat(" body=", f.body))))
      },
      None => Err("avatar field not found"),
    },
  }
}

fn mixed_text_and_file_parses() -> Result[Unit, Str] {
  let c := ctx_with_body(multipart_ctype(), body_text_and_file())
  match mp.parse(c, default_limits()) {
    Err(e) => Err(str.concat("parse failed: ", e.message)),
    Ok(parts) => match (mp.find_text(parts, "username"), mp.find_file(parts, "avatar")) {
      (Some(u), Some(a)) => if u == "alice" and a.filename == "a.txt" and a.body == "hello world" {
        Ok(())
      } else {
        Err("mixed body fields mismatch")
      },
      (None, _) => Err("username text field missing"),
      (_, None) => Err("avatar file field missing"),
    },
  }
}

# Boundary parameter quoted per RFC 2046 §5.1.1 — `boundary="abc"`.
fn quoted_boundary_parses() -> Result[Unit, Str] {
  let c := ctx_with_body("multipart/form-data; boundary=\"BOUND\"", body_one_text("k", "v"))
  match mp.parse(c, default_limits()) {
    Ok(parts) => match mp.find_text(parts, "k") {
      Some(v) => if v == "v" {
        Ok(())
      } else {
        Err("value mismatch")
      },
      None => Err("k not found"),
    },
    Err(e) => Err(str.concat("quoted boundary parse failed: ", e.message)),
  }
}

# Find missing → None (not Err — caller decides how to react).
fn find_text_returns_none_for_missing() -> Result[Unit, Str] {
  let c := ctx_with_body(multipart_ctype(), body_one_text("a", "1"))
  match mp.parse(c, default_limits()) {
    Err(e) => Err(str.concat("parse failed: ", e.message)),
    Ok(parts) => match mp.find_text(parts, "b") {
      None => Ok(()),
      Some(_) => Err("expected None for missing field"),
    },
  }
}

# ---- Error paths -------------------------------------------------
fn missing_content_type_returns_error() -> Result[Unit, Str] {
  let c := ctx_no_ctype(body_one_text("a", "1"))
  match mp.parse(c, default_limits()) {
    Err(e) => if e.kind == "content-type" {
      Ok(())
    } else {
      Err(str.concat("expected kind=content-type, got: ", e.kind))
    },
    Ok(_) => Err("expected Err for missing content-type"),
  }
}

fn wrong_content_type_returns_error() -> Result[Unit, Str] {
  let c := ctx_with_body("application/json", body_one_text("a", "1"))
  match mp.parse(c, default_limits()) {
    Err(e) => if e.kind == "content-type" {
      Ok(())
    } else {
      Err(str.concat("expected kind=content-type, got: ", e.kind))
    },
    Ok(_) => Err("expected Err for JSON content-type"),
  }
}

# multipart/form-data WITHOUT a boundary parameter is invalid.
fn missing_boundary_returns_error() -> Result[Unit, Str] {
  let c := ctx_with_body("multipart/form-data", body_one_text("a", "1"))
  match mp.parse(c, default_limits()) {
    Err(e) => if e.kind == "content-type" or e.kind == "boundary" {
      Ok(())
    } else {
      Err(str.concat("expected kind=content-type or boundary, got: ", e.kind))
    },
    Ok(_) => Err("expected Err for missing boundary"),
  }
}

# Limits — body exceeds max_size.
fn body_exceeds_max_size_returns_error() -> Result[Unit, Str] {
  let big := str.concat(body_one_text("a", "1"), "padding-padding-padding-padding-padding")
  let limits := { max_parts: 8, max_size: 20 }
  let c := ctx_with_body(multipart_ctype(), big)
  match mp.parse(c, limits) {
    Err(e) => if e.kind == "limit" {
      Ok(())
    } else {
      Err(str.concat("expected kind=limit, got: ", e.kind))
    },
    Ok(_) => Err("expected Err for size limit"),
  }
}

# ---- Suite -------------------------------------------------------
fn suite() -> List[Result[Unit, Str]] {
  [single_text_field_parses(), single_file_field_parses(), mixed_text_and_file_parses(), quoted_boundary_parses(), find_text_returns_none_for_missing(), missing_content_type_returns_error(), wrong_content_type_returns_error(), missing_boundary_returns_error(), body_exceeds_max_size_returns_error()]
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

