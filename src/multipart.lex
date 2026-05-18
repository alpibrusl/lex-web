# lex-web — multipart/form-data parsing (#25)
#
# RFC 7578 parser for `Content-Type: multipart/form-data;
# boundary=...`-encoded request bodies. Produces a list of typed
# parts so handlers can pick out file uploads and text fields by
# name without hand-rolling boundary detection.
#
# Pattern:
#
#   match multipart.parse(c, { max_parts: 16, max_size: 5_000_000 }) {
#     Err(e)    => resp.bad_request(e.message),
#     Ok(parts) => match multipart.find_file(parts, "avatar") {
#       None       => resp.bad_request("avatar field required"),
#       Some(file) => save_avatar(file.content_type, file.body),
#     },
#   }
#
# ## Scope (v1)
#
# - Text fields and file fields per the standard
#   `Content-Disposition: form-data; name="..."[; filename="..."]`
#   convention. Presence of `filename=` makes a part a FileField.
# - Per-part `Content-Type` (defaults to "text/plain" when missing).
# - `max_parts` and `max_size` caps. Both rejected as bad-request.
# - Eager parse — the whole body is in memory already (lex-web's
#   Request.body is Str). Streaming variants are a follow-up once
#   the underlying request body type widens to Bytes.
#
# ## Limits
#
# - The request body is `Str`, not `Bytes`, on the lex-lang side.
#   The runtime decodes non-UTF-8 bytes as U+FFFD; truly-binary
#   uploads (most images, archives, PDFs) lose data at the
#   framework boundary, not in this parser. Text-file uploads
#   (.txt, .csv, .json, .lex source) round-trip cleanly. A
#   Bytes-body upstream change is tracked separately.
# - RFC 5987 extended parameters (`filename*=UTF-8''...`) are not
#   honoured; plain `filename="..."` only. Non-ASCII filenames
#   land as their UTF-8 bytes, which is what most browsers send
#   anyway.
#
# Effects: none. Parsing is a pure transform.
#
# Issue: lex-web#25.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "./ctx" as ctx

# ---- Public types ------------------------------------------------
# A file upload. `filename` is the client-supplied basename (may be
# absent / empty; never trust it for filesystem operations). `body`
# is the raw form-data body as Str — see the "Limits" docstring
# section above for the binary-data caveat.
type FileField = { name :: Str, filename :: Str, content_type :: Str, body :: Str }

# A non-file form value. RFC 7578 form-data field with no
# `filename=` parameter.
type TextField = { name :: Str, value :: Str }

# One decoded part. `find_file` and `find_text` filter by name.
type MultipartPart = FilePart(FileField) | TextPart(TextField)

type Limits = { max_parts :: Int, max_size :: Int }

# Decode error. `message` is human-readable; `kind` is a tag for
# programmatic handling (return different status codes per error
# class, log differently, etc.).
type MultipartError = { kind :: Str, message :: Str }

# ---- Parsing -----------------------------------------------------
# Parse the request body as multipart/form-data. Returns the list
# of parts in document order, or a structured error on:
#   - Wrong / missing Content-Type            (kind = "content-type")
#   - Missing or malformed boundary parameter (kind = "boundary")
#   - Body exceeds limits                     (kind = "limit")
#   - Malformed part (no headers / etc.)      (kind = "part")
fn parse(c :: ctx.Ctx, limits :: Limits) -> Result[List[MultipartPart], MultipartError] {
  let ct := ctx.header_or(c, "content-type", "")
  let body := c.body
  if str.len(body) > limits.max_size {
    Err({ kind: "limit", message: "request body exceeds max_size" })
  } else {
    match extract_boundary(ct) {
      None => Err({ kind: "content-type", message: "content-type is not multipart/form-data with a boundary" }),
      Some(boundary) => {
        let raw_parts := split_on_boundary(body, boundary)
        if list.len(raw_parts) > limits.max_parts {
          Err({ kind: "limit", message: "request exceeds max_parts" })
        } else {
          decode_parts(raw_parts)
        }
      },
    }
  }
}

