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

fn http_100_CONTINUE() -> Int {
  100
}

fn http_101_SWITCHING_PROTOCOLS() -> Int {
  101
}

# ---- 2xx ---------------------------------------------------------
fn http_200_OK() -> Int {
  200
}

fn http_201_CREATED() -> Int {
  201
}

fn http_202_ACCEPTED() -> Int {
  202
}

fn http_204_NO_CONTENT() -> Int {
  204
}

fn http_206_PARTIAL_CONTENT() -> Int {
  206
}

# ---- 3xx ---------------------------------------------------------
fn http_301_MOVED_PERMANENTLY() -> Int {
  301
}

fn http_302_FOUND() -> Int {
  302
}

fn http_303_SEE_OTHER() -> Int {
  303
}

fn http_304_NOT_MODIFIED() -> Int {
  304
}

fn http_307_TEMPORARY_REDIRECT() -> Int {
  307
}

fn http_308_PERMANENT_REDIRECT() -> Int {
  308
}

# ---- 4xx ---------------------------------------------------------
fn http_400_BAD_REQUEST() -> Int {
  400
}

fn http_401_UNAUTHORIZED() -> Int {
  401
}

fn http_403_FORBIDDEN() -> Int {
  403
}

fn http_404_NOT_FOUND() -> Int {
  404
}

fn http_405_METHOD_NOT_ALLOWED() -> Int {
  405
}

fn http_406_NOT_ACCEPTABLE() -> Int {
  406
}

fn http_408_REQUEST_TIMEOUT() -> Int {
  408
}

fn http_409_CONFLICT() -> Int {
  409
}

fn http_410_GONE() -> Int {
  410
}

fn http_411_LENGTH_REQUIRED() -> Int {
  411
}

fn http_412_PRECONDITION_FAILED() -> Int {
  412
}

fn http_413_PAYLOAD_TOO_LARGE() -> Int {
  413
}

fn http_414_URI_TOO_LONG() -> Int {
  414
}

fn http_415_UNSUPPORTED_MEDIA_TYPE() -> Int {
  415
}

fn http_416_RANGE_NOT_SATISFIABLE() -> Int {
  416
}

fn http_418_IM_A_TEAPOT() -> Int {
  418
}

fn http_422_UNPROCESSABLE_ENTITY() -> Int {
  422
}

fn http_425_TOO_EARLY() -> Int {
  425
}

fn http_428_PRECONDITION_REQUIRED() -> Int {
  428
}

fn http_429_TOO_MANY_REQUESTS() -> Int {
  429
}

fn http_431_REQUEST_HEADER_FIELDS_TOO_LARGE() -> Int {
  431
}

# ---- 5xx ---------------------------------------------------------
fn http_500_INTERNAL_SERVER_ERROR() -> Int {
  500
}

fn http_501_NOT_IMPLEMENTED() -> Int {
  501
}

fn http_502_BAD_GATEWAY() -> Int {
  502
}

fn http_503_SERVICE_UNAVAILABLE() -> Int {
  503
}

fn http_504_GATEWAY_TIMEOUT() -> Int {
  504
}

fn http_505_HTTP_VERSION_NOT_SUPPORTED() -> Int {
  505
}

# ---- Predicates --------------------------------------------------
fn is_informational(status :: Int) -> Bool {
  status >= 100 and status < 200
}

fn is_success(status :: Int) -> Bool {
  status >= 200 and status < 300
}

fn is_redirect(status :: Int) -> Bool {
  status >= 300 and status < 400
}

fn is_client_error(status :: Int) -> Bool {
  status >= 400 and status < 500
}

fn is_server_error(status :: Int) -> Bool {
  status >= 500 and status < 600
}

fn is_error(status :: Int) -> Bool {
  status >= 400 and status < 600
}

