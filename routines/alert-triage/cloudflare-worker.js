export default {
  async fetch(request, env, ctx) {
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const contentType = request.headers.get("Content-Type") || "";
    if (!contentType.includes("application/json")) {
      return new Response("Unsupported Media Type", { status: 415 });
    }

    // Read raw body once — needed for HMAC verification before JSON.parse
    const rawBody = await request.text();
    if (rawBody.length > 1_000_000) {
      return new Response("Payload too large", { status: 413 });
    }

    let payload;
    try {
      payload = JSON.parse(rawBody);
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }

    // Slack sends url_verification during initial webhook setup (no signature yet)
    if (payload.type === "url_verification") {
      return new Response(payload.challenge, {
        headers: { "Content-Type": "text/plain" },
      });
    }

    // Verify Slack signing secret (HMAC-SHA256)
    const slackSig = request.headers.get("X-Slack-Signature");
    const slackTs = request.headers.get("X-Slack-Request-Timestamp");

    if (!slackSig || !slackTs) {
      return new Response("Unauthorized", { status: 401 });
    }

    // Reject timestamps older than 5 minutes (replay protection)
    const tsSeconds = parseInt(slackTs, 10);
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (Math.abs(nowSeconds - tsSeconds) > 300) {
      return new Response("Request timestamp too old", { status: 401 });
    }

    const sigBase = `v0:${slackTs}:${rawBody}`;
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(env.SLACK_SIGNING_SECRET),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(sigBase));
    const hexSig = "v0=" + Array.from(new Uint8Array(sig))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Constant-time compare to prevent timing attacks
    if (!timingSafeEqual(hexSig, slackSig)) {
      return new Response("Unauthorized", { status: 401 });
    }

    // Drop Slack retries — respond 200 to avoid duplicate agent runs
    if (request.headers.get("X-Slack-Retry-Num")) {
      return new Response("OK", { status: 200 });
    }

    // Only process real user messages — drop bots, edits, thread replies,
    // channel joins, and the agent's own Slack posts to prevent feedback loops
    if (payload.type === "event_callback") {
      const event = payload.event || {};
      if (event.type !== "message" || event.subtype || event.bot_id) {
        return new Response("OK", { status: 200 });
      }
    }

    // Respond to Slack immediately then fire the routine async.
    // Slack expects 200 within 3s or it retries, causing duplicate runs.
    ctx.waitUntil(triggerRoutine(env, payload));
    return new Response("OK", { status: 200 });
  },
};

async function triggerRoutine(env, payload) {
  const response = await fetch(
    `https://claude.ai/api/v1/code/triggers/${env.ROUTINE_ID}/run`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.CLAUDE_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ trigger_payload: payload }),
    }
  );

  if (!response.ok) {
    // Log internally only — never surface upstream error details externally
    console.error(`Routine trigger failed: ${response.status}`);
  }
}

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}
