# Alert Triage Routine

Automated alert triage cloud agent that watches `#system-alerts-prod` and `#yaz-errors`, classifies new bugs, and runs a triage-to-PR loop autonomously.

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

`cloudflare-worker.js` + `wrangler.toml` — bridges Slack webhooks to the claude.ai routine run endpoint (which requires Bearer auth). Verifies Slack request signatures (HMAC-SHA256), drops retries to prevent duplicate runs, and filters out bot/edit/subtype events to prevent feedback loops.

### Required Secrets

```bash
wrangler secret put CLAUDE_TOKEN        # your claude.ai API token
wrangler secret put ROUTINE_ID          # see Cloud Routine section above
wrangler secret put SLACK_SIGNING_SECRET  # from Slack App → Basic Information
```

### Deploy

```bash
npm install -g wrangler
wrangler login
wrangler secret put CLAUDE_TOKEN
wrangler secret put ROUTINE_ID
wrangler secret put SLACK_SIGNING_SECRET
wrangler deploy
# → https://alert-triage-webhook.YOUR_SUBDOMAIN.workers.dev
```

### Wire Up Webhooks

**Slack:**
1. Go to your Slack App → Event Subscriptions → enable
2. Set Request URL to your Worker URL (Slack will send `url_verification` — the Worker handles it automatically)
3. Subscribe to `message.channels` bot event
4. Add the app to `#system-alerts-prod` and `#yaz-errors`

**Honeybadger:**
- Settings → Notifications → Webhook URL → your Worker URL
- Note: Honeybadger does not send `X-Slack-Signature` headers. The Worker currently only verifies Slack signatures. For Honeybadger, consider a separate Worker or path-based routing with a shared secret header.
