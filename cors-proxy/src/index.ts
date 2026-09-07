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
  // Check for localhost
  if (hostname === "localhost" || hostname === "localhost.") return true;

  // Check for .local domain
  if (hostname.endsWith(".local") || hostname.endsWith(".local.")) return true;

  // Check for .internal domain
  if (hostname.endsWith(".internal") || hostname.endsWith(".internal.")) return true;

  // Check for IPv6 loopback
  if (hostname === "::1" || hostname === "0:0:0:0:0:0:0:1") return true;

  // Check for IPv4 private ranges
  const ipv4PrivateRanges = [
    /^10\./,                    // 10.0.0.0/8
    /^192\.168\./,             // 192.168.0.0/16
    /^172\.(1[6-9]|2[0-9]|3[01])\./, // 172.16.0.0/12
    /^127\./,                  // 127.0.0.0/8 (loopback)
    /^169\.254\./,             // 169.254.0.0/16 (link-local)
    /^0\./,                    // 0.0.0.0/8
    /^100\.64\./,              // 100.64.0.0/10 (carrier-grade NAT)
    /^224\./,                  // 224.0.0.0/4 (multicast)
    /^240\./,                  // 240.0.0.0/4 (reserved)
  ];
  for (const range of ipv4PrivateRanges) {
    if (range.test(hostname)) return true;
  }

  // Check for IPv6 private ranges
  const ipv6PrivatePatterns = [
    /^fe80:/i,                 // fe80::/10 (link-local)
    /^fec0:/i,                 // fec0::/10 (deprecated site-local)
    /^fc00:/i,                 // fc00::/7 (unique local)
    /^fd00:/i,                 // fd00::/8 (unique local)
    /^ff00:/i,                 // ff00::/8 (multicast)
  ];
  for (const pattern of ipv6PrivatePatterns) {
    if (pattern.test(hostname)) return true;
  }

  return false;
}

// Normalize obfuscated numeric IP forms to dotted quads so the
// private-range checks below cannot be bypassed ("2130706433",
// "0x7f.0.0.1", "0177.0.0.1" all mean 127.0.0.1). Returns null when the
// hostname is not usable.
function normalizeHostname(hostname: string): string | null {
  let h = hostname.toLowerCase();
  if (h.endsWith(".")) h = h.slice(0, -1);
  if (/^\d+$/.test(h)) {
    let n: bigint;
    try { n = BigInt(h); } catch { return null; }
    if (n < 0n || n > 4294967295n) return null;
    const b = Number(n);
    h = [(b >>> 24) & 255, (b >>> 16) & 255, (b >>> 8) & 255, b & 255].join(".");
    return h;
  }
  return h;
}

// Resolve a hostname and reject when any address is private. String-only
// checks lose to DNS rebinding (name clean at validation, dirty at fetch).
async function resolvedIPsArePublic(hostname: string): Promise<boolean> {
  const lookup = (Bun as any).dnsLookup;
  if (typeof lookup !== "function") return true;
  let raw: any;
  try {
    raw = await lookup(hostname);
  } catch {
    return false;
  }
  const list: any[] = Array.isArray(raw) ? raw : [raw];
  if (list.length === 0) return false;
  for (const entry of list) {
    const ip = String(entry?.address ?? entry);
    const norm = normalizeHostname(ip);
    if (!norm || isPrivateIP(norm)) return false;
  }
  return true;
}