# Find the first FilePart with the given form-data name. Useful
# right after `parse`: `match find_file(parts, "avatar") { ... }`.
fn find_file(parts :: List[MultipartPart], name :: Str) -> Option[FileField] {
  list.fold(parts, None, fn (acc :: Option[FileField], p :: MultipartPart) -> Option[FileField] {
    match acc {
      Some(_) => acc,
      None => match p {
        FilePart(f) => if f.name == name {
          Some(f)
        } else {
          None
        },
        TextPart(_) => None,
      },
    }
  })
}

# Find the first TextPart with the given name and return its value.
# Mirrors `find_file` for non-file form fields.
fn find_text(parts :: List[MultipartPart], name :: Str) -> Option[Str] {
  list.fold(parts, None, fn (acc :: Option[Str], p :: MultipartPart) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None => match p {
        TextPart(t) => if t.name == name {
          Some(t.value)
        } else {
          None
        },
        FilePart(_) => None,
      },
    }
  })
}

# ---- Internals ---------------------------------------------------
# Pull the `boundary=...` parameter out of a Content-Type header.
# Honours both unquoted (`boundary=abc123`) and quoted
# (`boundary="abc 123"`) per RFC 2046 §5.1.1. Returns None for
# headers that aren't multipart/form-data at all.
fn extract_boundary(ct :: Str) -> Option[Str] {
  let lower := str.to_lower(ct)
  if str.contains(lower, "multipart/form-data") {
    let needle := "boundary="
    let lower_idx := find_substring(lower, needle)
    if lower_idx < 0 {
      None
    } else {
      let start := lower_idx + str.len(needle)
      let raw := str.slice(ct, start, str.len(ct))
      Some(unquote(strip_after_semicolon(raw)))
    }
  } else {
    None
  }
}

# Strip any trailing `; otherparam=...` — boundary values
# themselves don't contain `;` per RFC 2046.
fn strip_after_semicolon(s :: Str) -> Str {
  let idx := find_substring(s, ";")
  if idx < 0 {
    s
  } else {
    str.slice(s, 0, idx)
  }
}

# Drop surrounding double-quotes if present. Boundary values can
# be quoted to carry whitespace per RFC 2046 §5.1.1.
fn unquote(s :: Str) -> Str {
  let t := str.trim(s)
  let n := str.len(t)
  if n >= 2 and str.slice(t, 0, 1) == "\"" and str.slice(t, n - 1, n) == "\"" {
    str.slice(t, 1, n - 1)
  } else {
    t
  }
}

# Index-of for substring; returns -1 if absent. str.split splits
# on every occurrence; we just want the first, and the position
# of it. Hand-roll via a slice-comparison loop.
fn find_substring(haystack :: Str, needle :: Str) -> Int {
  let nh := str.len(haystack)
  let nn := str.len(needle)
  if nn == 0 {
    0
  } else {
    find_substring_at(haystack, needle, 0, nh, nn)
  }
}

fn find_substring_at(haystack :: Str, needle :: Str, i :: Int, nh :: Int, nn :: Int) -> Int {
  if i + nn > nh {
    -1
  } else {
    if str.slice(haystack, i, i + nn) == needle {
      i
    } else {
      find_substring_at(haystack, needle, i + 1, nh, nn)
    }
  }
}

# Split a body on `--<boundary>` lines per RFC 7578. The leading
# `--` is part of the delimiter; the trailing `--` (close-delimiter)
# signals end-of-body and we drop everything after it. Each
# returned chunk is the raw bytes between two boundary lines —
# still including the leading CRLF and the per-part headers.
fn split_on_boundary(body :: Str, boundary :: Str) -> List[Str] {
  let delim := str.concat("--", boundary)
  let pieces := str.split(body, delim)
  let total := list.len(pieces)
  if total <= 2 {
    []
  } else {
    list.fold(pieces, ([], 0), fn (acc :: (List[Str], Int), p :: Str) -> (List[Str], Int) {
      match acc {
        (out, i) => if i == 0 or i >= total - 1 {
          (out, i + 1)
        } else {
          (list.concat(out, [strip_crlf_edges(p)]), i + 1)
        },
      }
    }) |> fn (acc :: (List[Str], Int)) -> List[Str] {
      match acc {
        (out, _) => out,
      }
    }
  }
}

