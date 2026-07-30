/**
 * Production-ready CORS Proxy Server
 * Built with Bun runtime
 */

const PORT = Bun.env.PORT || 3000;
const HOST = Bun.env.HOST || "localhost";
const ALLOWED_ORIGINS = (Bun.env.ALLOWED_ORIGINS?.split(",") || ["*"])
  .map(s => s.trim()).filter(s => s.length > 0);
const MAX_REDIRECTS = 5;
const MAX_RESPONSE_SIZE = 50 * 1024 * 1024; // 50MB
const PROXY_TIMEOUT_MS = 30000; // 30 seconds
const ALLOWED_DOMAINS = (Bun.env.ALLOWED_DOMAINS?.split(",") || [])
  .map(s => s.trim()).filter(s => s.length > 0);

// CORS headers configuration — uses ALLOWED_ORIGINS from env or "*" as fallback
const corsOrigin = ALLOWED_ORIGINS.length > 0 ? ALLOWED_ORIGINS[0] : "*";
const corsHeaders = {
  "Access-Control-Allow-Origin": corsOrigin,
  "Access-Control-Allow-Methods":
    "GET, POST, PUT, DELETE, OPTIONS, HEAD, PATCH",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Requested-With, Accept, Accept-Language, Referer, Origin",
  "Access-Control-Max-Age": "86400",
  "Access-Control-Expose-Headers":
    "Content-Length, Content-Type, Date, Server, X-Powered-By",
};

