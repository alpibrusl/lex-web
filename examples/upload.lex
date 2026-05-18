# examples/upload.lex — multipart/form-data uploads (#25)
#
# Demonstrates `multipart.parse` + `multipart.find_file` /
# `multipart.find_text`:
#
#   POST /upload  with body  --boundary
#                            Content-Disposition: form-data; name="title"
#                            ...
#                            --boundary
#                            Content-Disposition: form-data; name="file"; filename="x.txt"
#                            Content-Type: text/plain
#                            ...
#                            --boundary--
#
# Returns JSON describing the parsed parts.
#
# Note: lex-web's request body is `Str`, decoded as lossy UTF-8 by
# the runtime. Truly-binary uploads (most images / archives) lose
# data at the framework boundary. Text-file uploads (.txt, .csv,
# .json, source) round-trip cleanly. See src/multipart.lex docs.
#
# Run:
#   lex run --allow-effects io,net,time,crypto,random,sql,fs_read,fs_write,concurrent \
#           examples/upload.lex main
#
# Try:
#   curl -i -F 'title=greeting' -F 'file=@/etc/hostname' http://localhost:8083/upload

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/multipart" as mp

fn upload_limits() -> mp.Limits {
  { max_parts: 16, max_size: 5000000 }
}

fn handle_upload(c :: ctx.Ctx) -> resp.Response {
  match mp.parse(c, upload_limits()) {
    Err(e) => resp.bad_request(str.concat("multipart: ", e.message)),
    Ok(parts) => {
      let title := match mp.find_text(parts, "title") {
        Some(v) => v,
        None => "(no title)",
      }
      match mp.find_file(parts, "file") {
        None => resp.bad_request("file field required"),
        Some(f) => resp.json(str.concat("{\"title\":\"", str.concat(title, str.concat("\",\"filename\":\"", str.concat(f.filename, str.concat("\",\"content_type\":\"", str.concat(f.content_type, str.concat("\",\"size\":", str.concat(int.to_str(str.len(f.body)), "}"))))))))),
      }
    },
  }
}

fn app() -> router.Router {
  router.new() |> fn (r :: router.Router) -> router.Router {
    router.route(r, "POST", "/upload", handle_upload)
  }
}

fn handle(req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
  let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
  let r := router.dispatch(app(), raw)
  { status: r.status, body: BodyStr(r.body), headers: r.headers }
}

fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Unit {
  let __lex_discard_1 := io.print("upload demo on :8083")
  let __lex_discard_2 := io.print("  curl -F 'title=greeting' -F 'file=@/etc/hostname' http://localhost:8083/upload")
  net.serve_fn(8083, handle)
}