// Validate URL and check for SSRF
async function isValidUrl(urlString: string): Promise<boolean> {
  try {
    const url = new URL(urlString);
    if (url.protocol !== "http:" && url.protocol !== "https:") return false;

    const hostname = normalizeHostname(url.hostname);
    if (!hostname) return false;

    // SSRF protection: block private/internal IPs
    if (isPrivateIP(hostname)) return false;

    // If ALLOWED_DOMAINS is set, only allow those domains
    if (ALLOWED_DOMAINS.length > 0) {
      const isAllowed = ALLOWED_DOMAINS.some(
        (domain) =>
          hostname === domain || hostname.endsWith("." + domain),
      );
      if (!isAllowed) return false;
    }

    // DNS rebinding: the name was clean above, make sure it resolves
    // clean too (checked at every redirect hop by the caller).
    return await resolvedIPsArePublic(hostname);
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

    // Handle redirects manually
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("Location");
      if (location) {
        const redirectUrl = new URL(location, targetUrl).toString();
        // SSRF protection: validate redirect target
        if (!(await isValidUrl(redirectUrl))) {
          return new Response("Redirect to blocked URL", {
            status: 403,
            headers: corsHeaders,
          });
        }
        return proxyRequest(redirectUrl, redirectCount + 1);
      }
    }

    // Get response headers
    const responseHeaders = new Headers(corsHeaders);

    // Forward important headers (but NOT content-encoding since fetch auto-decompresses)
    const headersToForward = [
      "content-type",
      "content-length",
      "cache-control",
      "etag",
      "last-modified",
      "content-disposition",
      "content-range",
      "accept-ranges",
      "vary",
      "date",
      "expires",
      "age",
    ];

    headersToForward.forEach((header) => {
      const value = response.headers.get(header);
      if (value) {
        responseHeaders.set(header, value);
      }
    });

    // Remove headers that might reveal proxy usage
    responseHeaders.delete("x-powered-by");
    responseHeaders.delete("server");
    responseHeaders.delete("via");
    responseHeaders.delete("x-proxy");
    responseHeaders.delete("x-cache");

    // Enforce response size limit
    const contentLength = response.headers.get("content-length");
    if (contentLength && parseInt(contentLength, 10) > MAX_RESPONSE_SIZE) {
      return new Response("Response too large", {
        status: 413,
        headers: corsHeaders,
      });
    }

    // Stream with size limit
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
    return new Response("Bad gateway", {
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

    // Health check endpoint
    if (url.pathname === "/health") {
      logRequest(req.method, url.pathname, 200);
      return new Response("OK", {
        status: 200,
        headers: corsHeaders,
      });
    }

    // Handle CORS preflight
    if (req.method === "OPTIONS") {
      logRequest(req.method, url.pathname, 204);
      return new Response(null, {
        status: 204,
        headers: corsHeaders,
      });
    }

    if (req.method !== "GET" && req.method !== "HEAD") {
      return new Response("Method not allowed", {
        status: 405,
        headers: corsHeaders,
      });
    }

    // Root endpoint with usage info
    if (url.pathname === "/") {
      const usage = {
        service: "CORS Proxy Server",
        version: "1.0.0",
        usage: {
          method1: "GET /<url>",
          method2: "GET /?url=<encoded-url>",
          example1: `${url.origin}/https://example.com/image.jpg`,
          example2: `${url.origin}/?url=${encodeURIComponent(
            "https://example.com/image.jpg",
          )}`,
        },
        endpoints: {
          health: "/health",
          proxy: "/<target-url> or /?url=<target-url>",
        },
      };

      logRequest(req.method, url.pathname, 200);
      return new Response(JSON.stringify(usage, null, 2), {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      });
    }

    // Get target URL from path or query parameter
    let targetUrl: string | null = null;

    // Method 1: Direct path (preferred) - http://localhost:3000/https://example.com/image.jpg
    if (url.pathname !== "/" && url.pathname !== "/health") {
      // Remove leading slash and reconstruct the full URL with query string
      targetUrl = url.pathname.slice(1);
      if (url.search) {
        targetUrl += url.search;
      }
    }

    // Method 2: Query parameter - http://localhost:3000/?url=https://example.com/image.jpg
    if (!targetUrl) {
      targetUrl = url.searchParams.get("url");
    }

    if (!targetUrl) {
      logRequest(req.method, url.pathname, 400);
      return new Response(
        "Missing URL. Use http://localhost:3000/<url> or /?url=<url>",
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    // Decode URL if needed
    try {
      targetUrl = decodeURIComponent(targetUrl);
    } catch {
      // URL might not be encoded, use as is
    }

    // Validate URL
    if (!(await isValidUrl(targetUrl))) {
      logRequest(req.method, targetUrl, 400);
      return new Response("Invalid URL provided", {
        status: 400,
        headers: corsHeaders,
      });
    }

    // Check if it's a YouTube URL and redirect instead of proxying
    if (isYouTubeEmbed(targetUrl)) {
      const videoId = extractYouTubeVideoId(targetUrl);
      if (!videoId) {
        return new Response("Invalid YouTube URL", {
          status: 400,
          headers: corsHeaders,
        });
      }
      // YouTube URL detected, redirect to youtube-nocookie.com
      logRequest(req.method, targetUrl, 200);
      return new Response(serveYouTubeEmbed("https://www.youtube-nocookie.com/embed/" + videoId), {
        status: 200,
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          // "Content-Security-Policy": "frame-ancestors *",
          // "X-Frame-Options": "ALLOWALL",
        },
      });
    }

    // Proxy the request for non-YouTube URLs
    const response = await proxyRequest(targetUrl);
    logRequest(req.method, targetUrl, response.status);
    return response;
  },
  error(error) {
    console.error("Server error:", error);
    return new Response("Internal Server Error", {
      status: 500,
      headers: corsHeaders,
    });
  },
});

console.log(
  `🚀 CORS Proxy Server running on http://${server.hostname}:${server.port}`,
);
console.log(`📋 Health check: http://${server.hostname}:${server.port}/health`);
console.log(`🌍 Environment: ${Bun.env.NODE_ENV || "development"}`);

/**
 * This is required to bypass YouTube's Referrer Policy restrictions when
 * embedding videos on the mobile app. It basically "proxies" the Referrer and
 * allows any YouTube video to be embedded anywhere without restrictions.
 */
function serveYouTubeEmbed(url: string) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="referrer" content="strict-origin-when-cross-origin">
    <meta name="robots" content="noindex,nofollow">
    <title>YouTube Video Embed</title>
    <style>
    * {
        margin: 0;
        padding: 0;
        box-sizing:border-box
    }

    body, html {
        overflow: hidden;
        background:#000
    }

    iframe {
        border: 0;
        width: 100vw;
        height: 100vh;
        display: block
    }
    </style>
</head>
<body>
    <iframe src="${transformYouTubeUrl(
      url,
    )}" allow="accelerometer;autoplay;clipboard-write;encrypted-media;gyroscope;picture-in-picture;web-share" allowfullscreen referrerpolicy="strict-origin-when-cross-origin" title="Video player"></iframe>
