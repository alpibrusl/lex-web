# lex-web — HTTP status code constants
#
# Mirrors the most-used names from `fastapi.status` and `http.HTTPStatus`.
# Constants only — no imports, no effects. Use anywhere a literal Int
# would otherwise show up:
#
#   resp.json_status(status.HTTP_201_CREATED, body)
#   if c.method == "OPTIONS" { resp.empty(status.HTTP_204_NO_CONTENT) }
#
# Effects: none.

# ---- 1xx ---------------------------------------------------------

fn HTTP_100_CONTINUE()            -> Int { 100 }
fn HTTP_101_SWITCHING_PROTOCOLS() -> Int { 101 }

# ---- 2xx ---------------------------------------------------------

fn HTTP_200_OK()                            -> Int { 200 }
fn HTTP_201_CREATED()                       -> Int { 201 }
fn HTTP_202_ACCEPTED()                      -> Int { 202 }
fn HTTP_204_NO_CONTENT()                    -> Int { 204 }
fn HTTP_206_PARTIAL_CONTENT()               -> Int { 206 }

# ---- 3xx ---------------------------------------------------------

fn HTTP_301_MOVED_PERMANENTLY() -> Int { 301 }
fn HTTP_302_FOUND()             -> Int { 302 }
fn HTTP_303_SEE_OTHER()         -> Int { 303 }
fn HTTP_304_NOT_MODIFIED()      -> Int { 304 }
fn HTTP_307_TEMPORARY_REDIRECT()-> Int { 307 }
fn HTTP_308_PERMANENT_REDIRECT()-> Int { 308 }

# ---- 4xx ---------------------------------------------------------

fn HTTP_400_BAD_REQUEST()                   -> Int { 400 }
fn HTTP_401_UNAUTHORIZED()                  -> Int { 401 }
fn HTTP_403_FORBIDDEN()                     -> Int { 403 }
fn HTTP_404_NOT_FOUND()                     -> Int { 404 }
fn HTTP_405_METHOD_NOT_ALLOWED()            -> Int { 405 }
fn HTTP_406_NOT_ACCEPTABLE()                -> Int { 406 }
fn HTTP_408_REQUEST_TIMEOUT()               -> Int { 408 }
fn HTTP_409_CONFLICT()                      -> Int { 409 }
fn HTTP_410_GONE()                          -> Int { 410 }
fn HTTP_411_LENGTH_REQUIRED()               -> Int { 411 }
fn HTTP_412_PRECONDITION_FAILED()           -> Int { 412 }
fn HTTP_413_PAYLOAD_TOO_LARGE()             -> Int { 413 }
fn HTTP_414_URI_TOO_LONG()                  -> Int { 414 }
fn HTTP_415_UNSUPPORTED_MEDIA_TYPE()        -> Int { 415 }
fn HTTP_416_RANGE_NOT_SATISFIABLE()         -> Int { 416 }
fn HTTP_418_IM_A_TEAPOT()                   -> Int { 418 }
fn HTTP_422_UNPROCESSABLE_ENTITY()          -> Int { 422 }
fn HTTP_425_TOO_EARLY()                     -> Int { 425 }
fn HTTP_428_PRECONDITION_REQUIRED()         -> Int { 428 }
fn HTTP_429_TOO_MANY_REQUESTS()             -> Int { 429 }
fn HTTP_431_REQUEST_HEADER_FIELDS_TOO_LARGE() -> Int { 431 }

# ---- 5xx ---------------------------------------------------------

fn HTTP_500_INTERNAL_SERVER_ERROR()         -> Int { 500 }
fn HTTP_501_NOT_IMPLEMENTED()               -> Int { 501 }
fn HTTP_502_BAD_GATEWAY()                   -> Int { 502 }
fn HTTP_503_SERVICE_UNAVAILABLE()           -> Int { 503 }
fn HTTP_504_GATEWAY_TIMEOUT()               -> Int { 504 }
fn HTTP_505_HTTP_VERSION_NOT_SUPPORTED()    -> Int { 505 }

# ---- Predicates --------------------------------------------------

fn is_informational(status :: Int) -> Bool { status >= 100 and status < 200 }
fn is_success(status :: Int)       -> Bool { status >= 200 and status < 300 }
fn is_redirect(status :: Int)      -> Bool { status >= 300 and status < 400 }
fn is_client_error(status :: Int)  -> Bool { status >= 400 and status < 500 }
fn is_server_error(status :: Int)  -> Bool { status >= 500 and status < 600 }
fn is_error(status :: Int)         -> Bool { status >= 400 and status < 600 }