// Log request for monitoring
function logRequest(method: string, url: string, status: number) {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${method} ${url} - ${status}`);
}

// Check if an IP address is private/internal
function isPrivateIP(hostname: string): boolean {
  if (hostname === "localhost" || hostname === "localhost.") return true;
  if (hostname.endsWith(".local") || hostname.endsWith(".local.")) return true;
  if (hostname.endsWith(".internal") || hostname.endsWith(".internal.")) return true;
  if (hostname === "::1" || hostname === "0:0:0:0:0:0:0:1") return true;

  const ipv4PrivateRanges = [
    /^10\./,
    /^192\.168\./,
    /^172\.(1[6-9]|2[0-9]|3[01])\./,
    /^127\./,
    /^169\.254\./,
    /^0\./,
    /^100\.64\./,
    /^224\./,
    /^240\./,
  ];
  for (const range of ipv4PrivateRanges) {
    if (range.test(hostname)) return true;
  }

  const ipv6PrivatePatterns = [
    /^fe80:/i, /^fec0:/i, /^fc00:/i, /^fd00:/i, /^ff00:/i,
  ];
  for (const pattern of ipv6PrivatePatterns) {
    if (pattern.test(hostname)) return true;
  }

  return false;
}

// Validate URL and check for SSRF
function isValidUrl(urlString: string): boolean {
  try {
    const url = new URL(urlString);
    if (url.protocol !== "http:" && url.protocol !== "https:") return false;
    if (isPrivateIP(url.hostname)) return false;
    if (ALLOWED_DOMAINS.length > 0) {
      const isAllowed = ALLOWED_DOMAINS.some(
        (domain) =>
          url.hostname === domain || url.hostname.endsWith("." + domain),
      );
      if (!isAllowed) return false;
    }
    return true;
  } catch {
    return false;
  }
}

// Handle proxied request with redirect support
async function proxyRequest(
  targetUrl: string,
  redirectCount = 0,
): Promise<Response> {
  if (redirectCount >= MAX_REDIRECTS) {
    return new Response("Too many redirects", {
      status: 508,
      headers: corsHeaders,
    });
  }

  try {
    const response = await fetch(targetUrl, {
      method: "GET",
      redirect: "manual",
      signal: AbortSignal.timeout(PROXY_TIMEOUT_MS),
    });

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("Location");
      if (location) {
        const redirectUrl = new URL(location, targetUrl).toString();
        if (!isValidUrl(redirectUrl)) {
          return new Response("Redirect to blocked URL", {
            status: 403,
            headers: corsHeaders,
          });
        }
        return proxyRequest(redirectUrl, redirectCount + 1);
      }
    }

    const responseHeaders = new Headers(corsHeaders);
    const headersToForward = [
      "content-type", "content-length", "cache-control", "etag",
      "last-modified", "content-disposition", "content-range",
      "accept-ranges", "vary", "date", "expires", "age",
    ];
    headersToForward.forEach((header) => {
      const value = response.headers.get(header);
      if (value) responseHeaders.set(header, value);
    });

    responseHeaders.delete("x-powered-by");
    responseHeaders.delete("server");
    responseHeaders.delete("via");
    responseHeaders.delete("x-proxy");
    responseHeaders.delete("x-cache");

    const contentLength = response.headers.get("content-length");
    if (contentLength && parseInt(contentLength, 10) > MAX_RESPONSE_SIZE) {
      return new Response("Response too large", {
        status: 413,
        headers: corsHeaders,
      });
    }

    const reader = response.body?.getReader();
    if (!reader) {
      return new Response("No response body", {
        status: 502,
        headers: corsHeaders,
      });
    }

    let totalBytes = 0;
    const chunks: Uint8Array[] = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.length;
      if (totalBytes > MAX_RESPONSE_SIZE) {
        reader.releaseLock();
        return new Response("Response too large", {
          status: 413,
          headers: corsHeaders,
        });
      }
      chunks.push(value);
    }

    const body = new Blob(chunks);
    return new Response(body, {
      status: response.status,
      statusText: response.statusText,
      headers: responseHeaders,
    });
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : "Unknown error";
    console.error(`Proxy error: ${errorMessage}`);
    return new Response(`Proxy error: ${errorMessage}`, {
      status: 502,
      headers: corsHeaders,
    });
  }
}

// Main server
const server = Bun.serve({
  port: PORT,
  hostname: HOST,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/health") {
      logRequest(req.method, url.pathname, 200);
      return new Response("OK", { status: 200, headers: corsHeaders });
    }

    if (req.method === "OPTIONS") {
      logRequest(req.method, url.pathname, 204);
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (url.pathname === "/") {
      const usage = {
        service: "CORS Proxy Server",
        version: "1.0.0",
        usage: {
          method1: "GET /<url>",
          method2: "GET /?url=<encoded-url>",
          example1: `${url.origin}/https://example.com/image.jpg`,
          example2: `${url.origin}/?url=${encodeURIComponent("https://example.com/image.jpg")}`,
        },
        endpoints: {
          health: "/health",
          proxy: "/<target-url> or /?url=<target-url>",
        },
      };
      logRequest(req.method, url.pathname, 200);
      return new Response(JSON.stringify(usage, null, 2), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let targetUrl: string | null = null;
    if (url.pathname !== "/" && url.pathname !== "/health") {
      targetUrl = url.pathname.slice(1);
      if (url.search) targetUrl += url.search;
    }
    if (!targetUrl) targetUrl = url.searchParams.get("url");
    if (!targetUrl) {
      logRequest(req.method, url.pathname, 400);
      return new Response(
        "Missing URL. Use http://localhost:3000/<url> or /?url=<url>",
        { status: 400, headers: corsHeaders },
      );
    }

    try { targetUrl = decodeURIComponent(targetUrl); } catch { /* nop */ }
    if (!isValidUrl(targetUrl)) {
      logRequest(req.method, targetUrl, 400);
      return new Response("Invalid URL provided", { status: 400, headers: corsHeaders });
    }

    if (isYouTubeEmbed(targetUrl)) {
      logRequest(req.method, targetUrl, 200);
      return new Response(serveYouTubeEmbed(targetUrl), {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    const response = await proxyRequest(targetUrl);
    logRequest(req.method, targetUrl, response.status);
    return response;
  },
  error(error) {
    console.error("Server error:", error);
    return new Response("Internal Server Error", { status: 500, headers: corsHeaders });
  },
});

console.log(`CORS Proxy Server running on http://${server.hostname}:${server.port}`);
console.log(`Health check: http://${server.hostname}:${server.port}/health`);

function serveYouTubeEmbed(url: string) {
  return `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="referrer" content="strict-origin-when-cross-origin"><meta name="robots" content="noindex,nofollow"><title>YouTube Video Embed</title><style>*{margin:0;padding:0;box-sizing:border-box}body,html{overflow:hidden;background:#000}iframe{border:0;width:100vw;height:100vh;display:block}</style></head><body><iframe src="${transformYouTubeUrl(url)}" allow="accelerometer;autoplay;clipboard-write;encrypted-media;gyroscope;picture-in-picture;web-share" allowfullscreen referrerpolicy="strict-origin-when-cross-origin" title="Video player"></iframe></body></html>`;
}

function isYouTubeEmbed(urlString: string) {
  const url = new URL(urlString);
  return (url.hostname === "www.youtube.com" || url.hostname === "youtube.com" || url.hostname === "m.youtube.com" || url.hostname === "www.youtube-nocookie.com" || url.hostname === "youtube-nocookie.com") && url.pathname.startsWith("/embed/");
}

function transformYouTubeUrl(urlString: string): string {
  try {
    const url = new URL(urlString);
    if (url.hostname === "www.youtube.com" || url.hostname === "youtube.com" || url.hostname === "m.youtube.com") {
      url.hostname = "www.youtube-nocookie.com";
      return url.toString();
    }
    return urlString;
  } catch { return urlString; }
}
