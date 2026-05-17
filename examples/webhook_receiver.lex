# lex-web example — signed webhook receiver
#
# Production-shape pattern most SaaS integrations land on:
#
#   1. A `depends`-style verification chain checks a shared-secret
#      header *before* the route's body handler runs. Failed
#      verification returns 401 with a typed reason; never touches
#      the application code.
#   2. An idempotency-key check (X-Idempotency-Key) deduplicates
#      retries from at-least-once providers like Stripe / GitHub.
#      Already-seen keys return the original 202 without re-firing
#      the side effects.
#   3. The handler validates the payload against a Validator, queues
#      the side-effect work as a background.task, and returns 202
#      Accepted immediately so the provider doesn't time-out waiting
#      on a slow consumer.
#
# Wires together: depends (bind chained verifiers), exceptions
# (typed WebhookErr → 4xx mapping), background (post-202 side
# effects), status (HTTP_202_ACCEPTED), and lex-schema/problem
# (RFC 7807 envelope for validation failures).
#
# Run:
#   lex run --allow-effects io,net,time examples/webhook_receiver.lex main
#
# Try:
#   curl -X POST http://localhost:8080/webhooks/order \
#        -H 'content-type: application/json' \
#        -H 'x-webhook-secret: hush' \
#        -H 'x-idempotency-key: evt_001' \
#        -d '{"event":"order.created","order_id":"o_42","amount_cents":1999}'
#
#   # Replay the same key — same 202, side effect runs once.
#   # Bad secret:
#   curl -X POST http://localhost:8080/webhooks/order \
#        -H 'content-type: application/json' \
#        -H 'x-webhook-secret: wrong' \
#        -d '{}'

import "std.net" as net

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "../src/ctx" as ctx

import "../src/response" as resp

import "../src/router" as router

import "../src/middleware" as mw

import "../src/body" as body

import "../src/params" as params

import "../src/depends" as depends

import "../src/status" as status

import "../src/background" as bg

import "../src/exceptions" as exc

import "../src/docs" as docs

import "lex-schema/schema" as s

import "lex-schema/constraints" as c

import "lex-schema/validator" as v

# ---- Body validator -----------------------------------------------
fn webhook_validator() -> v.Validator {
  v.make({ title: "OrderWebhook", description: "Order lifecycle event", fields: [s.required_str("event", [StrPattern("^order\\.[a-z_]+$")]), s.required_str("order_id", [StrNonEmpty, StrMaxLen(64)]), s.required_int("amount_cents", [IntNonNegative])] })
}

# ---- Domain errors ------------------------------------------------
type WebhookErr = WhBadSecret | WhMissingIdempotencyKey | WhDuplicate(Str) | WhMissingHeader(Str)

fn configured_secret() -> Str {
  "hush"
}

fn verify_secret(c :: ctx.Ctx) -> Result[Unit, resp.Response] {
  match ctx.header(c, "x-webhook-secret") {
    None => Err(err_response(WhMissingHeader("x-webhook-secret"))),
    Some(s) => if s == configured_secret() {
      Ok(())
    } else {
      Err(err_response(WhBadSecret))
    },
  }
}

# ---- Dep: idempotency key + dedup --------------------------------
#
# Lex's pure-FP model means a process-wide seen-set lives in a
# Map[Str, Unit] we thread through closures (real apps would store
# in Redis / Postgres). For this example we keep it tiny and
# in-process — see the lex-orm pairing example for a persistent
# dedup table.
fn require_idempotency_key(c :: ctx.Ctx) -> Result[Str, resp.Response] {
  match params.header_str(c, "x-idempotency-key", None, [StrMinLen(1), StrMaxLen(128)]) {
    Err(r) => Err(r),
    Ok(key) => Ok(key),
  }
}

# In a real app `seen` would close over a thread-safe store. We
# pass it via the closure factory in `app()`.
fn check_not_duplicate(key :: Str, seen :: Map[Str, Unit]) -> Result[Unit, resp.Response] {
  match map.get(seen, key) {
    None => Ok(()),
    Some(_) => Err(err_response(WhDuplicate(key))),
  }
}

