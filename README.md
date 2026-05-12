# lex-web

HTTP framework for the [Lex language](https://github.com/alpibrusl/lex-lang), built on [lex-schema](https://github.com/alpibrusl/lex-data) for request validation.

## Modules

| Module | Purpose |
|--------|---------|
| `src/ctx.lex` | `Ctx` — enriched request context with path params, query, headers, cookies |
| `src/response.lex` | Response builders (`json`, `text`, `html`, `created`, `not_found`, …) |
| `src/router.lex` | Route table + dispatcher; `route()`, `handler_json()`, `dispatch()`, `dispatch_pure()` |
| `src/middleware.lex` | `MwCors`, `MwBodyLimit`, `MwRequestId`, `MwLogger` |
| `src/body.lex` | `json_body`, `require_json_body`, `form_body`, `form_body_raw`, `raw_body` |
| `src/openapi.lex` | Auto-generates OpenAPI 3.1 from the route table |
| `src/testing.lex` | Pure test helpers: request builders + `assert_*` assertions |
| `src/test_fixtures.lex` | Sample validators for use in tests and examples |
| `src/web.lex` | Facade that groups all modules under one import |

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
```

## Effect system

lex-web respects Lex's effect system. Effects propagate precisely:

| Function | Effects |
|----------|---------|
| `dispatch_pure` | none (for tests) |
| `dispatch` | `[io, time]` (logger + request-id middleware) |
| `middleware.run_post` | `[io, time]` |
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
router.use_mw(r, mw.cors(["https://example.com"]))
router.use_mw(r, mw.body_limit(1_000_000))
router.use_mw(r, mw.request_id())
router.use_mw(r, mw.logger())
```

Middlewares run in registration order. Pre-middleware (body_limit) can short-circuit with a 413 before the handler runs. Post-middleware (cors, request_id, logger) always runs after.

## Request validation

Attach a [lex-schema](https://github.com/alpibrusl/lex-data) `Validator` to a route and lex-web validates the JSON body automatically:

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

Validators also drive `openapi.export_openapi` — routes with a Validator get a `requestBody` schema automatically.

## OpenAPI export

```lex
let doc := openapi.export_openapi_str(
  app(), openapi.make_info("My API", "1.0.0"))
```

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

Run with `lex run tests/test_router.lex run_all`.

## Blocked on upstream issues

- **lex-lang#354** — `net.serve` cannot take a handler closure yet. Use a named wrapper: `fn handle(req :: ctx.RawRequest) -> [io, time] resp.RawResponse { resp.to_raw(router.dispatch(app(), req)) }`.
- **lex-lang#355** — `net.serve` does not forward response headers. Headers are set correctly in the `Response` record and will propagate once #355 ships.

## Import paths

Lex resolves imports by relative filesystem path. Import lex-web modules relative to your file:

```lex
import "../src/ctx"    as ctx   # from tests/ or examples/
import "../src/router" as router
```

For lex-schema types (Validator, Json …), always import through a lex-web `src/` module rather than directly — importing lex-data from `tests/` or `examples/` produces a different module identity and causes type errors. See `src/test_fixtures.lex` for the pattern.
