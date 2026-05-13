# lex-web — interactive documentation pages
#
# Generates the same Swagger UI / ReDoc HTML pages FastAPI serves at
# /docs and /redoc, pointing at a caller-supplied OpenAPI URL.
# CDN-hosted assets — no bundler, no static-file dependency.
#
# Wire it into your router:
#
#   router.route(r, "GET", "/docs",
#     fn (_c :: ctx.Ctx) -> resp.Response {
#       resp.html(docs.swagger_ui_html("/openapi.json", "My API"))
#     })
#
# Or in one shot:
#
#   docs.mount(router, "/openapi.json", "My API")
#
# Effects: none.

import "std.str" as str

import "./ctx"      as ctx
import "./response" as resp
import "./router"   as router

# ---- Swagger UI --------------------------------------------------

# Standard CDN build of swagger-ui-dist. Override the version by
# editing the constant if you need a pinned release.
fn swagger_ui_html(openapi_url :: Str, title :: Str) -> Str {
  let head := str.concat(
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>",
    str.concat(title,
    str.concat("</title><link rel=\"stylesheet\" href=\"",
    str.concat(swagger_css_url(),
    str.concat("\"></head><body><div id=\"swagger-ui\"></div><script src=\"",
    str.concat(swagger_js_url(),
    "\"></script>"))))))
  let init := str.concat(
    "<script>window.onload=function(){window.ui=SwaggerUIBundle({url:\"",
    str.concat(openapi_url,
    "\",dom_id:\"#swagger-ui\",deepLinking:true,layout:\"BaseLayout\"});};</script></body></html>"))
  str.concat(head, init)
}

# ---- ReDoc -------------------------------------------------------

fn redoc_html(openapi_url :: Str, title :: Str) -> Str {
  let head := str.concat(
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>",
    str.concat(title,
    str.concat("</title><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link href=\"https://fonts.googleapis.com/css?family=Roboto:300,400,700|Montserrat:300,400,700\" rel=\"stylesheet\"></head><body><redoc spec-url=\"",
    str.concat(openapi_url,
    str.concat("\"></redoc><script src=\"",
    str.concat(redoc_js_url(),
    "\"></script></body></html>"))))))
  head
}

# ---- One-shot mount ----------------------------------------------

# Adds GET /docs (Swagger) and GET /redoc (ReDoc), both pointing at
# `openapi_url`. The route patterns are fixed; if you need other
# paths use the html builders directly.
fn mount(
  r           :: router.Router,
  openapi_url :: Str,
  title       :: Str
) -> router.Router {
  let r1 := router.route(r, "GET", "/docs",
    fn (_c :: ctx.Ctx) -> resp.Response {
      resp.html(swagger_ui_html(openapi_url, title))
    })
  router.route(r1, "GET", "/redoc",
    fn (_c :: ctx.Ctx) -> resp.Response {
      resp.html(redoc_html(openapi_url, title))
    })
}

# ---- CDN URLs (override if you need to pin or self-host) ---------

fn swagger_css_url() -> Str {
  "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css"
}

fn swagger_js_url() -> Str {
  "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"
}

fn redoc_js_url() -> Str {
  "https://cdn.jsdelivr.net/npm/redoc@2/bundles/redoc.standalone.js"
}
