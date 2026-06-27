# Alert Triage Routine

Automated alert triage cloud agent that watches `#system-alerts-prod`, classifies new bugs, and runs a triage-to-PR loop autonomously.

## Cloud Routine

**Routine ID:** `trig_0191VXjhXDQ7UFtsz5STs4wo`
**Manage:** https://claude.ai/code/routines/trig_0191VXjhXDQ7UFtsz5STs4wo
**Schedule:** Hourly fallback (real triggers come from the Cloudflare Worker webhook)
**Repo:** `https://github.com/youth-inc/youthinc`
**MCP connectors:** Slack, Linear, PostHog

## What It Does

1. **Classify** — reads the last hour of alerts, cross-checks against 24h history and PostHog to determine if each is a new bug
2. **Ticket** — creates a Linear issue in the `system-alerts` project, assigned to kfaham@youth.inc
3. **Investigate** — searches the codebase and PostHog for root cause
4. **Fix** — opens a branch (`kinano/auto-fix-*`) and a PR with the minimal fix
5. **Notify** — comments on the Linear ticket with the PR link; optionally posts in the Slack thread (requires human approval due to org policy)

Skips: Honeybadger (local Docker only, not cloud-accessible)

## Cloudflare Worker (Webhook Shim)

`cloudflare-worker.js` + `wrangler.toml` — bridges Slack webhooks to the claude.ai routine run endpoint.

**Security:** Slack HMAC-SHA256 signature verification, 5-min replay window, constant-time compare.
**Reliability:** 3-attempt retry with backoff on 5xx; 4xx errors (bad token, bad routine ID) are not retried.
**Dedup:** Event-id deduplication via Cloudflare KV (optional); falls back to `X-Slack-Retry-Num` header drop.
**Scope:** Channel allowlist enforced at the worker boundary — only configured channel IDs trigger the routine. Thread replies are dropped.

### Required Secrets

```bash
wrangler secret put CLAUDE_TOKEN          # your claude.ai API token
wrangler secret put ROUTINE_ID            # trig_0191VXjhXDQ7UFtsz5STs4wo
wrangler secret put SLACK_SIGNING_SECRET  # Slack App → Basic Information
```

### Required Config (wrangler.toml)

Set `ALLOWED_CHANNEL_IDS` to the Slack channel ID for `#system-alerts-prod`.
Get the ID: right-click the channel in Slack → Copy link → last path segment.

```toml
[vars]
ALLOWED_CHANNEL_IDS = "C12345678"  # replace with real ID
```

### Optional: KV Deduplication

For stronger event-id dedup (survives worker restarts):

```bash
wrangler kv namespace create SEEN_EVENTS
# paste the returned id into wrangler.toml [[kv_namespaces]] and uncomment
wrangler deploy
```

### Deploy

```bash
npm install -g wrangler
wrangler login
# set secrets and ALLOWED_CHANNEL_IDS in wrangler.toml first
wrangler deploy
# → https://alert-triage-webhook.YOUR_SUBDOMAIN.workers.dev
```

### Wire Up Slack

1. Slack App → Event Subscriptions → enable
2. Request URL: your Worker URL (handles `url_verification` automatically)
3. Subscribe to `message.channels` bot event
4. Add the app to `#system-alerts-prod` only

**Honeybadger:** Does not send `X-Slack-Signature` headers — needs a separate path or shared-secret approach. Currently out of scope.
