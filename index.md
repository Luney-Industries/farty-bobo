---
layout: default
title: "Farty Bobo — Opinionated Claude Code, Claude Desktop & Codex Configuration"
description: >-
  Clone it. Symlink it. Stop suffering. Opinionated configuration for Claude Code,
  Claude Desktop, and Codex with custom skills, hooks, settings, and MCP servers for every machine you own.
image: /logos/fartybobo_angry_mascot_1360.png
---

<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --lime:    #97C459;
    --purple:  #7F77DD;
    --indigo:  #534AB7;
    --navy:    #26215C;
    --bg:      #0d0b1e;
    --bg2:     #120f28;
    --bg3:     #1a1640;
    --border:  #2e2860;
    --text:    #f0eeff;
    --sub:     #c4bef0;
    --dim:     #9089c4;
    --font-display: 'Bebas Neue', Impact, sans-serif;
    --font-body:    'JetBrains Mono', 'Courier New', monospace;
  }

  html, body { width: 100%; overflow-x: hidden; background: var(--bg); }

  .fb { font-family: var(--font-body); color: var(--text); background: var(--bg); position: relative; }

  /* ── grain ── */
  .fb::before {
    content: '';
    position: fixed; inset: 0;
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='1'/%3E%3C/svg%3E");
    opacity: 0.04; pointer-events: none; z-index: 0;
  }

  /* ── CRT scanlines ── */
  .fb::after {
    content: '';
    position: fixed; inset: 0;
    background: repeating-linear-gradient(
      to bottom,
      transparent 0px, transparent 3px,
      rgba(0,0,0,0.08) 3px, rgba(0,0,0,0.08) 4px
    );
    pointer-events: none; z-index: 999;
  }

  /* ── HERO ── */
  .fb-hero {
    position: relative; z-index: 1;
    width: 100%; min-height: 100svh;
    display: flex; align-items: center;
    overflow: hidden;
  }

  /* deep radial glow */
  .fb-hero-bg {
    position: absolute; inset: 0;
    background:
      radial-gradient(ellipse 55% 80% at 80% 50%, rgba(83,74,183,0.25) 0%, transparent 70%),
      radial-gradient(ellipse 30% 40% at 20% 80%, rgba(151,196,89,0.07) 0%, transparent 60%);
    pointer-events: none;
  }

  /* mascot — shared base; positioning scoped to desktop media query below */
  .fb-mascot-wrap {
    display: flex; align-items: flex-end;
    pointer-events: none;
  }

  .fb-mascot {
    display: block;
  }

  /* left content — hard right wall keeps text out of mascot's face */
  .fb-left {
    position: relative; z-index: 2;
    padding: 72px 6vw;
    width: 52vw;
    max-width: 52vw;
    display: flex; flex-direction: column; gap: 0;
  }

  .fb-label {
    font-family: var(--font-display);
    font-size: clamp(1rem, 2vw, 1.6rem);
    color: var(--purple);
    letter-spacing: 0.25em;
    text-transform: uppercase;
    margin-bottom: 8px;
    opacity: 0;
    animation: fb-slide-up 0.5s cubic-bezier(0.22,1,0.36,1) 0.05s forwards;
  }

  /* tagline with occasional glitch */
  .fb-tagline {
    font-family: var(--font-display);
    font-size: clamp(4rem, 8.5vw, 9rem);
    line-height: 0.88;
    color: var(--lime);
    text-transform: uppercase;
    letter-spacing: -0.01em;
    margin-bottom: 36px;
    opacity: 0;
    will-change: transform, opacity;
    animation:
      fb-slam 0.5s cubic-bezier(0.22,1,0.36,1) 0.2s forwards,
      fb-glitch 8s steps(1) 2s infinite;
  }

  .fb-desc {
    font-size: clamp(0.82rem, 1.2vw, 0.95rem);
    color: var(--sub);
    max-width: 420px;
    line-height: 1.85;
    opacity: 0;
    animation: fb-slide-up 0.6s cubic-bezier(0.22,1,0.36,1) 0.45s forwards;
  }

  .fb-desc a { color: var(--lime); text-decoration: none; border-bottom: 1px solid rgba(151,196,89,0.35); }
  .fb-desc a:hover { border-bottom-color: var(--lime); }

  /* ── MARQUEE STRIPE ── */
  .fb-stripe {
    position: relative; z-index: 1;
    width: 100%; background: var(--purple);
    padding: 11px 0; overflow: hidden; white-space: nowrap;
  }

  .fb-marquee {
    display: inline-block;
    font-family: var(--font-display);
    font-size: 1.05rem; letter-spacing: 0.16em;
    color: var(--bg);
    animation: fb-marquee 16s linear infinite;
  }

  /* ── CONTENT ── */
  .fb-content {
    position: relative; z-index: 1;
    width: 100%;
    display: grid; grid-template-columns: 1fr 1fr;
  }

  .fb-section {
    background: var(--bg2);
    border-right: 1px solid var(--border);
    border-bottom: 1px solid var(--border);
    padding: 52px 5vw;
    transition: background 0.2s;
  }
  .fb-section:last-child { border-right: none; }
  .fb-section:hover { background: var(--bg3); }

  .fb-section h2 {
    font-family: var(--font-display);
    font-size: clamp(1.7rem, 2.6vw, 2.4rem);
    color: var(--lime); letter-spacing: 0.06em;
    text-transform: uppercase;
    margin-bottom: 24px; padding-bottom: 14px;
    border-bottom: 1px solid var(--border);
  }

  .fb-items { list-style: none; }

  .fb-items li {
    display: flex; gap: 20px;
    padding: 14px 0;
    border-bottom: 1px solid var(--border);
    font-size: clamp(0.8rem, 1vw, 0.87rem);
    line-height: 1.6;
  }
  .fb-items li:last-child { border-bottom: none; }

  .fb-item-key { flex: 0 0 120px; color: var(--purple); font-weight: 700; }
  .fb-item-val { color: var(--sub); }

  /* terminal codeblock */
  .fb-terminal {
    background: #000;
    border: 1px solid var(--border);
    border-top: 24px solid var(--border);
    border-radius: 6px 6px 0 0;
    padding: 20px 24px;
    font-size: clamp(0.76rem, 1vw, 0.83rem);
    line-height: 2.1;
    color: var(--sub);
    overflow-x: auto;
    margin-bottom: 28px;
    position: relative;
  }

  /* fake traffic lights */
  .fb-terminal::before {
    content: '● ● ●';
    position: absolute;
    top: -19px; left: 12px;
    font-size: 0.5rem; letter-spacing: 5px;
    color: #555;
  }

  .fb-terminal .cmd { color: var(--lime); }
  .fb-terminal .arg { color: var(--dim); }

  /* blinking cursor on last line */
  .fb-cursor {
    display: inline-block;
    width: 8px; height: 1em;
    background: var(--lime);
    vertical-align: text-bottom;
    animation: fb-blink 1s step-end infinite;
  }

  .fb-link {
    display: inline-block;
    font-family: var(--font-display);
    font-size: 1.2rem; letter-spacing: 0.1em;
    color: var(--bg); background: var(--lime);
    padding: 13px 36px;
    text-decoration: none; text-transform: uppercase;
    transition: background 0.15s, transform 0.15s;
    clip-path: polygon(0 0, calc(100% - 10px) 0, 100% 10px, 100% 100%, 10px 100%, 0 calc(100% - 10px));
  }
  .fb-link:hover { background: #aad96a; transform: translateY(-2px); }

  /* ── FOOTER ── */
  .fb-footer {
    position: relative; z-index: 1;
    width: 100%; text-align: center;
    padding: 22px;
    font-size: 0.65rem; color: var(--dim);
    border-top: 1px solid var(--border);
    letter-spacing: 0.14em; text-transform: uppercase;
  }

  /* ── KEYFRAMES ── */
  @keyframes fb-slide-up {
    from { opacity: 0; transform: translateY(28px); }
    to   { opacity: 1; transform: translateY(0); }
  }

  @keyframes fb-slam {
    from { opacity: 0; transform: translateY(48px); }
    to   { opacity: 1; transform: translateY(0); }
  }

  @keyframes fb-mascot-in {
    from { opacity: 0; transform: translateX(60px) rotate(4deg); }
    to   { opacity: 1; transform: translateX(0) rotate(0deg); }
  }

  @keyframes fb-marquee {
    from { transform: translateX(0); }
    to   { transform: translateX(-50%); }
  }

  @keyframes fb-blink {
    0%, 100% { opacity: 1; } 50% { opacity: 0; }
  }

  /* glitch: fires at 0%, 10%, 12%, 14% then dormant — repeats every 8s */
  @keyframes fb-glitch {
    0%   { transform: none; opacity: 1; }
    2%   { transform: skewX(-1deg) translateX(3px); opacity: 0.85; }
    4%   { transform: skewX(1deg) translateX(-3px); opacity: 0.9; }
    6%   { transform: none; opacity: 1; }
    100% { transform: none; opacity: 1; }
  }

  /* ── DESKTOP (>1100px) & TABLET (801–1100px) share absolute mascot layout ── */
  @media (min-width: 801px) {
    .fb-mascot-wrap {
      position: absolute;
      right: -4vw; top: 0; bottom: 0;
      opacity: 0;
      animation: fb-mascot-in 0.8s cubic-bezier(0.22,1,0.36,1) 0.15s forwards;
    }

    .fb-mascot {
      height: 95svh;
      width: auto;
      filter:
        drop-shadow(-20px 0 80px rgba(127,119,221,0.6))
        drop-shadow(0 0 40px rgba(127,119,221,0.3));
    }
  }

  /* ── TABLET (801–1100px) — smaller mascot, wider text column ── */
  @media (min-width: 801px) and (max-width: 1100px) {
    .fb-mascot { height: 70svh; max-width: 50vw; }
    .fb-left { width: 56vw; max-width: 56vw; padding: 60px 5vw; }
    .fb-tagline { font-size: clamp(3.5rem, 7vw, 6rem); }
  }

  /* ── MOBILE (≤800px) ── */
  @media (max-width: 800px) {
    .fb-hero {
      flex-direction: column;
      align-items: stretch;
      /* height + min-height so flex children can distribute the space */
      height: 100svh;
      min-height: 100svh;
      /* svh fallback for older Android WebViews */
      height: 100vh;
      height: 100svh;
      min-height: 100vh;
      min-height: 100svh;
      padding-bottom: 0;
      overflow: visible; /* let mascot drop-shadow breathe */
    }

    .fb-left {
      position: relative; z-index: 3;
      width: 100%; max-width: 100%;
      padding: 44px 6vw 28px;
      flex-shrink: 0;
    }

    .fb-tagline {
      font-size: clamp(3rem, 14vw, 5.5rem);
      margin-bottom: 20px;
    }

    .fb-desc { font-size: 0.88rem; max-width: 100%; line-height: 1.75; }

    /* normal flow — no absolute positioning, no !important needed */
    .fb-mascot-wrap {
      position: relative;
      width: 100%;
      flex: 1;
      justify-content: center;
      /* cancel desktop animation — explicit transition:none prevents Safari flash */
      animation: none;
      transition: none;
      opacity: 1;
      min-height: 160px; /* safe floor at 320px viewports */
    }

    .fb-mascot {
      /* height-driven sizing: width follows aspect ratio, capped at 86vw */
      height: 52svh;
      height: 52vh; /* fallback */
      height: 52svh;
      width: auto;
      max-width: 86vw;
      filter:
        drop-shadow(0 -16px 50px rgba(127,119,221,0.9))
        drop-shadow(0 0 30px rgba(127,119,221,0.5));
    }

    .fb-content { grid-template-columns: 1fr; }
    .fb-section { border-right: none; }
    .fb-items li { font-size: 0.87rem; }
    .fb-item-key { flex: 0 0 105px; }
    .fb-item-val { color: var(--text); }
  }
</style>

<div class="fb">

  <section class="fb-hero">
    <div class="fb-hero-bg"></div>

    <div class="fb-left">
      <p class="fb-label">Farty Bobo</p>
      <p class="fb-tagline">We Got the<br>F***ing Gas</p>
      <p class="fb-desc" id="fb-desc-text">
        Built for <strong>software engineers</strong> who need to ship — not babysit a hellscape of missing configs
        and forgotten context across every machine you own. Full support for
        <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a>
        and <a href="https://claude.ai/download">Claude Desktop</a>,
        partial support for <a href="https://github.com/openai/codex">Codex</a>
        — comes with a parallel workflow so you're not watching a spinner while the next job sits idle.
        Opinionated, angry, and actually set up right.
        Clone it. Symlink it. Stop suffering.
      </p>
    </div>

    <div class="fb-mascot-wrap">
      <img
        class="fb-mascot"
        src="{{ '/logos/fartybobo_straitjacket.svg' | relative_url }}"
        alt="Farty Bobo mascot"
      />
    </div>
  </section>

  <div class="fb-stripe">
    <span class="fb-marquee">WE GOT THE F***ING GAS &nbsp;✦&nbsp; WE GOT THE F***ING GAS &nbsp;✦&nbsp; WE GOT THE F***ING GAS &nbsp;✦&nbsp; WE GOT THE F***ING GAS &nbsp;✦&nbsp; WE GOT THE F***ING GAS &nbsp;✦&nbsp; WE GOT THE F***ING GAS &nbsp;✦&nbsp; WE GOT THE F***ING GAS &nbsp;✦&nbsp; WE GOT THE F***ING GAS &nbsp;✦&nbsp;</span>
  </div>

  <div class="fb-content">

    <div class="fb-section">
      <h2>What the Hell's In Here</h2>
      <ul class="fb-items">
        <li>
          <span class="fb-item-key">CLAUDE.md</span>
          <span class="fb-item-val">Tells Claude who the f*** it is and how to behave. Non-negotiable.</span>
        </li>
        <li>
          <span class="fb-item-key">settings.json</span>
          <span class="fb-item-val">Model, hooks, permissions. Don't touch it unless you know what you're doing.</span>
        </li>
        <li>
          <span class="fb-item-key">skills/</span>
          <span class="fb-item-val">Real slash commands. Not the useless defaults that ship out of the box.</span>
        </li>
        <li>
          <span class="fb-item-key">hooks/</span>
          <span class="fb-item-val">Shell scripts that fire before/after edits so you don't shoot yourself in the foot.</span>
        </li>
        <li>
          <span class="fb-item-key">commands/</span>
          <span class="fb-item-val">Status line and other crap Claude needs to actually function.</span>
        </li>
        <li>
          <span class="fb-item-key">plugins/</span>
          <span class="fb-item-val">Don't want the whole thing? Run <code>/plugin marketplace add fartybobo/farty-bobo</code> then <code>/farty-bobo:install</code>.</span>
        </li>
        <li>
          <span class="fb-item-key">cmux/</span>
          <span class="fb-item-val">First-party cmux + ghostty workspace config. Templates only — run <code>cmux/setup.sh --cwd ~/your/project</code> to generate the real files and wire up the <code>cmux-workspace</code> alias.</span>
        </li>
      </ul>
    </div>

    <div class="fb-section">
      <h2>Just Do It Already</h2>
      <div class="fb-terminal">
        <span class="cmd">git clone</span> <span class="arg">https://github.com/fartybobo/farty-bobo ~/dev/farty-bobo</span><br/>
        <span class="cmd">cd</span> <span class="arg">~/dev/farty-bobo</span><br/>
        <span class="cmd">./setup.sh</span><span class="fb-cursor"></span>
      </div>
      <a class="fb-link" href="https://github.com/fartybobo/farty-bobo">Read the Damn Docs →</a>
    </div>

  </div>

  <footer class="fb-footer">Farty Bobo &mdash; We Got the f***ing Gas &mdash; A <a href="https://luneyindustries.com" target="_blank" rel="noopener" style="color:inherit;text-decoration:underline;">Luney Industries</a> Product</footer>

</div>

<script src="{{ '/assets/js/hero-variant.js' | relative_url }}"></script>
