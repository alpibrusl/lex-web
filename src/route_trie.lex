# lex-web — compiled route trie
#
# Replaces `find_match`'s O(N × M) list.fold over routes with a
# segment-keyed trie lookup that's O(M) in the path depth.
#
# Built once at app() time from the list of routes; consulted on
# every dispatch.
#
# Resolution order at each node, when multiple edges could match the
# next segment, is specificity-first:
#   1. literal segment (exact match)
#   2. `:param` segment (one bound name per node)
#   3. `*wildcard` (consumes the rest of the path)
#
# This is a behaviour change from the v0.2 `list.fold` dispatcher,
# which resolved purely in registration order: registering
# `GET /items/:id` *before* `GET /items/special` would route
# `/items/special` to `:id`. The trie picks `special` regardless of
# the registration order, matching the behaviour of Express,
# FastAPI, and Axum. Backtracking is supported, so a literal that
# leads to a dead-end (e.g. `/items/admin/*rest` registered, but
# request is `/items/admin/foo` and only `/items/:id/profile` is a
# valid continuation) falls back to `:param` / `*wildcard`.
#
# Effects: none. The trie is a pure value.
#
# ---- Generic over the handler payload (#GENERIC_ROW) --------------
#
# `TrieNode[h]` stores an arbitrary payload `h` at its terminal nodes
# — ordinary value-level polymorphism, the same kind `List[a]` already
# has, not effect-row polymorphism. This is what lets both the fixed
# `Router` (`H := HandlerBody`, unchanged below) and the new
# `GenericRouter[e]` (`H := (ctx.Ctx) -> [| e] resp.Response`, see
# router.lex) share one path-matching implementation. `compile` /
# `lookup` never look inside `h` — they just carry it — so making them
# generic changes nothing about what they compute; every existing
# caller keeps compiling with `h` inferred as `HandlerBody` from
# context, with no source change of its own.
#
# ---- HandlerBody — pure / effectful handler shape (fixed Router) --
#
# Route handlers, for the original fixed-row `Router`, come in three
# shapes:
#
#   HPure   ::  (Ctx) -> Response                            — registered via router.route
#   HEff    ::  (Ctx) -> [io, time, crypto, random, sql, fs_read,
#                         fs_write, net, concurrent] Response  — via router.route_effectful
#   HStream ::  (Ctx) -> [io, time, crypto, random, sql, fs_read,
#                         fs_write, net, concurrent] StreamResponse
#                         — via router.route_stream (#29). Always
#                         effectful — pure stream handlers are rare
#                         (typically pull from a queue / DB / clock)
#                         and the wide row lets the body narrow
#                         per the agent-guidelines.
#
# Each variant carries an `Option[v.Validator]` as a second positional
# field — the `response_model` from RouteMeta (#28). For `HStream`
# the response_model is currently NOT enforced (the body is a lazy
# iterator; we can't validate ahead-of-time without forcing it,
# which would defeat the streaming property). v1 stores the value
# for consistency / OpenAPI emit but treats it as a no-op at
# dispatch time. Same `None` semantics as HPure/HEff.
#
# Bundled into HandlerBody so the trie's `Map[Str, HandlerBody]` stays
# the single source of truth for dispatch — no parallel meta map and
# no second lookup on the hot path.
#
# `HandlerBody` itself stays a fixed, closed tagged union: `Router`'s
# whole raison d'être is offering three well-known, pre-set widths
# (pure / the wide effectful set / the wide streaming set) rather than
# asking every caller to pick one, and RouteMeta/OpenAPI/response_model
# are wired specifically to these three shapes. `dispatch` matches
# HPure/HEff (HStream → 500 with a hint); `dispatch_pure` honours only
# `HPure`; `dispatch_outcome` (#29) matches all three and returns a
# sum-typed result. The wide effect set on `HEff` / `HStream` is
# intentionally generous: narrow the handler *body*, not the type, per
# the lex agent-guidelines — or reach for `GenericRouter[e]` (router.lex)
# when the fixed set genuinely doesn't cover what a route needs.

