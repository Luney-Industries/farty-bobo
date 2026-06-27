# Alert Triage Routine

Automated alert triage cloud agent that watches `#system-alerts-prod`, classifies new bugs, and runs a triage-to-PR loop autonomously.

## How It Works

Honeybadger detects an error → posts to `#system-alerts-prod` via its Slack app → Slack fires a webhook → Cloudflare Worker verifies the signature and forwards to the claude.ai routine → routine classifies, tickets, investigates, and opens a PR.

**Fallback:** the routine also runs hourly as a safety net.

## What It Does

1. **Classify** — reads the last hour of alerts, cross-checks against 24h history and PostHog to determine if each is a new bug
2. **Ticket** — creates a Linear issue in the `system-alerts` project, assigned to kfaham@youth.inc
3. **Investigate** — searches the codebase and PostHog for root cause
4. **Fix** — opens a branch (`kinano/auto-fix-*`) and a PR with the minimal fix
5. **Notify** — comments on the Linear ticket with the PR link; optionally posts in the Slack thread (requires human approval due to org policy)

## Setup

### 1. Create a Cloudflare account

https://dash.cloudflare.com/sign-up — free tier is sufficient.

### 2. Install Wrangler and log in

```bash
npm install -g wrangler
wrangler login
```

### 3. Create wrangler.toml from the template

`wrangler.toml` is gitignored — copy the template and fill in your values:

```bash
cp routines/alert-triage/wrangler.toml.template routines/alert-triage/wrangler.toml
```

Get the `#system-alerts-prod` channel ID: right-click the channel in Slack → Copy link → last path segment (starts with `C`). Set it in `wrangler.toml`:

```toml
ALLOWED_CHANNEL_IDS = "C12345678"  # replace with real ID
```

### 4. Set secrets

Secrets live exclusively in Cloudflare's secret store — never commit real values to the repo.

Run these from the `routines/alert-triage/` directory (where `wrangler.toml` lives):

```bash
cd routines/alert-triage
wrangler secret put CLAUDE_TOKEN
wrangler secret put ROUTINE_ID
wrangler secret put SLACK_SIGNING_SECRET
```

**CLAUDE_TOKEN** — your claude.ai session cookie (bills against your plan, not the Anthropic API):
1. Open https://claude.ai → DevTools → Application → Cookies → `https://claude.ai`
2. Copy the value of the `sessionKey` cookie
> Session cookies expire after weeks to months. When the Worker returns 401s, re-run `wrangler secret put CLAUDE_TOKEN` with a fresh `sessionKey`.

**ROUTINE_ID** — paste `trig_0191VXjhXDQ7UFtsz5STs4wo`

**SLACK_SIGNING_SECRET** — from your Slack App → Basic Information → Signing Secret (set up in step 6)

### 5. (Optional) Enable KV Deduplication

Stronger dedup that survives worker restarts. Without this, dedup falls back to dropping `X-Slack-Retry-Num` requests (weaker but usually sufficient for low-volume alert channels).

```bash
wrangler kv namespace create SEEN_EVENTS
```

Cloudflare prints a generated `id` — a unique identifier for your new KV namespace (e.g. `a1b2c3d4e5f6789012345678abcdef01`). Paste it into `wrangler.toml` and uncomment the `[[kv_namespaces]]` block:

```toml
[[kv_namespaces]]
binding = "SEEN_EVENTS"
id = "paste-the-id-here"
```

### 6. Deploy

```bash
cd routines/alert-triage
wrangler deploy
# → https://alert-triage-webhook.YOUR_SUBDOMAIN.workers.dev
```

### 7. Create the Slack App

1. https://api.slack.com/apps → Create New App → From scratch
2. **Basic Information → Signing Secret** → copy it → `wrangler secret put SLACK_SIGNING_SECRET`
3. **Event Subscriptions** → On → paste your Worker URL as the Request URL (Slack sends a verification challenge — the Worker handles it automatically)
4. **Subscribe to bot events** → Add `message.channels` → Save
5. **Install App** → Install to Workspace → authorize
6. In Slack: `#system-alerts-prod` → Integrations → Add Apps → add your new app
7. Add the Honeybadger Slack app to `#system-alerts-prod` if it isn't there already — it's what posts the alerts the routine watches for

---

## Cloud Routine Reference

**Routine ID:** `trig_0191VXjhXDQ7UFtsz5STs4wo`
**Manage:** https://claude.ai/code/routines/trig_0191VXjhXDQ7UFtsz5STs4wo
**Repo:** `https://github.com/youth-inc/youthinc`
**MCP connectors:** Slack, Linear, PostHog

## Cloudflare Worker

**Security:** Slack HMAC-SHA256 signature verification, 5-min replay window, constant-time compare.
**Reliability:** 3-attempt retry with backoff on 5xx; 4xx errors are not retried.
**Dedup:** Event-id deduplication via Cloudflare KV (optional); falls back to `X-Slack-Retry-Num` header drop.
**Scope:** Only messages from `ALLOWED_CHANNEL_IDS` pass through. Thread replies and non-Honeybadger bot messages are dropped.

