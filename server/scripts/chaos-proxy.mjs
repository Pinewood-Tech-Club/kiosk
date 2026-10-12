// A local HTTP and websocket proxy in front of a booth Worker that can drop, refuse or black-hole traffic on
// demand, for chaos tests of the kiosk app and the Node client simulator.
//
//   node scripts/chaos-proxy.mjs --upstream https://kiosk-staging.jamboree.techclub.pw --port 8790
//   curl -X POST localhost:8791/mode/down      # up | down | blackhole
//   curl -X POST localhost:8791/kill           # cut every open connection without a close frame
import http from "node:http";
import { WebSocket, WebSocketServer } from "ws";

export function startProxy({ upstream, port, log = () => {} }) {
  const upstreamURL = new URL(upstream);
  const wsUpstream = upstreamURL.origin.replace(/^http/, "ws");
  let mode = "up";
  const sockets = new Set();
  const pairs = new Set();
  const stats = { requests: 0, refused: 0, blackholed: 0, killed: 0, upgrades: 0 };

  const server = http.createServer(async (req, res) => {
    stats.requests++;
    if (mode === "down") {
      stats.refused++;
      req.socket.destroy();
      return;
    }
    if (mode === "blackhole") {
      stats.blackholed++;
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const headers = { ...req.headers };
    delete headers.host;
    delete headers.connection;
    delete headers["content-length"];
    try {
      const response = await fetch(upstreamURL.origin + req.url, {
        method: req.method,
        headers,
        body: ["GET", "HEAD"].includes(req.method) ? undefined : Buffer.concat(chunks),
      });
      const body = Buffer.from(await response.arrayBuffer());
      if (mode !== "up") {
        req.socket.destroy();
        return;
      }
      const out = {};
      response.headers.forEach((value, key) => {
        if (!["content-encoding", "transfer-encoding", "connection", "content-length"].includes(key)) out[key] = value;
      });
      res.writeHead(response.status, out);
      res.end(body);
    } catch (error) {
      log(`upstream error ${error.message}`);
      res.writeHead(502, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: { code: "unavailable", message: "Proxy upstream failed", retryable: true } }));
    }
  });

  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });

  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    stats.upgrades++;
    if (mode === "down") {
      stats.refused++;
      socket.destroy();
      return;
    }
    if (mode === "blackhole") {
      stats.blackholed++;
      return;
    }
    const headers = {};
    for (const key of ["authorization", "x-booth-device"]) if (req.headers[key]) headers[key] = req.headers[key];
    const up = new WebSocket(wsUpstream + req.url, { headers });
    up.once("unexpected-response", (_r, response) => {
      socket.end(`HTTP/1.1 ${response.statusCode} Upstream refused\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    });
    up.once("error", () => socket.destroy());
    up.once("open", () => {
      wss.handleUpgrade(req, socket, head, (client) => {
        const pair = { client, up };
        pairs.add(pair);
        const forget = () => pairs.delete(pair);
        client.on("message", (data, binary) => {
          if (mode === "up" && up.readyState === WebSocket.OPEN) up.send(data, { binary });
        });
        up.on("message", (data, binary) => {
          if (mode === "up" && client.readyState === WebSocket.OPEN) client.send(data, { binary });
        });
        client.on("close", () => { forget(); up.terminate(); });
        up.on("close", () => { forget(); client.terminate(); });
        client.on("error", () => {});
        up.on("error", () => {});
      });
    });
  });

  server.listen(port);

  return {
    stats,
    get mode() { return mode; },
    setMode(next) {
      mode = next;
      log(`proxy mode ${next}`);
    },
    kill() {
      stats.killed += pairs.size + sockets.size;
      for (const { client, up } of pairs) {
        client.terminate();
        up.terminate();
      }
      pairs.clear();
      for (const socket of sockets) socket.destroy();
      log("proxy killed all connections");
    },
    close: () => new Promise((resolve) => {
      for (const socket of sockets) socket.destroy();
      wss.close();
      server.close(resolve);
    }),
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const arg = (name, fallback) => {
    const index = process.argv.indexOf(`--${name}`);
    return index >= 0 ? process.argv[index + 1] : fallback;
  };
  const port = Number(arg("port", "8790"));
  const proxy = startProxy({
    upstream: arg("upstream", "https://kiosk-staging.jamboree.techclub.pw"),
    port,
    log: (line) => console.log(`${new Date().toISOString()} ${line}`),
  });
  http
    .createServer((req, res) => {
      const [, verb, value] = req.url.split("/");
      if (req.method === "POST" && verb === "mode" && ["up", "down", "blackhole"].includes(value)) proxy.setMode(value);
      else if (req.method === "POST" && verb === "kill") proxy.kill();
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ mode: proxy.mode, stats: proxy.stats }));
    })
    .listen(port + 1);
  console.log(`Proxy on http://127.0.0.1:${port}, control on http://127.0.0.1:${port + 1}`);
}
