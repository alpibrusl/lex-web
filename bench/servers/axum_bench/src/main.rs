//! TechEmpower-style framework benchmark for Axum.
//!
//! Routes mirror bench/servers/lex_web_bench.lex one-for-one:
//!     GET /plaintext   -> "Hello, World!"   (text/plain)
//!     GET /json        -> {"message":"Hello, World!"}
//!     GET /users/:id   -> {"id":"<id>","name":"Alice"}
//!
//! Build & run:
//!     cargo run --release --manifest-path bench/servers/axum_bench/Cargo.toml
//!
//! Axum sits on top of hyper 1.x + tokio — the same stack lex-lang
//! 0.9.3's net.serve_fn uses (#388). This gives the upper bound for
//! what the underlying runtime can do on this machine.

use axum::{
    extract::Path,
    response::IntoResponse,
    routing::get,
    Json, Router,
};
use serde::Serialize;
use std::net::SocketAddr;

#[derive(Serialize)]
struct Message {
    message: &'static str,
}

#[derive(Serialize)]
struct User {
    id: String,
    name: &'static str,
}

async fn plaintext() -> &'static str {
    "Hello, World!"
}

async fn json_hello() -> impl IntoResponse {
    Json(Message { message: "Hello, World!" })
}

async fn get_user(Path(id): Path<String>) -> impl IntoResponse {
    Json(User { id, name: "Alice" })
}

// Default tokio runtime (multi-thread, worker_threads = cores).
// Matches what lex-lang's net.serve_fn does so the comparison is
// runtime-for-runtime.
#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let app = Router::new()
        .route("/plaintext", get(plaintext))
        .route("/json", get(json_hello))
        .route("/users/:id", get(get_user));

    let addr: SocketAddr = "0.0.0.0:8083".parse().unwrap();
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    println!("axum bench listening on {addr}");
    axum::serve(listener, app).await.unwrap();
}
