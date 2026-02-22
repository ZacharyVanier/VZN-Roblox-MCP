import http from "http";
import { BridgeService } from "./bridge-service.js";
import { StudioRegistry } from "./studio-registry.js";
import { HTTP_PORT_START, HTTP_PORT_END } from "./types.js";

function parseBody(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString();
        resolve(raw ? (JSON.parse(raw) as Record<string, unknown>) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

function sendJson(res: http.ServerResponse, status: number, data: unknown): void {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  });
  res.end(body);
}

/**
 * Start the HTTP server that Studio plugins poll for commands.
 * Tries ports 3002-3020 until one is available.
 */
export function startHttpServer(
  bridge: BridgeService,
  registry: StudioRegistry,
  fixedPort?: number
): Promise<{ server: http.Server; port: number }> {
  return new Promise((resolve, reject) => {
    function tryPort(port: number): void {
      if (fixedPort != null && port !== fixedPort) {
        reject(new Error("Port " + fixedPort + " is already in use"));
        return;
      }
      if (fixedPort == null && port > HTTP_PORT_END) {
        reject(new Error("No available port in range " + HTTP_PORT_START + "-" + HTTP_PORT_END));
        return;
      }

      const server = http.createServer(async (req, res) => {
        // CORS preflight
        if (req.method === "OPTIONS") {
          sendJson(res, 200, {});
          return;
        }

        const url = new URL(req.url || "/", "http://localhost:" + port);
        const path = url.pathname;

        try {
          // -- GET /health --
          if (path === "/health" && req.method === "GET") {
            sendJson(res, 200, {
              status: "ok",
              service: "vzn-roblox-mcp",
              studios: registry.getActiveStudios().length,
            });
            return;
          }

          // -- POST /register --
          if (path === "/register" && req.method === "POST") {
            const body = await parseBody(req);
            registry.register({
              studioId: body.studioId as string,
              placeName: (body.placeName as string) || "Unknown Place",
              placeId: body.placeId as number | undefined,
              gameId: body.gameId as number | undefined,
            });
            const sid = (body.studioId as string).slice(0, 8);
            console.error("[VZN MCP] Studio registered: " + sid + "... (" + body.placeName + ")");
            sendJson(res, 200, { success: true });
            return;
          }

          // -- GET /poll?studioId=xxx --
          if (path === "/poll" && req.method === "GET") {
            const studioId = url.searchParams.get("studioId");
            if (!studioId) {
              sendJson(res, 400, { error: "Missing studioId query parameter" });
              return;
            }

            registry.recordPoll(studioId);

            const pending = bridge.getPendingRequest(studioId);
            if (pending) {
              sendJson(res, 200, { command: pending });
            } else {
              sendJson(res, 200, { command: null });
            }
            return;
          }

          // -- POST /response --
          if (path === "/response" && req.method === "POST") {
            const body = await parseBody(req);
            const requestId = body.requestId as string;
            const studioId = body.studioId as string;
            const success = body.success as boolean;
            const data = body.data;
            const error = body.error as string | undefined;

            if (error || !success) {
              bridge.rejectRequest(
                requestId,
                studioId,
                error || "Unknown plugin error"
              );
            } else {
              bridge.resolveRequest(requestId, studioId, {
                success: true,
                data,
              });
            }

            sendJson(res, 200, { success: true });
            return;
          }

          // -- POST /disconnect --
          if (path === "/disconnect" && req.method === "POST") {
            const body = await parseBody(req);
            const studioId = body.studioId as string;
            bridge.clearStudio(studioId);
            registry.disconnect(studioId);
            console.error("[VZN MCP] Studio disconnected: " + (studioId || "unknown").slice(0, 8) + "...");
            sendJson(res, 200, { success: true });
            return;
          }

          // -- 404 --
          sendJson(res, 404, { error: "Not found" });
        } catch (err) {
          console.error("[VZN MCP] HTTP error:", err);
          sendJson(res, 500, { error: "Internal server error" });
        }
      });

      server.once("error", (err: NodeJS.ErrnoException) => {
        if (err.code === "EADDRINUSE") {
          console.error("[VZN MCP] Port " + port + " in use, trying " + (port + 1) + "...");
          tryPort(port + 1);
        } else {
          reject(err);
        }
      });

      server.listen(port, "127.0.0.1", () => {
        console.error("[VZN MCP] HTTP server listening on 127.0.0.1:" + port);
        resolve({ server, port });
      });
    }

    tryPort(fixedPort != null ? fixedPort : HTTP_PORT_START);
  });
}
