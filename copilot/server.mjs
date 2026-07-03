#!/usr/bin/env node
// Local web server for the ShadowzDex tax-aware co-pilot. Serves a chat UI and
// streams the co-pilot's steps to the browser over SSE. All keys stay here on
// the server — the browser only sends text and receives log lines.
//
//   node copilot/server.mjs   →   http://127.0.0.1:8799
//
// SECURITY: binds to 127.0.0.1 only. This endpoint can move real (testnet) funds,
// so do NOT expose it publicly without auth / per-user wallets. Demo locally or
// over an SSH tunnel.

import http from "node:http";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dir = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8799);
const HOST = "127.0.0.1";

const page = () => readFileSync(join(__dir, "public", "index.html"));

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${HOST}`);

  if (req.method === "GET" && url.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(page());
    return;
  }

  if (req.method === "GET" && url.pathname === "/chat") {
    const message = (url.searchParams.get("m") || "").slice(0, 200).trim();
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    if (!message) { send("done", { ok: false }); return res.end(); }

    // Spawn the proven CLI (array args → no shell injection). Stream its output.
    const child = spawn("node", [join(__dir, "copilot.mjs"), message], { cwd: __dir });
    const pump = (buf) => {
      for (const line of buf.toString().split("\n")) {
        const t = line.replace(/\s+$/, "");
        if (t.length) send("line", t);
      }
    };
    child.stdout.on("data", pump);
    child.stderr.on("data", pump);
    child.on("close", (code) => { send("done", { ok: code === 0 }); res.end(); });
    req.on("close", () => child.kill());
    return;
  }

  res.writeHead(404); res.end("not found");
});

server.listen(PORT, HOST, () => {
  console.log(`🤖 ShadowzDex co-pilot chat → http://${HOST}:${PORT}`);
});
