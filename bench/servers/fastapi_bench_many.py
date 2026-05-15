"""FastAPI microbenchmark — N-route scaling counterpart.

Mirrors bench/servers/lex_web_bench_many.lex: 20 dummy routes
followed by /plaintext, /json, /users/{id}. Used to compare how
each framework's dispatcher cost scales with route-table size.

Run:
    python -m uvicorn bench.servers.fastapi_bench_many:app \\
        --host 0.0.0.0 --port 8081 --workers 1 \\
        --no-access-log --log-level warning
"""

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


def _hello() -> str:
    return "Hello, World!"


for i in range(20):
    app.get(f"/r{i:02d}", response_class=PlainTextResponse)(_hello)


@app.get("/plaintext", response_class=PlainTextResponse)
async def plaintext() -> str:
    return "Hello, World!"


@app.get("/json")
async def json_hello() -> dict:
    return {"message": "Hello, World!"}


@app.get("/users/{user_id}")
async def get_user(user_id: str) -> dict:
    return {"id": user_id, "name": "Alice"}
