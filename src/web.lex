# lex-web — top-level facade
#
# Convenience re-import surface. Instead of importing fifteen modules,
# application code can import just "web" and access everything
# through its sub-modules:
#
#   import "../src/web" as web
#
#   fn handler(c :: web.ctx.Ctx) -> web.resp.Response { ... }
#   fn app() -> web.router.Router {
#     web.router.new()
#       |> fn (r :: web.router.Router) -> web.router.Router {
#            web.router.route(r, "GET", "/", handler)
#          }
#   }
#
# Lex does not have re-exports, so each module must be addressed
# through its sub-alias (web.ctx, web.resp, web.router ...).
# For single-module imports the direct import is idiomatic:
#
#   import "../src/ctx"    as ctx
#   import "../src/router" as router
#
# Effects: none (the facade itself has no functions).

import "./ctx"          as ctx
import "./response"     as resp
import "./router"       as router
import "./middleware"   as middleware
import "./body"         as body
import "./openapi"      as openapi
import "./ws"           as ws
import "./testing"      as testing
import "./status"       as status
import "./params"       as params
import "./depends"      as depends
import "./sub_router"   as sub_router
import "./lifespan"     as lifespan
import "./background"   as background
import "./docs"         as docs
import "./static_files" as static_files
import "./exceptions"   as exceptions
import "./crypto"       as crypto
import "./stream"       as stream