# ---- Exception registry ------------------------------------------
fn err_registry() -> exc.Registry[WebhookErr] {
  (((exc.new() |> fn (r :: exc.Registry[WebhookErr]) -> exc.Registry[WebhookErr] {
    exc.add(r, fn (e :: WebhookErr) -> Option[resp.Response] {
      match e {
        WhBadSecret => Some(resp.unauthorized("invalid x-webhook-secret")),
        _ => None,
      }
    })
  }) |> fn (r :: exc.Registry[WebhookErr]) -> exc.Registry[WebhookErr] {
    exc.add(r, fn (e :: WebhookErr) -> Option[resp.Response] {
      match e {
        WhMissingHeader(h) => Some(resp.bad_request(str.concat("missing header: ", h))),
        _ => None,
      }
    })
  }) |> fn (r :: exc.Registry[WebhookErr]) -> exc.Registry[WebhookErr] {
    exc.add(r, fn (e :: WebhookErr) -> Option[resp.Response] {
      match e {
        WhDuplicate(key) => Some(resp.json(str.concat("{\"status\":\"already_processed\",\"idempotency_key\":\"", str.concat(key, "\"}")))),
        _ => None,
      }
    })
  }) |> fn (r :: exc.Registry[WebhookErr]) -> exc.Registry[WebhookErr] {
    exc.with_fallback(r, fn (_e :: WebhookErr) -> resp.Response {
      resp.internal_error()
    })
  }
}

fn err_response(e :: WebhookErr) -> resp.Response {
  exc.handle(err_registry(), e)
}

# ---- Handler ------------------------------------------------------
# Compose the verification chain via depends.bind. Each step short-
# circuits to its typed response on failure; success threads through
# to the body handler.
fn handle_webhook(c :: ctx.Ctx, seen :: Map[Str, Unit]) -> resp.Response {
  match depends.bind(verify_secret(c), fn (_u :: Unit) -> Result[Str, resp.Response] {
    require_idempotency_key(c)
  }) {
    Err(r) => r,
    Ok(key) => match check_not_duplicate(key, seen) {
      Err(r) => r,
      Ok(_) => match body.require_json_body(c, webhook_validator()) {
        Err(r) => r,
        Ok(_payload) => accept_and_queue(key),
      },
    },
  }
}

# Return 202 immediately; queue the slow work as a background task
# so the provider doesn't time out on us.
fn accept_and_queue(key :: Str) -> resp.Response {
  let r := { body: str.concat("{\"status\":\"accepted\",\"idempotency_key\":\"", str.concat(key, "\"}")), status: status.HTTP_202_ACCEPTED(), headers: map.from_list([("content-type", "application/json")]) }
  bg.with_task(r, bg.task(str.concat("process-", key), fn () -> [io, time] Nil {
    io.print(str.concat("processed: ", key))
  })).response
}

# ---- Routing ------------------------------------------------------
fn app(seen :: Map[Str, Unit]) -> router.Router {
  (((((router.new() |> fn (r :: router.Router) -> router.Router {
    router.handler_json(r, "POST", "/webhooks/order", webhook_validator(), fn (c :: ctx.Ctx) -> resp.Response {
      handle_webhook(c, seen)
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.attach_meta(r, "POST", "/webhooks/order", { tags: ["webhooks"], summary: "Receive an order-lifecycle webhook", description: "Verifies x-webhook-secret, dedups on x-idempotency-key, queues processing, returns 202.", status: status.HTTP_202_ACCEPTED() })
  }) |> fn (r :: router.Router) -> router.Router {
    router.route(r, "GET", "/healthz", fn (_c :: ctx.Ctx) -> resp.Response {
      resp.json("{\"ok\":true}")
    })
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.body_limit(64000))
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.request_id())
  }) |> fn (r :: router.Router) -> router.Router {
    router.use_mw(r, mw.logger())
  }
}

# ---- Entry point --------------------------------------------------
fn main() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent] Unit {
  let __lex_discard_1 := io.print("webhook receiver on :8080")
  let __lex_discard_2 := io.print("  POST /webhooks/order  (needs x-webhook-secret + x-idempotency-key)")
  let __lex_discard_3 := io.print("  GET  /healthz")
  let seen := map.new()
  net.serve_fn(8080, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Response {
    let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
    let r := router.dispatch(app(seen), raw)
    { status: r.status, body: BodyStr(r.body), headers: r.headers }
  })
}

