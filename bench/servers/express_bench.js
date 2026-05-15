// TechEmpower-style framework benchmark for Express.
//
// Routes mirror bench/servers/lex_web_bench.lex:
//   GET /plaintext   -> "Hello, World!"
//   GET /json        -> {"message":"Hello, World!"}
//   GET /users/:id   -> {"id":"<id>","name":"Alice"}
//
// Run:
//   node bench/servers/express_bench.js
//
// No middleware. Single Node process, single event loop — same
// shape FastAPI is benchmarked under.

const express = require("express");

const app = express();
app.disable("x-powered-by");
app.disable("etag");

app.get("/plaintext", (_req, res) => {
  res.type("text/plain").send("Hello, World!");
});

app.get("/json", (_req, res) => {
  res.json({ message: "Hello, World!" });
});

app.get("/users/:id", (req, res) => {
  res.json({ id: req.params.id, name: "Alice" });
});

const port = Number(process.env.PORT) || 8082;
app.listen(port, () => {
  console.log(`express bench listening on :${port}`);
});
