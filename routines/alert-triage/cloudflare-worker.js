// Required Worker secrets: CLAUDE_TOKEN, ROUTINE_ID, SLACK_SIGNING_SECRET
// Required Worker vars:    ALLOWED_CHANNEL_IDS (comma-separated Slack channel IDs, e.g. "C12345678,C87654321")
//
// Optional KV binding:     SEEN_EVENTS — bind a KV namespace named "SEEN_EVENTS" in wrangler.toml
//                          to enable event_id deduplication. Without it, dedup falls back to
//                          the X-Slack-Retry-Num header drop (weaker but still effective).

const MAX_ATTEMPTS = 3;
const RETRY_DELAYS_MS = [1000, 3000];
const EVENT_ID_TTL_SECONDS = 300; // 5 min — matches Slack's retry window

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const contentType = request.headers.get("Content-Type") || "";
    if (!contentType.includes("application/json")) {
      return new Response("Unsupported Media Type", { status: 415 });
    }

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

    // Slack url_verification handshake — no signature present yet
    if (payload.type === "url_verification") {
      return new Response(payload.challenge, {
        headers: { "Content-Type": "text/plain" },
      });
    }

    // --- Signature verification ---
    const slackSig = request.headers.get("X-Slack-Signature");
    const slackTs = request.headers.get("X-Slack-Request-Timestamp");

    if (!slackSig || !slackTs) {
      return new Response("Unauthorized", { status: 401 });
    }

    const tsSeconds = parseInt(slackTs, 10);
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (Math.abs(nowSeconds - tsSeconds) > 300) {
      return new Response("Request timestamp too old", { status: 401 });
    }

    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(env.SLACK_SIGNING_SECRET),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"]
    );
    const sig = await crypto.subtle.sign(
      "HMAC",
      key,
      new TextEncoder().encode(`v0:${slackTs}:${rawBody}`)
    );
    const hexSig =
      "v0=" +
      Array.from(new Uint8Array(sig))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");

    if (!timingSafeEqual(new TextEncoder().encode(hexSig), new TextEncoder().encode(slackSig))) {
      return new Response("Unauthorized", { status: 401 });
    }

    // --- Event filtering ---
    if (payload.type === "event_callback") {
      const event = payload.event || {};

      // Only allow real user messages OR the Honeybadger bot — drop everything else
      const isHoneybadger = event.app_id === env.HONEYBADGER_SLACK_APP_ID;
      if (
        event.type !== "message" ||
        event.subtype ||
        event.thread_ts ||
        (event.bot_id && !isHoneybadger)
      ) {
        return new Response("OK", { status: 200 });
      }

      // Enforce channel allowlist — only #system-alerts-prod
      const allowedIds = (env.ALLOWED_CHANNEL_IDS || "")
        .split(",")
        .map((id) => id.trim())
        .filter(Boolean);
      if (allowedIds.length > 0 && !allowedIds.includes(event.channel)) {
        return new Response("OK", { status: 200 });
      }

      // --- Idempotency via event_id (requires KV binding) ---
      const eventId = payload.event_id;
      if (eventId && env.SEEN_EVENTS) {
        const seen = await env.SEEN_EVENTS.get(eventId);
        if (seen) {
          return new Response("OK", { status: 200 }); // duplicate
        }
        // Mark as seen before firing — write-before-ack prevents duplicate runs
        // even if the routine call takes time
        await env.SEEN_EVENTS.put(eventId, "1", {
          expirationTtl: EVENT_ID_TTL_SECONDS,
        });
      } else if (request.headers.get("X-Slack-Retry-Num")) {
        // Fallback dedup when KV is unavailable
        return new Response("OK", { status: 200 });
      }
    }

    // Ack Slack immediately — Slack times out at 3s and retries otherwise.
    // Fire the routine with retry/backoff in the background via waitUntil.
    ctx.waitUntil(triggerRoutineWithRetry(env, payload));
    return new Response("OK", { status: 200 });
  },
};

async function triggerRoutineWithRetry(env, payload) {
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
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

      if (response.ok) return;

      // 4xx errors are not retryable (bad token, bad routine ID, etc.)
      if (response.status >= 400 && response.status < 500) {
        console.error(
          `Routine trigger failed (non-retryable): ${response.status}`
        );
        return;
      }

      console.error(
        `Routine trigger failed (attempt ${attempt}/${MAX_ATTEMPTS}): ${response.status}`
      );
    } catch (err) {
      console.error(
        `Routine trigger threw (attempt ${attempt}/${MAX_ATTEMPTS}): ${err.message}`
      );
    }

    if (attempt < MAX_ATTEMPTS) {
      await sleep(RETRY_DELAYS_MS[attempt - 1]);
    }
  }

  // All attempts exhausted — log for Cloudflare dashboard visibility
  console.error(
    `Routine trigger permanently failed after ${MAX_ATTEMPTS} attempts. Event: ${JSON.stringify(payload).slice(0, 200)}`
  );
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function timingSafeEqual(a, b) {
  if (a.byteLength !== b.byteLength) return false;
  const viewA = new DataView(a.buffer ?? a);
  const viewB = new DataView(b.buffer ?? b);
  let mismatch = 0;
  for (let i = 0; i < a.byteLength; i++) {
    mismatch |= viewA.getUint8(i) ^ viewB.getUint8(i);
  }
  return mismatch === 0;
}
