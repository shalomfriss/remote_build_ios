#!/usr/bin/env node
// Copyright (c) 2026 Pedro Shakour
// SPDX-License-Identifier: Apache-2.0

"use strict";

const http = require("node:http");
const tls = require("node:tls");
const { URL } = require("node:url");
const { WebSocket, WebSocketServer } = require("ws");

function argument(name, fallback) {
  const index = process.argv.indexOf(name);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const host = argument("--host", "127.0.0.1");
const port = Number(argument("--port", "7392"));
const simulator = new URL(argument("--simulator-url", "http://127.0.0.1:3200"));
const bridgeHost = argument("--bridge-host", "127.0.0.1");
const bridgePort = Number(argument("--bridge-port", "7391"));
const websocketServer = new WebSocketServer({ noServer: true });

function simulatorURL(requestURL, websocket = false) {
  const target = new URL(requestURL, simulator);
  if (websocket) {
    target.protocol = target.protocol === "https:" ? "wss:" : "ws:";
  }
  return target;
}

function proxyHTTP(request, response) {
  if (request.url === "/_grok-build/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end('{"ok":true}\n');
    return;
  }

  const target = simulatorURL(request.url);
  // Keep the phone-visible Host header so serve-sim advertises helper URLs on
  // this gateway (or its ngrok hostname), rather than unreachable 127.0.0.1.
  // http.request still connects to `target`; Host only controls generated URLs.
  const headers = { ...request.headers };
  delete headers.connection;
  delete headers.upgrade;
  const upstream = http.request(target, { method: request.method, headers }, (upstreamResponse) => {
    response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
    upstreamResponse.pipe(response);
  });
  upstream.on("error", () => {
    if (!response.headersSent) response.writeHead(502);
    response.end("Simulator unavailable\n");
  });
  request.pipe(upstream);
}

function relayACP(phone) {
  const bridge = tls.connect({
    host: bridgeHost,
    port: bridgePort,
    rejectUnauthorized: false,
  });
  let buffered = Buffer.alloc(0);

  bridge.on("data", (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    while (true) {
      const newline = buffered.indexOf(0x0a);
      if (newline < 0) break;
      const line = buffered.subarray(0, newline).toString("utf8").replace(/\r$/, "");
      buffered = buffered.subarray(newline + 1);
      if (phone.readyState === WebSocket.OPEN) phone.send(line);
    }
  });
  bridge.on("error", () => phone.close(1013, "Companion bridge unavailable"));
  bridge.on("close", () => phone.close());
  phone.on("message", (message) => {
    const payload = Buffer.isBuffer(message) ? message : Buffer.from(message);
    bridge.write(Buffer.concat([payload.subarray(0, payload.length), Buffer.from("\n")]));
  });
  phone.on("close", () => bridge.destroy());
  phone.on("error", () => bridge.destroy());
}

function proxySimulatorWebSocket(phone, request) {
  const upstream = new WebSocket(simulatorURL(request.url, true), {
    headers: { "user-agent": request.headers["user-agent"] || "GrokBuild" },
  });
  const queued = [];
  phone.on("message", (message, isBinary) => {
    if (upstream.readyState === WebSocket.OPEN) upstream.send(message, { binary: isBinary });
    else if (upstream.readyState === WebSocket.CONNECTING) queued.push([message, isBinary]);
  });
  upstream.on("open", () => {
    for (const [message, isBinary] of queued) upstream.send(message, { binary: isBinary });
  });
  upstream.on("message", (message, isBinary) => {
    if (phone.readyState === WebSocket.OPEN) phone.send(message, { binary: isBinary });
  });
  upstream.on("close", () => phone.close());
  upstream.on("error", () => phone.close(1013, "Simulator unavailable"));
  phone.on("close", () => upstream.close());
  phone.on("error", () => upstream.close());
}

const server = http.createServer(proxyHTTP);
server.on("upgrade", (request, socket, head) => {
  websocketServer.handleUpgrade(request, socket, head, (phone) => {
    if (new URL(request.url, "http://localhost").pathname === "/acp") relayACP(phone);
    else proxySimulatorWebSocket(phone, request);
  });
});
server.listen(port, host);

function shutdown() {
  server.close(() => process.exit(0));
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