type HandlerBody = HPure(((ctx.Ctx) -> resp.Response, Option[v.Validator])) | HEff(((ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response, Option[v.Validator])) | HStream(((ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] stream.StreamResponse, Option[v.Validator]))

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "lex-schema/validator" as v

import "./ctx" as ctx

import "./response" as resp

import "./stream" as stream

# A node in the route trie, generic over the handler payload `h`.
#
#   handlers  — routes that *terminate* at this node, keyed by method.
#               Empty for interior nodes (e.g. `/users` when only
#               `/users/:id` is registered).
#   literal   — `seg -> child node` for each literal segment edge.
#   param     — `(name, child node)` for the single `:name` edge,
#               if any. Each trie node carries at most one `:param`
#               edge: registering `/users/:id` and then
#               `/users/:name/profile` collapses to one edge under
#               the *first-registered* name (`id`). The two child
#               sub-trees are merged so both terminal handlers
#               survive — but handlers must agree on the param name,
#               since lookup binds to the first-registered name.
#               Register consistently or expect mis-keyed params.
#   wildcard  — `(name, method -> handler-record)` for `*rest`. Once
#               matched, the wildcard binds the rest of the path as
#               one joined string; no children needed.
type TrieNode[h] = { handlers :: Map[Str, h], literal :: Map[Str, TrieNode[h]], param :: Option[(Str, TrieNode[h])], wildcard :: Option[(Str, Map[Str, h])] }

fn empty_node[h]() -> TrieNode[h] {
  { handlers: map.new(), literal: map.new(), param: None, wildcard: None }
}

# Insert one route into the trie.
#
# `segs` is the route pattern split on '/' (e.g. `/users/:id` ->
# ["users", ":id"]). The handler is stored at the terminal node
# under the method key.
fn insert[h](t :: TrieNode[h], method :: Str, segs :: List[Str], body :: h) -> TrieNode[h] {
  match list.head(segs) {
    None => {
      { handlers: map.set(t.handlers, method, body), literal: t.literal, param: t.param, wildcard: t.wildcard }
    },
    Some(seg) => {
      let rest := list.tail(segs)
      if str.starts_with(seg, "*") {
        let name := str.slice(seg, 1, str.len(seg))
        let cur_handlers := match t.wildcard {
          None => map.new(),
          Some(pair_v) => match pair_v {
            (_, hs) => hs,
          },
        }
        { handlers: t.handlers, literal: t.literal, param: t.param, wildcard: Some((name, map.set(cur_handlers, method, body))) }
      } else {
        if str.starts_with(seg, ":") {
          let name_new := str.slice(seg, 1, str.len(seg))
          let pair_next := match t.param {
            None => (name_new, insert(empty_node(), method, rest, body)),
            Some(prev) => match prev {
              (name_old, c) => (name_old, insert(c, method, rest, body)),
            },
          }
          { handlers: t.handlers, literal: t.literal, param: Some(pair_next), wildcard: t.wildcard }
        } else {
          let child := match map.get(t.literal, seg) {
            None => empty_node(),
            Some(c) => c,
          }
          { handlers: t.handlers, literal: map.set(t.literal, seg, insert(child, method, rest, body)), param: t.param, wildcard: t.wildcard }
        }
      }
    },
  }
}

# Public: build the trie from a list of (method, segments, body) triples.
fn compile[h](triples :: List[(Str, List[Str], h)]) -> TrieNode[h] {
  list.fold(triples, empty_node(), fn (t :: TrieNode[h], triple :: (Str, List[Str], h)) -> TrieNode[h] {
    match triple {
      (method, segs, body) => insert(t, method, segs, body),
    }
  })
}

# Public: lookup a request path. Returns the matched handler body +
# the bound params, or None if no route matched.
#
# Resolution order at each node: literal first (Map.get O(log n)),
# then param (single edge), then wildcard (terminates).
fn lookup[h](t :: TrieNode[h], method :: Str, segs :: List[Str]) -> Option[(h, Map[Str, Str])] {
  lookup_inner(t, method, segs, map.new())
}

fn lookup_inner[h](t :: TrieNode[h], method :: Str, segs :: List[Str], params :: Map[Str, Str]) -> Option[(h, Map[Str, Str])] {
  match list.head(segs) {
    None => {
      match map.get(t.handlers, method) {
        Some(b) => Some((b, params)),
        None => None,
      }
    },
    Some(seg) => {
      let rest := list.tail(segs)
      match map.get(t.literal, seg) {
        Some(child) => {
          match lookup_inner(child, method, rest, params) {
            Some(hit) => Some(hit),
            None => try_param_then_wildcard(t, method, seg, segs, rest, params),
          }
        },
        None => try_param_then_wildcard(t, method, seg, segs, rest, params),
      }
    },
  }
}

# Fallback chain: try the :param edge, then the *wildcard edge.
# Pulled out of lookup_inner to keep the literal-match arm flat.
fn try_param_then_wildcard[h](t :: TrieNode[h], method :: Str, seg :: Str, all_segs :: List[Str], rest :: List[Str], params :: Map[Str, Str]) -> Option[(h, Map[Str, Str])] {
  match t.param {
    Some(pair_v) => {
      match pair_v {
        (name, child) => {
          let bound := map.set(params, name, seg)
          match lookup_inner(child, method, rest, bound) {
            Some(hit) => Some(hit),
            None => try_wildcard(t, method, all_segs, params),
          }
        },
      }
    },
    None => try_wildcard(t, method, all_segs, params),
  }
}

fn try_wildcard[h](t :: TrieNode[h], method :: Str, segs :: List[Str], params :: Map[Str, Str]) -> Option[(h, Map[Str, Str])] {
  match t.wildcard {
    None => None,
    Some(pair_v) => {
      match pair_v {
        (name, hmap) => {
          match map.get(hmap, method) {
            None => None,
            Some(b) => {
              let bound := map.set(params, name, str.join(segs, "/"))
              Some((b, bound))
            },
          }
        },
      }
    },
  }
}

