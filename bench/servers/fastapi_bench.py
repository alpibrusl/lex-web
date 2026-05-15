"""TechEmpower-style framework benchmark for FastAPI.

Routes mirror bench/servers/lex_web_bench.lex one-for-one:
    GET /plaintext   -> "Hello, World!"  (text/plain)
    GET /json        -> {"message":"Hello, World!"}
    GET /users/{id}  -> {"id":"<id>","name":"Alice"}

Run with:
    python -m uvicorn bench.servers.fastapi_bench:app \\
        --host 0.0.0.0 --port 8081 \\
        --workers 1 --no-access-log --log-level warning

No middleware is registered. TechEmpower runs FastAPI the same way
in its plaintext / json suites.
"""

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse, JSONResponse, ORJSONResponse

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/plaintext", response_class=PlainTextResponse)
async def plaintext() -> str:
    return "Hello, World!"


@app.get("/json")
async def json_hello() -> dict:
    return {"message": "Hello, World!"}


@app.get("/users/{user_id}")
async def get_user(user_id: str) -> dict:
    return {"id": user_id, "name": "Alice"}