</body>
</html>`;
}

// Video IDs are exactly 11 base64url chars - anything else is rejected
// before it can reach the embed HTML below.
function extractYouTubeVideoId(urlString: string): string | null {
  try {
    const url = new URL(urlString);
    const m = /^\/embed\/([A-Za-z0-9_-]{11})/.exec(url.pathname);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

// Check if URL is a YouTube embed (including youtube-nocookie.com)
function isYouTubeEmbed(urlString: string) {
  const url = new URL(urlString);
  return (
    (url.hostname === "www.youtube.com" ||
      url.hostname === "youtube.com" ||
      url.hostname === "m.youtube.com" ||
      url.hostname === "www.youtube-nocookie.com" ||
      url.hostname === "youtube-nocookie.com") &&
    url.pathname.startsWith("/embed/")
  );
}

// Transform YouTube URLs to use youtube-nocookie.com for enhanced privacy
function transformYouTubeUrl(urlString: string): string {
  try {
    const url = new URL(urlString);

    // Check if it's a YouTube domain
    if (
      url.hostname === "www.youtube.com" ||
      url.hostname === "youtube.com" ||
      url.hostname === "m.youtube.com"
    ) {
      // Replace with youtube-nocookie.com
      url.hostname = "www.youtube-nocookie.com";
      return url.toString();
    }

    return urlString;
  } catch {
    return urlString;
  }
}
