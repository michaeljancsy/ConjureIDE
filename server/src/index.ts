import type { Env } from "./types";
import { handleActivate } from "./activate";
import { handleVerify } from "./verify";
import { handleWebhook } from "./webhook";

async function handleDownload(): Promise<Response> {
  const appcastRes = await fetch("https://updates.conjuredsp.com/appcast.xml");
  if (!appcastRes.ok) {
    return new Response("Update feed unavailable", { status: 502 });
  }
  const xml = await appcastRes.text();
  const match = xml.match(/<enclosure[^>]+url="([^"]+\.dmg)"/);
  if (!match) {
    return new Response("No release found", { status: 503 });
  }
  const dmgUrl = match[1];
  const redirectUrl = `https://www.conjuredsp.com/downloaded?file=${encodeURIComponent(dmgUrl)}`;
  return Response.redirect(redirectUrl, 302);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // CORS headers for the macOS app
    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }

    let response: Response;

    switch (url.pathname) {
      case "/activate":
        if (request.method !== "POST") {
          response = new Response("Method not allowed", { status: 405 });
        } else {
          response = await handleActivate(request, env);
        }
        break;

      case "/verify":
        if (request.method !== "POST") {
          response = new Response("Method not allowed", { status: 405 });
        } else {
          response = await handleVerify(request, env);
        }
        break;

      case "/webhooks/paddle":
        if (request.method !== "POST") {
          response = new Response("Method not allowed", { status: 405 });
        } else {
          response = await handleWebhook(request, env);
        }
        break;

      case "/download":
        if (request.method !== "GET") {
          response = new Response("Method not allowed", { status: 405 });
        } else {
          response = await handleDownload();
        }
        break;

      case "/health":
        response = Response.json({ status: "ok" });
        break;

      default:
        response = new Response("Not found", { status: 404 });
    }

    // Add CORS headers to all responses
    const newHeaders = new Headers(response.headers);
    for (const [key, value] of Object.entries(corsHeaders)) {
      newHeaders.set(key, value);
    }

    return new Response(response.body, {
      status: response.status,
      headers: newHeaders,
    });
  },
};
