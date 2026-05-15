# lex-web — compiled route trie
#
# Replaces `find_match`'s O(N × M) list.fold over routes with a
# segment-keyed trie lookup that's O(M) in the path depth.
#
# Built once at app() time from the list of routes; consulted on
# every dispatch.
#
# Resolution order at each node, when multiple edges could match the
# next segment, matches the historical list.fold semantics:
#   1. literal segment (exact match) — registered first wins
#   2. `:param` segment (one bound name per node)
#   3. `*wildcard` (consumes the rest of the path)
#
# Effects: none. The trie is a pure value.

import "std.str"  as str
import "std.list" as list
import "std.map"  as map

import "./ctx"      as ctx
import "./response" as resp

# A node in the route trie.
#
#   handlers  — routes that *terminate* at this node, keyed by method.
#               Empty for interior nodes (e.g. `/users` when only
#               `/users/:id` is registered).
#   literal   — `seg -> child node` for each literal segment edge.
#   param     — `(name, child node)` for the single `:name` edge,
#               if any. The framework refuses to register two
#               `:param` patterns on the same prefix (last one wins,
#               matching the list.fold behaviour for the param edge).
#   wildcard  — `(name, method -> handler-record)` for `*rest`. Once
#               matched, the wildcard binds the rest of the path as
#               one joined string; no children needed.
type TrieNode = {
  handlers :: Map[Str, (ctx.Ctx) -> resp.Response],
  literal  :: Map[Str, TrieNode],
  param    :: Option[(Str, TrieNode)],
  wildcard :: Option[(Str, Map[Str, (ctx.Ctx) -> resp.Response])],
}

fn empty_node() -> TrieNode {
  {
    handlers: map.new(),
    literal:  map.new(),
    param:    None,
    wildcard: None,
  }
}

# Insert one route into the trie.
#
# `segs` is the route pattern split on '/' (e.g. `/users/:id` ->
# ["users", ":id"]). The handler is stored at the terminal node
# under the method key.
fn insert(
  t       :: TrieNode,
  method  :: Str,
  segs    :: List[Str],
  handler :: (ctx.Ctx) -> resp.Response
) -> TrieNode {
  match list.head(segs) {
    None => {
      # Terminal — store the handler at this node.
      {
        handlers: map.set(t.handlers, method, handler),
        literal:  t.literal,
        param:    t.param,
        wildcard: t.wildcard,
      }
    },
    Some(seg) => {
      let rest := list.tail(segs)
      if str.starts_with(seg, "*") {
        let name := str.slice(seg, 1, str.len(seg))
        let cur_handlers := match t.wildcard {
          None         => map.new(),
          Some(pair_v) => match pair_v { (_, hs) => hs },
        }
        {
          handlers: t.handlers,
          literal:  t.literal,
          param:    t.param,
          wildcard: Some((name, map.set(cur_handlers, method, handler))),
        }
      } else {
        if str.starts_with(seg, ":") {
          let name := str.slice(seg, 1, str.len(seg))
          let child := match t.param {
            None       => empty_node(),
            Some(pair) => match pair { (_, c) => c },
          }
          {
            handlers: t.handlers,
            literal:  t.literal,
            param:    Some((name, insert(child, method, rest, handler))),
            wildcard: t.wildcard,
          }
        } else {
          let child := match map.get(t.literal, seg) {
            None    => empty_node(),
            Some(c) => c,
          }
          {
            handlers: t.handlers,
            literal:  map.set(t.literal, seg, insert(child, method, rest, handler)),
            param:    t.param,
            wildcard: t.wildcard,
          }
        }
      }
    },
  }
}

# Public: build the trie from a list of (method, segments, handler) triples.
fn compile(
  triples :: List[(Str, List[Str], (ctx.Ctx) -> resp.Response)]
) -> TrieNode {
  list.fold(triples, empty_node(),
    fn (t :: TrieNode, triple :: (Str, List[Str], (ctx.Ctx) -> resp.Response)) -> TrieNode {
      match triple {
        (method, segs, h) => insert(t, method, segs, h),
      }
    })
}

# Public: lookup a request path. Returns the matched handler + the
# bound params, or None if no route matched.
#
# Resolution order at each node: literal first (Map.get O(log n)),
# then param (single edge), then wildcard (terminates).
fn lookup(
  t       :: TrieNode,
  method  :: Str,
  segs    :: List[Str]
) -> Option[((ctx.Ctx) -> resp.Response, Map[Str, Str])] {
  lookup_inner(t, method, segs, map.new())
}

fn lookup_inner(
  t       :: TrieNode,
  method  :: Str,
  segs    :: List[Str],
  params  :: Map[Str, Str]
) -> Option[((ctx.Ctx) -> resp.Response, Map[Str, Str])] {
  match list.head(segs) {
    None => {
      # Path consumed — look up handler for this method at this node.
      match map.get(t.handlers, method) {
        Some(h) => Some((h, params)),
        None    => None,
      }
    },
    Some(seg) => {
      let rest := list.tail(segs)
      # Try literal first.
      match map.get(t.literal, seg) {
        Some(child) => {
          match lookup_inner(child, method, rest, params) {
            Some(hit) => Some(hit),
            None      => try_param_then_wildcard(t, method, seg, segs, rest, params),
          }
        },
        None => try_param_then_wildcard(t, method, seg, segs, rest, params),
      }
    },
  }
}

# Fallback chain: try the :param edge, then the *wildcard edge.
# Pulled out of lookup_inner to keep the literal-match arm flat.
fn try_param_then_wildcard(
  t        :: TrieNode,
  method   :: Str,
  seg      :: Str,
  all_segs :: List[Str],
  rest     :: List[Str],
  params   :: Map[Str, Str]
) -> Option[((ctx.Ctx) -> resp.Response, Map[Str, Str])] {
  match t.param {
    Some(pair_v) => {
      match pair_v {
        (name, child) => {
          let bound := map.set(params, name, seg)
          match lookup_inner(child, method, rest, bound) {
            Some(hit) => Some(hit),
            None      => try_wildcard(t, method, all_segs, params),
          }
        },
      }
    },
    None => try_wildcard(t, method, all_segs, params),
  }
}

fn try_wildcard(
  t       :: TrieNode,
  method  :: Str,
  segs    :: List[Str],
  params  :: Map[Str, Str]
) -> Option[((ctx.Ctx) -> resp.Response, Map[Str, Str])] {
  match t.wildcard {
    None => None,
    Some(pair_v) => {
      match pair_v {
        (name, hmap) => {
          match map.get(hmap, method) {
            None    => None,
            Some(h) => {
              let bound := map.set(params, name, str.join(segs, "/"))
              Some((h, bound))
            },
          }
        },
      }
    },
  }
}
