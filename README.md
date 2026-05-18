# lex-web

HTTP framework for the [Lex language](https://github.com/alpibrusl/lex-lang),
built on [lex-schema](https://github.com/alpibrusl/lex-schema) for request
validation. Designed as a FastAPI-style toolkit for Lex: typed parameters,
declarative routes, dependency injection, OpenAPI 3.1 export, Swagger UI,
sub-routers, lifespan hooks, background tasks, and an effect-aware testing
surface.

Requires **lex-lang 0.9.0+** (native `net.serve_fn` closure handlers, the
`Response` record, `net.serve_ws_fn`). 0.9.1 is recommended for the `lex test`
runner, `lex fmt`, and `Iter[T]` lazy streaming.

## Modules

| Module | Purpose |
|--------|---------|
| `src/ctx.lex`           | `Ctx` — enriched request context (path params, query, headers, cookies) |
| `src/response.lex`      | Response builders (`json`, `text`, `html`, `created`, `not_found`, `problem`, …) |
| `src/router.lex`        | Route table + dispatcher; `RouteMeta` for tags / summary / status / `response_model` (#28); `attach_meta`, `route_with_meta`, `with_response_model` |
| `src/middleware.lex`    | `MwCors` (with OPTIONS preflight), `MwBodyLimit`, `MwRequestId`, `MwLogger`, `MwGzip`, `MwTrustedHost`, `MwCustom` (user-defined hooks — #27) |
| `src/body.lex`          | `json_body`, `require_json_body`, `form_body`, `form_body_raw`, `raw_body` |
| `src/openapi.lex`       | Auto-generates OpenAPI 3.1 — tags, summaries, descriptions, operationIds, per-route success status |
| `src/ws.lex`            | WebSocket server — `serve()`, path helpers, frame helpers |
| `src/testing.lex`       | Pure test helpers: request builders + `assert_*` assertions |
| `src/test_fixtures.lex` | Sample validators for use in tests and examples |
| `src/web.lex`           | Facade that groups all modules under one import |
| **FastAPI parity (v0.2)** | |
| `src/status.lex`        | `HTTP_*` named status constants + `is_success` / `is_error` predicates |
| `src/params.lex`        | Typed query / path / header extractors with constraints (FastAPI's `Query`/`Path`/`Header`) |
| `src/depends.lex`       | `inject1`..`inject4`, `bind`, `map`, `pure` for dependency-injection composition |
| `src/sub_router.lex`    | `SubRouter` — APIRouter equivalent with prefix + tags + per-route metadata |
| `src/lifespan.lex`      | Startup / shutdown hook lists (FastAPI's `lifespan`) |
| `src/background.lex`    | `BackgroundTask` + `Reply` for post-response work |
| `src/docs.lex`          | Swagger UI / ReDoc HTML pages, auto-mountable at `/docs` and `/redoc` |
| `src/static_files.lex`  | In-memory bundle (`mount_map`) and filesystem (`mount_dir`) static serving |
| `src/exceptions.lex`    | Typed-error registry (FastAPI's `exception_handler`) |
| `src/serve.lex`         | `serve` / `serve_with` / `serve_quic` — wrap `net.serve_*` with router dispatch; HTTP/1.1, HTTP/2, HTTP/3 entry points |

## Example applications

The `examples/` directory carries runnable apps that exercise the framework
end-to-end. Each shows a different slice of the surface — pick the one
closest to what you're building.

| File | What it builds | Modules exercised |
|------|----------------|-------------------|
| `users_api.lex` | Smallest possible Users CRUD | `router`, `body`, `middleware`, `openapi` |
| `fastapi_style.lex` | Items API touching every new v0.2 module | every FastAPI-parity module |
| `with_lex_orm.lex` | Items API persisted via lex-orm (SQLite) | `+ lex-orm/connection`, `query`, `migrate` |
| `url_shortener.lex` | POST /api/links + 302 redirects + click stats + Swagger UI | `sub_router`, `params`, `exceptions`, `background`, `docs`, `lifespan` |
| `jsonrpc_ws.lex` | JSON-RPC 2.0 over WebSocket on `:9000`, browser console on `:8080` | `ws`, `router`, lex-schema `json_value` |
| `webhook_receiver.lex` | Signed webhook ingestion with idempotency dedup + background processing | `depends.bind`, `exceptions`, `background`, `params.header_str`, RFC 7807 |
| `middleware_custom.lex` | Bearer-token gate + response-stamping via `mw.custom` | `middleware.custom` (#27) |

Run any of them with `lex run --allow-effects io,net,time examples/<file> main`
(some need additional effects — each file's header comment carries the exact
invocation).

## Quick start

```lex
import "../src/ctx"      as ctx
import "../src/response" as resp
import "../src/router"   as router

fn greet(c :: ctx.Ctx) -> resp.Response {
  match ctx.path_param(c, "name") {
    None       => resp.bad_request("missing name"),
    Some(name) => resp.json(str.concat("{\"hello\":\"", str.concat(name, "\"}"))),
  }
}

fn app() -> router.Router {
  router.new()
    |> fn (r :: router.Router) -> router.Router {
         router.route(r, "GET", "/greet/:name", greet)
       }
}

fn handle(req :: ctx.RawRequest) -> [io, time] resp.Response {
  router.dispatch(app(), req)
}

fn main() -> [net, io, time] Nil {
  net.serve_fn(8080, handle)
}
```

`src/serve.lex` exposes the lex-lang listener entry points under a single
namespace (the same way `src/ws.lex` groups WebSocket entry points). It's a
thin passthrough — callers still write the `fn handle(req) { router.dispatch(app(), req) }`
boilerplate the existing examples use:

```lex
import "../src/serve" as web_serve

fn handle(req :: ctx.RawRequest) -> [io, time] resp.Response {
  router.dispatch(app(), req)
}

fn main() -> [net, io, time] Nil {
  web_serve.serve(8080, handle)
}
```

## HTTP/2 and HTTP/3 (requires lex-lang 0.9.6+)

`serve.lex`'s `serve_with` and `serve_quic` wrap
[lex-lang#497](https://github.com/alpibrusl/lex-lang/pull/499) (`net.serve_fn_with`)
and [lex-lang#496](https://github.com/alpibrusl/lex-lang/pull/501) (`net.serve_quic_fn`).

HTTP/2 over the same TCP listener (preface-detected, falls back to HTTP/1.1):

```lex
import "../src/serve" as web_serve

fn handle(req :: ctx.RawRequest) -> [io, time] resp.Response {
  router.dispatch(app(), req)
}

fn main() -> [net, io, time] Nil {
  let opts := { http2: true, inline_vm: false, host: "0.0.0.0" }
  web_serve.serve_with(8080, handle, opts)
}
```

HTTP/3 over QUIC (UDP). Mandatory TLS — pair with `std.tls`:

```lex
import "../src/serve" as web_serve
import "std.tls"      as tls

fn handle(req :: ctx.RawRequest) -> [io, time] resp.Response {
  router.dispatch(app(), req)
}

fn main() -> [net, io, time] Nil {
  match tls.self_signed("localhost") {
    Ok(t)  => web_serve.serve_quic(4433, t, handle),
    Err(_) => (),
  }
}
```

Production deployments use a CA-signed cert via `tls.from_pem_files(cert, key)`
and typically pair a TCP listener on `:443` (HTTP/1.1 + 2) with a UDP listener
on `:443` (HTTP/3) for client transport negotiation.

The QUIC path requires the `lex` binary to be built with `cargo build --release --features quic` — the default release omits it to keep the dep graph
slim. Without the feature, `serve_quic` returns a clear "compiled without
quic" error at startup.

## Persistence — pairs with lex-orm

[lex-orm](https://github.com/alpibrusl/lex-orm) (a typed query builder +
migration runner on top of `std.sql`) shares lex-schema with lex-web — the
same `ModelSchema` value drives request validation **and** the persisted table
shape. The end-to-end pairing demo lives in `examples/with_lex_orm.lex`:

```lex
fn item_schema() -> s.ModelSchema {
  { title: "items", description: "",
    fields: [
      s.required_int("id",   []),
      s.required_str("name", [StrNonEmpty, StrMaxLen(64)]),
      s.required_int("qty",  [IntPositive]),
    ] }
}

fn list_items(c :: ctx.Ctx) -> [sql] resp.Response {
  let plan := q.paginate(q.select(item_repo()), 1, 20)
  match q.run_select(plan, db) {
    Err(_)    => resp.internal_error(),
    Ok(items) => resp.json(serialize(items)),
  }
}
```

`run_select` carries the `[sql]` effect; the dispatcher propagates it through
to `main`. lex-orm v0.1+ runs against real `std.sql` (Postgres + SQLite) since
[#4](https://github.com/alpibrusl/lex-orm/pull/4) landed.

## FastAPI parity

The end-to-end demo lives in `examples/fastapi_style.lex`. The pieces:

### Sub-routers (`APIRouter` equivalent)

```lex
fn items() -> sub_router.SubRouter {
  sub_router.new("/items", ["items"])
    |> fn (r :: sub_router.SubRouter) -> sub_router.SubRouter {
         sub_router.route(r, "GET", "/", list_items)
       }
    |> fn (r :: sub_router.SubRouter) -> sub_router.SubRouter {
         sub_router.with_summary(r, "List items, paginated")
       }
    |> fn (r :: sub_router.SubRouter) -> sub_router.SubRouter {
         sub_router.handler_json(r, "POST", "/", v_item, create_item)
       }
    |> fn (r :: sub_router.SubRouter) -> sub_router.SubRouter {
         sub_router.with_status(r, status.HTTP_201_CREATED())
       }
}

fn app() -> router.Router {
  sub_router.mount(router.new(), items())
}
```

### Typed query / path parameters

Bad input becomes a 422 `problem+json` response automatically — exactly what
FastAPI does:

```lex
match params.query_int(c, "page", Some(1), [IntPositive]) {
  Err(r)    => r,
  Ok(page)  => resp.json(...),
}
```

`params` ships `query_str`, `query_int`, `query_float`, `query_bool`,
`query_optional_str`, `query_optional_int`, `path_str`, `path_int`,
`path_float`, `header_str`, `bearer`. Each takes a constraint list from
lex-schema (`StrEmail`, `IntInRange(1, 100)`, …); failures collapse into a
single 422 with every failing constraint reported, *not* one-at-a-time.

### Dependency injection

Lex doesn't have decorators, so DI is a function-composition pattern. A
`Dep[T] = (Ctx) -> Result[T, Response]` and `inject1`..`inject4` thread the
results into the handler:

```lex
fn current_user(c :: ctx.Ctx) -> Result[Str, resp.Response] {
  match params.bearer(c) {
    Err(r)  => Err(r),
    Ok(tok) => lookup(tok),
  }
}

fn protected(c :: ctx.Ctx) -> resp.Response {
  depends.inject1(c, current_user,
    fn (cc :: ctx.Ctx, user :: Str) -> resp.Response {
      resp.json(str.concat("{\"hello\":\"", str.concat(user, "\"}")))
    })
}
```

`inject2` … `inject4` compose multiple deps; `bind`, `map`, and `pure` build
chained deps inside a single function.

### Lifespan, background, and docs

```lex
let ls := lifespan.new()
            |> fn (l) { lifespan.on_startup(l, fn () { io.print("ready") }) }

let _ := lifespan.run_startup(ls)

let r := background.with_task(
  resp.created_json("{}", "/users/42"),
  background.task("welcome-email",
    fn () -> [io, time] Nil { send_email() }))

# Mount Swagger UI + ReDoc
docs.mount(router, "/openapi.json", "My API")
```

### Exceptions

A registry of `(error -> Option[Response])` matchers, scanned in registration
order. Domain errors stop being scattered match arms and become declarative
mappings:

```lex
type AppError = NotFound(Str) | Conflict(Str)

let reg := exceptions.new()
  |> fn (r) { exceptions.add(r, fn (e) {
       match e {
         NotFound(what) => Some(resp.json_status(404, ...)),
         _ => None,
       } }) }

exceptions.handle(reg, NotFound("user_42"))   # -> 404 Response
```

### Status constants

```lex
import "../src/status" as status

resp.json_status(status.HTTP_201_CREATED(), body)
if status.is_error(r.status) { log_failure(r) }
```

## Effect system

lex-web respects Lex's effect system. Effects propagate precisely:

| Function | Effects |
|----------|---------|
| `dispatch_pure` | none (for tests) |
| `dispatch` | `[io, time]` (logger + request-id middleware) |
| `middleware.run_post` | `[io, time]` |
| `lifespan.run_startup` / `run_shutdown` | `[io, time]` |
| `background.run_all` | `[io, time]` |
| `static_files.serve_from_dir` | `[io]` |
| `static_files.serve_from_map` | none |
| Handler closures | determined by what the handler body calls |

Use `dispatch_pure` in test suites — all tests stay effect-free and fast.

## Path patterns

```
/users          — exact static match
/users/:id      — `:name` binds one non-empty segment
/files/*rest    — `*name` binds all remaining segments (including slashes)
```

## Middleware

```lex
router.use_mw(r, mw.cors(["https://example.com"]))   # also handles OPTIONS preflight (204)
router.use_mw(r, mw.body_limit(1_000_000))
router.use_mw(r, mw.request_id())
router.use_mw(r, mw.gzip(1_024))
router.use_mw(r, mw.trusted_host(["example.com", "api.example.com"]))
router.use_mw(r, mw.logger())
```

Middlewares run in registration order. Pre-middleware (body_limit,
trusted_host, cors-preflight) can short-circuit before the handler runs.
Post-middleware (cors-headers, gzip, request_id, logger) always runs after.

## Request validation

Attach a [lex-schema](https://github.com/alpibrusl/lex-schema) `Validator` to
a route and lex-web validates the JSON body automatically:

```lex
import "../src/test_fixtures" as tf

fn create_item(c :: ctx.Ctx) -> resp.Response {
  match body.require_json_body(c, tf.item_validator()) {
    Err(problem_resp) => problem_resp,   # 422 RFC 7807 response
    Ok(item_json)     => resp.created_json("{\"id\":\"42\"}", "/items/42"),
  }
}

router.handler_json(r, "POST", "/items", tf.item_validator(), create_item)
```

Validators also drive `openapi.export_openapi` — routes with a Validator get a
`requestBody` schema automatically.

## OpenAPI export

```lex
let doc := openapi.export_openapi_str(
  app(), openapi.make_info("My API", "1.0.0"))
```

OpenAPI output now includes:

- **operationIds**: derived from method + pattern (`getUsersId` for `GET /users/:id`)
- **tags**: from `RouteMeta.tags` or `sub_router.new("/...", [tags...])`
- **summary** and **description**: from `RouteMeta` (and `sub_router.with_summary` etc.)
- **per-route success status**: from `RouteMeta.status` (e.g. 201 for POST routes)

## WebSocket

```lex
import "../src/ws" as ws

fn on_message(conn :: WsConn, msg :: WsMessage) -> WsAction {
  match msg {
    WsText(frame) => ws.send(handle_frame(conn, frame)),
    WsClose       => WsNoOp,
    _             => WsNoOp,
  }
}

fn main() -> [net] Nil {
  ws.serve(9000, "ocpp1.6", on_message)
}
```

`WsConn`, `WsMessage`, and `WsAction` are global builtin types (no import
needed). See `src/ws.lex` for path helpers (`last_segment`, `segment`) and
frame helpers (`text_frame`, `is_close`).

## Testing

```lex
import "../src/testing" as t
import "../src/router"  as router

fn test_greet() -> Result[Unit, Str] {
  let req  := t.get("/greet/world")
  let resp := router.dispatch_pure(app(), req)
  t.all([
    t.assert_status(resp, 200),
    t.assert_body_contains(resp, "world"),
  ])
}

fn suite() -> List[Result[Unit, Str]] { [test_greet()] }

fn run_all() -> Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  })
}
```

Run with `lex test` (runs all `tests/test_*.lex` files automatically).

## Package setup (lex.toml)

lex-web declares its lex-schema dependency in `lex.toml`:

```toml
[package]
name    = "lex-web"
version = "0.2.0"

[dependencies]
lex-schema = { path = "../lex-schema" }
```

Internal imports use the package name instead of relative paths:

```lex
import "lex-schema/validator" as v
```

For your own application, import lex-web modules relative to your file:

```lex
import "../src/ctx"    as ctx   # from tests/ or examples/
import "../src/router" as router
```

## Import paths

Lex resolves imports by relative filesystem path. Import lex-web modules
relative to your file. For lex-schema types (`Validator`, `Json`, …) use
`src/test_fixtures.lex` or import via lex.toml package names — both approaches
are safe since lex-lang v0.9.0 (#358, path canonicalization).
