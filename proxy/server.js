const http = require("node:http");
const { Readable } = require("node:stream");

const port = Number.parseInt(process.env.PORT || "8080", 10);
const upstreamBaseUrl = normalizeBaseUrl(process.env.UPSTREAM_BASE_URL || "http://ollama:11434");
const apiKey = process.env.LLM_HOST_API_KEY || "";
const allowedOrigins = (process.env.ALLOWED_ORIGINS || "*")
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);
const requestTimeoutMs = Number.parseInt(process.env.REQUEST_TIMEOUT_MS || "0", 10);
const logRequests = (process.env.LOG_REQUESTS || "true").toLowerCase() !== "false";

if (!apiKey) {
  console.warn("LLM_HOST_API_KEY is empty; proxy is running without API authentication.");
}

const server = http.createServer(async (req, res) => {
  try {
    applyCors(req, res);

    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    const requestUrl = new URL(req.url || "/", "http://windows-llm-host.local");

    if (requestUrl.pathname === "/health") {
      await handleHealth(res);
      return;
    }

    if (requestUrl.pathname === "/") {
      writeJson(res, 200, {
        name: "windows-llm-host",
        upstream: upstreamBaseUrl,
        authenticated: Boolean(apiKey),
        endpoints: ["/api/*", "/v1/*", "/health"],
      });
      return;
    }

    if (!isAuthorized(req)) {
      writeJson(res, 401, { error: "Missing or invalid bearer token" });
      return;
    }

    await proxyRequest(req, res, requestUrl);
  } catch (error) {
    console.error(error);
    if (!res.headersSent) {
      writeJson(res, 502, { error: "Proxy request failed", detail: error.message });
      return;
    }
    res.end();
  }
});

server.listen(port, "0.0.0.0", () => {
  console.log(`windows-llm-host proxy listening on 0.0.0.0:${port}`);
  console.log(`Forwarding requests to ${upstreamBaseUrl}`);
});

async function proxyRequest(req, res, requestUrl) {
  const upstreamUrl = new URL(`${requestUrl.pathname}${requestUrl.search}`, upstreamBaseUrl);
  const body = await readRequestBody(req);
  const headers = buildForwardHeaders(req.headers, body);
  const controller = requestTimeoutMs > 0 ? new AbortController() : null;
  const timeout = controller
    ? setTimeout(() => controller.abort(), requestTimeoutMs)
    : null;

  if (logRequests) {
    console.log(`${req.method} ${requestUrl.pathname} -> ${upstreamUrl.href}`);
  }

  try {
    const upstreamResponse = await fetch(upstreamUrl, {
      method: req.method,
      headers,
      body: body.length > 0 ? body : undefined,
      signal: controller ? controller.signal : undefined,
    });

    res.writeHead(upstreamResponse.status, Object.fromEntries(upstreamResponse.headers));

    if (upstreamResponse.body) {
      Readable.fromWeb(upstreamResponse.body).pipe(res);
    } else {
      res.end();
    }
  } finally {
    if (timeout) {
      clearTimeout(timeout);
    }
  }
}

async function handleHealth(res) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1500);

  try {
    const response = await fetch(new URL("/api/tags", upstreamBaseUrl), {
      signal: controller.signal,
    });
    writeJson(res, response.ok ? 200 : 502, {
      status: response.ok ? "ok" : "upstream_error",
      upstream: upstreamBaseUrl,
    });
  } catch (error) {
    writeJson(res, 502, {
      status: "upstream_unavailable",
      upstream: upstreamBaseUrl,
      detail: error.message,
    });
  } finally {
    clearTimeout(timeout);
  }
}

function isAuthorized(req) {
  if (!apiKey) {
    return true;
  }

  const authorization = req.headers.authorization || "";
  const token = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
  const explicitKey = req.headers["x-api-key"];

  return token === apiKey || explicitKey === apiKey;
}

function buildForwardHeaders(sourceHeaders, body) {
  const headers = {};
  const blocked = new Set([
    "authorization",
    "connection",
    "content-length",
    "host",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "transfer-encoding",
    "upgrade",
    "x-api-key",
  ]);

  for (const [name, value] of Object.entries(sourceHeaders)) {
    if (!blocked.has(name.toLowerCase()) && value !== undefined) {
      headers[name] = Array.isArray(value) ? value.join(", ") : value;
    }
  }

  if (body.length > 0) {
    headers["content-length"] = String(body.length);
  }

  return headers;
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function applyCors(req, res) {
  const origin = req.headers.origin;
  const allowAll = allowedOrigins.includes("*");
  const allowedOrigin = allowAll ? "*" : allowedOrigins.find((item) => item === origin);

  if (allowedOrigin) {
    res.setHeader("Access-Control-Allow-Origin", allowedOrigin);
  }

  res.setHeader("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS");
  res.setHeader(
    "Access-Control-Allow-Headers",
    "Authorization,Content-Type,X-Api-Key,X-Requested-With",
  );
  res.setHeader("Access-Control-Max-Age", "86400");
}

function writeJson(res, statusCode, payload) {
  res.writeHead(statusCode, { "content-type": "application/json" });
  res.end(JSON.stringify(payload, null, 2));
}

function normalizeBaseUrl(value) {
  return value.endsWith("/") ? value : `${value}/`;
}
