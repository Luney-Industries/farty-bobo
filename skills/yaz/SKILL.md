---
name: yaz
description: Help users of the Yaz connector explore org designs, images, and product visuals. Accepts an org name, design query, or product filter and returns structured results with context. Also supports comparing designs, auditing image coverage, and spotting gaps in product imagery.
---

# Yaz Skill

Yaz is a connector to the organization design and product image catalog system. It knows about org designs (logos, artwork, etc.), their approval status, and which products carry those designs — including what image files are available for each.

## 0. Preflight Check

Before anything else, verify the yaz MCP tools are available: `mcp__yaz__search_orgs`, `mcp__yaz__get_org_designs`, `mcp__yaz__get_org_images`, `mcp__yaz__get_org_product_images`.

If any are missing, stop and tell the human: "The Yaz MCP connector isn't configured. Set it up first."

## 1. Understand the Request

Accept input in any of these forms:

- **Org name** — e.g. `/yaz Youth Soccer Club` → look up the org and show its designs
- **Design query** — e.g. `/yaz show approved designs for Acme` → filter by approval status
- **Product image query** — e.g. `/yaz show black polo images for Youth Inc` → filter by product name and color
- **Audit request** — e.g. `/yaz which designs for X are missing SVG files?` → find gaps
- **No argument** — ask the human what org or design they want to explore

Parse the intent from args or conversation context. If ambiguous, make the most reasonable call and proceed — you can always refine after showing results.

## 2. Resolve the Org

Use `mcp__yaz__search_orgs` with a partial name from the request. If multiple orgs match, present them as a short numbered list and ask the human to pick. If exactly one matches, proceed without asking.

## 3. Route to Intent

Determine the primary intent before fetching anything beyond the org:

- **Product image query** (human asks about specific products, colors, or product-level images) → skip to **4c** directly using the org ID — do not call `get_org_designs` first
- **Everything else** → call `mcp__yaz__get_org_designs` with the org ID, then route to the appropriate section below

When fetching designs, apply filters if the request implies them:
- `approval_status`: `approved`, `to_review`, `in_progress`, `to_rework`
- `active_status`: `active`, `inactive`, `amazon-only`

## 4. Handle the Intent

Branch based on what the human wants:

### 4a. Browse Designs

Show a summary table:

```
## Designs for {Org Name}

| ID | Name | Approval | Active |
|----|------|----------|--------|
| 12 | Primary Logo | approved | active |
| 34 | Alternate Mark | to_review | active |
...
```

If there are more than 15 designs, group by approval status and show counts per group first, then ask if they want to drill into a specific group.

### 4b. Inspect a Specific Design's Images

When the human picks a design (or the request is for a specific design's files), use `mcp__yaz__get_org_images` with the `org_design_id`.

Optionally filter by `image_type`: `svg`, `base`, `embroidery_emb`, `embroidery_dst`.

Show results:

```
## Images for Design: {design name} (ID: {id})

| Type | URL |
|------|-----|
| svg  | https://... |
| base | https://... |
| embroidery_emb | https://... |
```

If no images exist for a type the human asked about, call it out explicitly.

### 4c. Product Image Lookup

When the human wants to see what products carry a design or filter by product attributes, use `mcp__yaz__get_org_product_images`.

Key filter rules (enforce these strictly — do NOT explain them to the human unless they ask):
- Use `product_name` for style/brand keywords (e.g. "polo", "jersey tank")
- Use `product_color` for color (e.g. "black", "heather navy") — SEPARATE from `product_name`
- Never combine style + color in `product_name` — they will NOT match
- All filters are case-insensitive substring matches
- Timestamp filters are ISO 8601 UTC

Show results grouped by image URL (as the API returns them), with a list of products sharing each image:

```
## Product Images — {Org Name}
Filtered by: {applied filters}

### Image 1
**URL:** https://...
**Type:** base
**Design:** Primary Logo
**Products using this image:**
- Youth Polo S Black
- Youth Polo M Black
- Youth Polo L Black

### Image 2
...
```

If the result set is large (>20 images), summarize counts first and ask if they want the full list or a more specific filter.

### 4d. Audit / Gap Analysis

When the human asks to find missing images, coverage gaps, or incomplete designs:

1. Fetch all designs for the org (optionally filtered by status)
2. For each design, call `mcp__yaz__get_org_images` — run these in parallel where possible
3. Check which image types are present vs. missing
4. Report gaps:

```
## Image Coverage Audit — {Org Name}

| Design | SVG | Base | Embroidery EMB | Embroidery DST |
|--------|-----|------|----------------|----------------|
| Primary Logo | ✓ | ✓ | ✗ | ✗ |
| Alternate Mark | ✗ | ✓ | ✗ | ✗ |
...

### Summary
- {N} designs missing SVG
- {N} designs missing all embroidery files
- {N} designs fully covered
```

Flag any design with `approval_status=approved` that is missing files — those are the most urgent gaps.

## 5. Offer Follow-up Actions

After any result, offer relevant next steps:

- **Filter further** — apply different status, color, or product filters
- **Audit coverage** — run a gap analysis across all designs
- **Done** — nothing more needed

Don't offer options that don't make sense for the current result. Keep it short.