# Strip the leading CRLF that follows the boundary line and the
# trailing CRLF that precedes the next boundary line.
fn strip_crlf_edges(s :: Str) -> Str {
  let n := str.len(s)
  let after_lead := if n >= 2 and str.slice(s, 0, 2) == "\r\n" {
    str.slice(s, 2, n)
  } else {
    s
  }
  let m := str.len(after_lead)
  if m >= 2 and str.slice(after_lead, m - 2, m) == "\r\n" {
    str.slice(after_lead, 0, m - 2)
  } else {
    after_lead
  }
}

# Walk the decoded chunks, splitting each into header block +
# body and decoding the Content-Disposition. Returns the first
# error encountered, or the full list on success.
fn decode_parts(raw_parts :: List[Str]) -> Result[List[MultipartPart], MultipartError] {
  list.fold(raw_parts, Ok([]), fn (acc :: Result[List[MultipartPart], MultipartError], raw :: Str) -> Result[List[MultipartPart], MultipartError] {
    match acc {
      Err(_) => acc,
      Ok(parts) => match decode_one_part(raw) {
        Err(e) => Err(e),
        Ok(p) => Ok(list.concat(parts, [p])),
      },
    }
  })
}

fn decode_one_part(raw :: Str) -> Result[MultipartPart, MultipartError] {
  let sep_idx := find_substring(raw, "\r\n\r\n")
  if sep_idx < 0 {
    Err({ kind: "part", message: "part missing header/body separator" })
  } else {
    let head := str.slice(raw, 0, sep_idx)
    let body := str.slice(raw, sep_idx + 4, str.len(raw))
    let headers := parse_part_headers(head)
    let disp := map.get(headers, "content-disposition")
    let ctype := match map.get(headers, "content-type") {
      Some(v) => v,
      None => "text/plain",
    }
    match disp {
      None => Err({ kind: "part", message: "part missing Content-Disposition" }),
      Some(d) => match parse_disposition(d) {
        None => Err({ kind: "part", message: "part Content-Disposition has no name" }),
        Some(np) => match np {
          (name, filename_opt) => match filename_opt {
            None => Ok(TextPart({ name: name, value: body })),
            Some(filename) => Ok(FilePart({ name: name, filename: filename, content_type: ctype, body: body })),
          },
        },
      },
    }
  }
}

fn parse_part_headers(head :: Str) -> Map[Str, Str] {
  list.fold(str.split(head, "\r\n"), map.new(), fn (m :: Map[Str, Str], line :: Str) -> Map[Str, Str] {
    let idx := find_substring(line, ":")
    if idx < 0 {
      m
    } else {
      let key := str.to_lower(str.trim(str.slice(line, 0, idx)))
      let val := str.trim(str.slice(line, idx + 1, str.len(line)))
      map.set(m, key, val)
    }
  })
}

# Parse `form-data; name="x"; filename="y"` into `(name, Option(filename))`.
# Other parameters are ignored. None if `name=` is absent.
fn parse_disposition(d :: Str) -> Option[(Str, Option[Str])] {
  let lower := str.to_lower(d)
  if str.contains(lower, "form-data") {
    let name := extract_quoted_param(d, "name=")
    let filename := extract_quoted_param(d, "filename=")
    match name {
      "" => None,
      n => Some((n, match filename {
        "" => None,
        f => Some(f),
      })),
    }
  } else {
    None
  }
}

# Extract `<param>"value"` or `<param>value` (up to ; or end of
# string). Returns "" if absent. Hand-rolled to avoid a regex dep
# for a single shape.
fn extract_quoted_param(s :: Str, prefix :: Str) -> Str {
  let idx := find_substring(s, prefix)
  if idx < 0 {
    ""
  } else {
    let after := str.slice(s, idx + str.len(prefix), str.len(s))
    if str.len(after) > 0 and str.slice(after, 0, 1) == "\"" {
      let rest := str.slice(after, 1, str.len(after))
      let end := find_substring(rest, "\"")
      if end < 0 {
        rest
      } else {
        str.slice(rest, 0, end)
      }
    } else {
      let end := find_substring(after, ";")
      if end < 0 {
        str.trim(after)
      } else {
        str.trim(str.slice(after, 0, end))
      }
    }
  }
}

