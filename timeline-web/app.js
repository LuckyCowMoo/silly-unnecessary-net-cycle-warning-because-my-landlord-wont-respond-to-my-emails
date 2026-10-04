(() => {
  const CYCLE_SEC = 31;
  const LIVE_BACK_SEC = 1.5 * 60;
  const LIVE_AHEAD_SEC = 45;
  const HIGHLIGHT_MS = 125; // mark milder spikes (markers + line peaks)
  const ON_TIME_MS = 100;   // major spike must land within this of expected slot
  const WARN_SEC = 3;       // red clock + warning beeps before expected
  const LEFT = 44;
  // GitHub Pages UI → local probe. Same-origin when opened via Serve-SpikeTimeline.py
  const API_BASE = /github\.io$/i.test(location.hostname) ? "http://127.0.0.1:8765" : "";

  const els = {
    title: document.getElementById("title"),
    stats: document.getElementById("stats"),
    next: document.getElementById("next"),
    liveBtn: document.getElementById("liveBtn"),
    followBtn: document.getElementById("followBtn"),
    soundBtn: document.getElementById("soundBtn"),
    clock: document.getElementById("clock"),
    clockLabel: document.getElementById("clockLabel"),
    map: document.getElementById("map"),
    arrowsTop: document.getElementById("arrowsTop"),
    main: document.getElementById("main"),
    arrowsBot: document.getElementById("arrowsBot"),
    bin: document.getElementById("bin"),
    tip: document.getElementById("tip"),
    events: document.getElementById("events"),
  };

  const state = {
    live: true,         // pinned to −1.5m / +45s window while following
    follow: true,       // scroll viewport forward with wall clock
    sound: false,       // warning beeps before expected spikes
    t0: 0, t1: 1,       // full data range (unix ms)
    v0: 0, v1: 1,       // visible range
    anchor: null,       // unix ms
    status: "",
    recording: false,
    spikes: [],         // visible + buffer (padded for slot colouring)
    samples: [],        // visible buckets
    slotHits: new Map(), // expected-slot time → major on-time (survives scroll-off)
    minimap: [],        // {has, large}
    hits: [],           // hover targets in main canvas css px
    drag: null,
    dirty: true,
    needData: true,
    lastFetch: 0,
    lastFollowNow: 0,
  };

  // Warning audio: 3 countdown beeps, hit tone at spike (held for dur), miss tone if none
  const audio = {
    ctx: null,
    targetSlot: null, // locked expected time through on-time window (nextExpected jumps away at T=0)
    beeped: new Set(), // 3,2,1, hit, miss
    resolved: false,
  };

  function nowMs() { return Date.now(); }

  /** Tip of the timeline for follow/live: wall clock while recording, else last sample. */
  function followTipMs() {
    if (state.recording) return nowMs();
    // ignore unset defaults (t0=0,t1=1) before /api/meta lands
    if (state.t1 > state.t0 && state.t1 > 1e12) return state.t1;
    return nowMs();
  }

  function xOf(t, v0, v1, w, left = LEFT) {
    const span = v1 - v0;
    if (span <= 0) return left;
    return left + ((t - v0) / span) * (w - left - 10);
  }

  function tOf(x, v0, v1, w, left = LEFT) {
    const span = v1 - v0;
    const frac = (x - left) / Math.max(1, w - left - 10);
    return v0 + frac * span;
  }

  function fmtTime(ms, withMs = false) {
    const d = new Date(ms);
    const p = (n, z = 2) => String(n).padStart(z, "0");
    const base = `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
    return withMs ? `${base}.${p(d.getMilliseconds(), 3)}` : base;
  }

  function setLiveWindow() {
    const tip = followTipMs();
    state.v1 = tip + LIVE_AHEAD_SEC * 1000;
    state.v0 = tip - LIVE_BACK_SEC * 1000;
    state.live = true;
    state.follow = true;
    state.lastFollowNow = nowMs();
    state.needData = true;
    state.dirty = true;
    updateFollowBtns();
  }

  function enableFollow() {
    // Only advance the current view with wall clock — never change zoom/position.
    state.follow = true;
    state.live = false;
    state.lastFollowNow = nowMs();
    state.dirty = true;
    updateFollowBtns();
  }

  function leaveFollow() {
    if (!state.follow && !state.live) return;
    state.follow = false;
    state.live = false;
    updateFollowBtns();
  }

  function updateFollowBtns() {
    els.liveBtn.classList.toggle("on", state.live && state.follow);
    els.liveBtn.textContent = state.live && state.follow ? "Live (−1.5m / +45s)  ON" : "Live (−1.5m / +45s)";
    els.followBtn.classList.toggle("on", state.follow);
    els.followBtn.textContent = state.follow ? "Scroll with time  ON" : "Scroll with time";
  }

  function fitAll() {
    leaveFollow();
    if (state.t1 > state.t0) {
      state.v0 = state.t0;
      state.v1 = state.t1;
      state.needData = true;
      state.dirty = true;
    }
  }

  /** True if a major spike landed within ON_TIME_MS of expected slot time. */
  function majorOnTime(slotT) {
    if (state.slotHits.get(slotT)) return true;
    for (const s of state.spikes) {
      if (Math.abs(s.t - slotT) > ON_TIME_MS) continue;
      if (s.large || s.rtt >= 200) {
        state.slotHits.set(slotT, true);
        return true;
      }
    }
    return false;
  }

  /** Colour for an expected-slot marker (upcoming / past hit / past miss). */
  function slotColor(slotT, n = nowMs()) {
    if (slotT >= n) return "#4a90d9";
    if (majorOnTime(slotT)) return "#e85d4c";
    return "#7dcea0";
  }

  function eachVisibleSlot(cb) {
    if (state.anchor == null || state.v1 <= state.v0) return;
    const cycle = CYCLE_SEC * 1000;
    let slot0 = state.anchor + Math.floor((state.v0 - state.anchor) / cycle) * cycle;
    const span = state.v1 - state.v0;
    const approxSlots = span / cycle;
    const stepSlots = approxSlots > 80 ? Math.ceil(approxSlots / 80) : 1;
    let drawn = 0;
    for (let s = slot0; s <= state.v1 + cycle && drawn < 120; s += cycle * stepSlots) {
      if (s < state.v0 || s > state.v1) continue;
      cb(s);
      drawn++;
    }
  }

  function drawChevron(ctx, x, y, dir, color) {
    // dir: 1 = point down (∨), -1 = point up (∧)
    const half = 5;
    const depth = 6;
    ctx.beginPath();
    ctx.moveTo(x - half, y);
    ctx.lineTo(x, y + dir * depth);
    ctx.lineTo(x + half, y);
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.6;
    ctx.lineJoin = "round";
    ctx.lineCap = "round";
    ctx.stroke();
  }

  async function api(path) {
    const r = await fetch(API_BASE + path, { cache: "no-store" });
    if (!r.ok) throw new Error(`${path} ${r.status}`);
    return r.json();
  }

  async function refreshMeta() {
    const m = await api("/api/meta");
    state.t0 = m.t0;
    state.t1 = m.t1;
    state.anchor = m.anchor;
    state.status = m.statusText || "";
    state.recording = !!m.recording;
    state.minimap = m.minimap || [];
    const liveSite = !!m.live;
    const mode = liveSite
      ? (state.recording
          ? (state.follow ? (state.live ? "LIVE" : "LIVE · SCROLLING") : "LIVE · PAUSED")
          : "LIVE · waiting for tab activity")
      : (state.recording
          ? (state.follow ? (state.live ? "LIVE FOLLOW" : "SCROLLING") : "PAUSED")
          : (state.follow && state.live ? "RECORDED · END" : "RECORDED"));
    els.title.textContent = `${mode}  |  ${m.runDir}`;
    if (state.follow && state.live) {
      const tip = followTipMs();
      state.v1 = tip + LIVE_AHEAD_SEC * 1000;
      state.v0 = tip - LIVE_BACK_SEC * 1000;
      state.lastFollowNow = nowMs();
    } else if (state.v1 <= state.v0 && m.t1 > m.t0) {
      state.v0 = m.t0; state.v1 = m.t1;
    }
    // keep chart/minimap fresh while recording; also refresh when following recorded end
    state.needData = true;
    state.dirty = true;
  }

  async function refreshWindowData() {
    // Pad spike fetch by a full cycle so a slot still in the binary strip keeps
    // its hit colour after the expected-time marker scrolls off-screen.
    const pad = CYCLE_SEC * 1000 + ON_TIME_MS;
    const spQ = `t0=${state.v0 - pad}&t1=${state.v1 + pad}`;
    const saQ = `t0=${state.v0}&t1=${state.v1}&budget=2400`;
    const [sp, sa] = await Promise.all([
      api(`/api/spikes?${spQ}`),
      api(`/api/samples?${saQ}`),
    ]);
    state.spikes = sp.spikes || [];
    state.samples = sa.samples || [];
    for (const s of state.spikes) {
      if (!(s.large || s.rtt >= 200)) continue;
      if (state.anchor == null) continue;
      const cycle = CYCLE_SEC * 1000;
      const slot = state.anchor + Math.round((s.t - state.anchor) / cycle) * cycle;
      if (Math.abs(s.t - slot) <= ON_TIME_MS) state.slotHits.set(slot, true);
    }
    state.needData = false;
    state.dirty = true;
  }

  async function refreshEvents() {
    try {
      const e = await api("/api/events?tail=30");
      els.events.textContent = (e.lines || []).join("\n");
    } catch {}
  }

  function nextExpected() {
    if (state.anchor == null) return null;
    const cycle = CYCLE_SEC * 1000;
    const n = nowMs();
    let k = Math.ceil((n - state.anchor) / cycle);
    if (n - state.anchor < 0) k = 0;
    let next = state.anchor + k * cycle;
    if (next - n < -50) next += cycle;
    return { next, seconds: (next - n) / 1000 };
  }

  function ensureAudio() {
    if (!audio.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return null;
      audio.ctx = new AC();
    }
    if (audio.ctx.state === "suspended") audio.ctx.resume();
    return audio.ctx;
  }

  /** tone: 'warn' | 'hit' | 'miss' */
  function playTone(tone, durationMs) {
    const ctx = ensureAudio();
    if (!ctx) return;
    const now = ctx.currentTime;
    const dur = Math.max(0.04, (durationMs || 80) / 1000);
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);
    if (tone === "warn") {
      osc.type = "square";
      osc.frequency.value = 880;
      gain.gain.setValueAtTime(0.0001, now);
      gain.gain.exponentialRampToValueAtTime(0.12, now + 0.01);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + Math.min(0.12, dur));
      osc.start(now);
      osc.stop(now + Math.min(0.14, dur + 0.02));
    } else if (tone === "hit") {
      osc.type = "sawtooth";
      osc.frequency.value = 523.25; // C5 — distinct from warn
      gain.gain.setValueAtTime(0.0001, now);
      gain.gain.exponentialRampToValueAtTime(0.14, now + 0.015);
      gain.gain.setValueAtTime(0.12, now + Math.max(0.02, dur - 0.04));
      gain.gain.exponentialRampToValueAtTime(0.0001, now + dur);
      osc.start(now);
      osc.stop(now + dur + 0.02);
    } else {
      // miss — lower third tone
      osc.type = "triangle";
      osc.frequency.value = 220;
      gain.gain.setValueAtTime(0.0001, now);
      gain.gain.exponentialRampToValueAtTime(0.16, now + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.35);
      osc.start(now);
      osc.stop(now + 0.4);
    }
  }

  function spikeNearExpected(slotT) {
    let best = null;
    // Wider than ON_TIME so late-arriving API rows still count for the hit tone
    const win = Math.max(ON_TIME_MS, 300);
    for (const s of state.spikes) {
      if (s.rtt < HIGHLIGHT_MS && !s.large) continue;
      if (Math.abs(s.t - slotT) > win) continue;
      if (!best || s.rtt > best.rtt) best = s;
    }
    // Fallback: sample peaks (sometimes land in /api/samples before /api/spikes)
    for (const s of state.samples) {
      if (s.rtt < HIGHLIGHT_MS) continue;
      if (Math.abs(s.t - slotT) > win) continue;
      if (!best || s.rtt > best.rtt) best = { t: s.t, rtt: s.rtt, durMs: 150, large: s.rtt >= 200 };
    }
    return best;
  }

  function updateSoundBtn() {
    if (!els.soundBtn) return;
    els.soundBtn.classList.toggle("on", state.sound);
    els.soundBtn.textContent = state.sound ? "Sound  ON" : "Sound  OFF";
  }

  /** Countdown beeps + hit/miss for the locked expected slot. */
  function tickWarnAudio() {
    const n = nowMs();
    const exp = nextExpected();

    // Arm a new target when the upcoming slot enters the 3s warn window.
    // Do NOT retarget once past T=0 — nextExpected() already points at +31s.
    if (exp && exp.seconds <= WARN_SEC && exp.seconds > 0) {
      if (audio.targetSlot !== exp.next) {
        audio.targetSlot = exp.next;
        audio.beeped = new Set();
        audio.resolved = false;
      }
    }

    if (audio.targetSlot == null) return;

    const slot = audio.targetSlot;
    const until = (slot - n) / 1000;

    // Keep spike data fresh through countdown + post-slot resolution
    if (until <= WARN_SEC + 0.5 && until > -2) state.needData = true;

    if (!state.sound) {
      // still track slot arming above so enabling mid-countdown works next time
      if (audio.resolved && until < -2) audio.targetSlot = null;
      return;
    }

    // Beeps 1–3 at T−3s, T−2s, T−1s (warn tone)
    for (const sec of [3, 2, 1]) {
      if (until <= sec && until > sec - 1 && !audio.beeped.has(sec)) {
        audio.beeped.add(sec);
        playTone("warn", 90);
      }
    }

    if (!audio.resolved && until <= 0) {
      const spike = spikeNearExpected(slot);
      if (spike && !audio.beeped.has("hit")) {
        audio.beeped.add("hit");
        audio.resolved = true;
        const dur = Math.max(120, Number(spike.durMs) || 120);
        playTone("hit", dur);
      } else if (
        n > slot + ON_TIME_MS + 600 &&
        !audio.beeped.has("miss") &&
        !audio.beeped.has("hit")
      ) {
        // No spike in the expected window → third tone
        audio.beeped.add("miss");
        audio.resolved = true;
        playTone("miss", 350);
      }
    }

    // Clear lock so the next cycle can arm
    if (audio.resolved && until < -2) {
      audio.targetSlot = null;
    }
  }

  function sizeCanvas(c) {
    if (!c) return null;
    const dpr = Math.max(1, window.devicePixelRatio || 1);
    const cssW = Math.max(1, c.clientWidth || 0);
    const cssH = Math.max(1, c.clientHeight || 0);
    const w = Math.max(1, Math.floor(cssW * dpr));
    const h = Math.max(1, Math.floor(cssH * dpr));
    if (c.width !== w || c.height !== h) {
      c.width = w; c.height = h;
    }
    const ctx = c.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { ctx, w: cssW, h: cssH, dpr };
  }

  function drawClock() {
    const sized = sizeCanvas(els.clock);
    if (!sized) return;
    const { ctx, w, h } = sized;
    ctx.clearRect(0, 0, w, h);
    const cx = w / 2, cy = h / 2;
    const r = Math.max(12, Math.min(w, h) / 2 - 4);
    const handLen = r * 0.72;
    const rimW = Math.max(2, r * 0.08);

    const exp = nextExpected();
    const until = exp ? exp.seconds : null;

    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.fillStyle = "#0b0e12";
    ctx.fill();
    ctx.strokeStyle = "#2a3340";
    ctx.lineWidth = rimW;
    ctx.stroke();

    // Always-red arc for the last WARN_SEC of the cycle (hand enters this near spike time)
    {
      const a0 = ((CYCLE_SEC - WARN_SEC) / CYCLE_SEC) * Math.PI * 2 - Math.PI / 2;
      const a1 = Math.PI * 2 - Math.PI / 2;
      ctx.beginPath();
      ctx.arc(cx, cy, r, a0, a1, false);
      ctx.strokeStyle = "#e85d4c";
      ctx.lineWidth = rimW + 1.5;
      ctx.lineCap = "butt";
      ctx.stroke();
    }

    ctx.beginPath();
    ctx.arc(cx, cy, Math.max(6, r - 8), 0, Math.PI * 2);
    ctx.strokeStyle = "#3d4a5c";
    ctx.lineWidth = 1;
    ctx.stroke();

    // 0 at 12 o'clock; sweeps full circle over one 31s cycle
    let ang = -Math.PI / 2;
    if (exp) {
      const u = Math.max(0, Math.min(CYCLE_SEC, until));
      ang = ((CYCLE_SEC - u) / CYCLE_SEC) * Math.PI * 2 - Math.PI / 2;
      els.clockLabel.textContent = fmtTime(exp.next);
      if (until >= 0) {
        els.next.textContent = `Next expected: ${fmtTime(exp.next, true)}   in ${until.toFixed(1)}s`;
        els.next.classList.toggle("warn", until <= WARN_SEC);
      } else {
        els.next.textContent = `Expected spike overdue by ${(-until).toFixed(1)}s. Next slot ${fmtTime(exp.next)}`;
        els.next.classList.add("warn");
      }
    } else {
      els.clockLabel.textContent = "--";
      els.next.textContent = "Next expected: waiting for cycle anchor (first large spike)";
      els.next.classList.remove("warn");
    }

    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.lineTo(cx + Math.cos(ang) * handLen, cy + Math.sin(ang) * handLen);
    ctx.strokeStyle = "#7dcea0";
    ctx.lineWidth = Math.max(2.5, r * 0.12);
    ctx.lineCap = "round";
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(cx, cy, Math.max(2.5, r * 0.1), 0, Math.PI * 2);
    ctx.fillStyle = "#7dcea0";
    ctx.fill();
  }

  function drawMap() {
    const { ctx, w, h } = sizeCanvas(els.map);
    ctx.fillStyle = "#0b0e12";
    ctx.fillRect(0, 0, w, h);
    const cols = state.minimap;
    const n = cols.length || 1;
    const mapLeft = 8;
    const plotW = w - mapLeft - 8;
    for (let i = 0; i < cols.length; i++) {
      if (!cols[i].has) continue;
      const x = mapLeft + ((i + 0.5) / n) * plotW;
      ctx.beginPath();
      ctx.moveTo(x, 6);
      ctx.lineTo(x, h - 6);
      ctx.strokeStyle = cols[i].large ? "#e85d4c" : "#e0a14a";
      ctx.globalAlpha = 0.85;
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.globalAlpha = 1;
    }
    if (state.t1 > state.t0) {
      const x1 = xOf(state.v0, state.t0, state.t1, w, mapLeft);
      const x2 = xOf(state.v1, state.t0, state.t1, w, mapLeft);
      ctx.fillStyle = "rgba(125,206,160,0.2)";
      ctx.strokeStyle = "#7dcea0";
      ctx.lineWidth = 2;
      ctx.fillRect(x1, 4, Math.max(3, x2 - x1), h - 8);
      ctx.strokeRect(x1, 4, Math.max(3, x2 - x1), h - 8);
    }
  }

  function drawMain() {
    const { ctx, w, h } = sizeCanvas(els.main);
    ctx.fillStyle = "#0b0e12";
    ctx.fillRect(0, 0, w, h);
    state.hits = [];
    const maxRtt = 400;
    const plotH = h - 40;

    // grid
    for (const ms of [0, 63, 100, 200, 300, 400]) {
      const y = h - 20 - (ms / maxRtt) * plotH;
      ctx.beginPath();
      ctx.moveTo(LEFT, y);
      ctx.lineTo(w - 10, y);
      ctx.strokeStyle = "#243041";
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.fillStyle = "#6b7c8f";
      ctx.font = "10px Consolas, monospace";
      ctx.fillText(String(ms), 4, y + 3);
    }

    // expected cycle marks: blue = upcoming, red = past hit, green = past miss
    const n = followTipMs();
    eachVisibleSlot((s) => {
      const x = xOf(s, state.v0, state.v1, w);
      const future = s >= n;
      const col = slotColor(s, n);
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, h - 14);
      ctx.strokeStyle = col;
      ctx.globalAlpha = future ? 0.9 : 0.85;
      ctx.lineWidth = future ? 1.5 : 1.25;
      ctx.setLineDash([4, 3]);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.globalAlpha = 1;
    });

    // sample line — merge in-view spike peaks so markers sit on the line
    // (do not merge padded off-screen spikes — that yanks the line up at the edges)
    {
      const pts = state.samples.map((s) => ({ t: s.t, rtt: s.rtt }));
      for (const s of state.spikes) {
        if (s.rtt < HIGHLIGHT_MS) continue;
        if (s.t < state.v0 || s.t > state.v1) continue;
        pts.push({ t: s.t, rtt: s.rtt });
      }
      pts.sort((a, b) => a.t - b.t);
      if (pts.length > 1) {
        ctx.beginPath();
        let started = false;
        for (const s of pts) {
          const x = xOf(s.t, state.v0, state.v1, w);
          const y = h - 20 - (Math.min(maxRtt, s.rtt) / maxRtt) * plotH;
          if (!started) { ctx.moveTo(x, y); started = true; }
          else ctx.lineTo(x, y);
        }
        ctx.strokeStyle = "#4a90a4";
        ctx.lineWidth = 1.2;
        ctx.stroke();
      }
    }

    // spike markers — circle + very faint stem; skip mild RTTs / off-screen
    for (const s of state.spikes) {
      if (s.rtt < HIGHLIGHT_MS) continue;
      if (s.t < state.v0 || s.t > state.v1) continue;
      const x = xOf(s.t, state.v0, state.v1, w);
      const y = h - 20 - (Math.min(maxRtt, s.rtt) / maxRtt) * plotH;
      const large = !!s.large;
      ctx.beginPath();
      ctx.moveTo(x, 6);
      ctx.lineTo(x, h - 16);
      ctx.strokeStyle = large ? "#e85d4c" : "#e0a14a";
      ctx.globalAlpha = 0.12;
      ctx.lineWidth = 1;
      ctx.stroke();
      ctx.globalAlpha = 1;
      const rad = large ? 5 : 3.5;
      ctx.beginPath();
      ctx.arc(x, y, rad, 0, Math.PI * 2);
      ctx.fillStyle = large ? "#e85d4c" : "#e0a14a";
      ctx.fill();
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = 0.8;
      ctx.stroke();
      state.hits.push({ x, y, r: rad + 4, s });
    }

    {
      const tip = followTipMs();
      if (tip >= state.v0 && tip <= state.v1) {
        const x = xOf(tip, state.v0, state.v1, w);
        ctx.beginPath();
        ctx.moveTo(x, 0);
        ctx.lineTo(x, h);
        ctx.strokeStyle = state.recording ? "rgba(255,255,255,0.25)" : "rgba(255,255,255,0.4)";
        ctx.lineWidth = 1;
        ctx.stroke();
      }
    }

    ctx.fillStyle = "#6b7c8f";
    ctx.font = "10px Consolas, monospace";
    for (let i = 0; i <= 5; i++) {
      const t = state.v0 + ((state.v1 - state.v0) * i) / 5;
      const x = xOf(t, state.v0, state.v1, w);
      ctx.fillText(fmtTime(t), x - 22, h - 6);
    }

    const viewMin = (state.v1 - state.v0) / 60000;
    const dataMin = (state.t1 - state.t0) / 60000;
    els.stats.textContent =
      `spikes ${state.spikes.length} (in view)  samples ${state.samples.length} buckets  ` +
      `view ${viewMin.toFixed(2)} min  data ${dataMin.toFixed(1)} min  cycle=${CYCLE_SEC}s`;
  }

  function drawBin() {
    const sized = sizeCanvas(els.bin);
    if (!sized) return;
    const { ctx, w, h } = sized;
    ctx.fillStyle = "#0b0e12";
    ctx.fillRect(0, 0, w, h);
    // Same left gutter / plot width as the main timeline so slots line up.
    ctx.fillStyle = "#6b7c8f";
    ctx.font = "10px Consolas, monospace";
    ctx.textAlign = "center";
    ctx.fillText("31s", LEFT / 2, h / 2 + 3);
    ctx.textAlign = "left";
    if (state.anchor == null || state.v1 <= state.v0) return;
    const cycle = CYCLE_SEC * 1000;
    const n = followTipMs();
    let slot0 = state.anchor + Math.floor((state.v0 - state.anchor) / cycle) * cycle;
    const gap = 2; // clear separator between 31s segments
    let slots = 0;
    for (let s = slot0; s < state.v1 + cycle && slots < 40; s += cycle) {
      slots++;
      const s1 = s + cycle;
      if (s1 < state.v0 || s > state.v1) continue;
      let fill;
      if (s >= n) fill = "#2e6eb5"; // upcoming
      else if (majorOnTime(s)) fill = "#c0392b"; // on-time major
      else fill = "#1e8449"; // miss
      const x1 = xOf(Math.max(s, state.v0), state.v0, state.v1, w);
      const x2 = xOf(Math.min(s1, state.v1), state.v0, state.v1, w);
      const bw = Math.max(1, x2 - x1 - gap);
      ctx.fillStyle = fill;
      ctx.fillRect(x1, 6, bw, h - 12);
      ctx.strokeStyle = "#0b0e12";
      ctx.lineWidth = 1;
      ctx.strokeRect(x1 + 0.5, 6.5, bw - 1, h - 13);
    }
  }

  function drawArrows() {
    if (!els.arrowsTop || !els.arrowsBot) return;
    const top = sizeCanvas(els.arrowsTop);
    const bot = sizeCanvas(els.arrowsBot);
    if (!top || !bot) return;
    top.ctx.clearRect(0, 0, top.w, top.h);
    bot.ctx.clearRect(0, 0, bot.w, bot.h);
    if (state.anchor == null) return;
    const n = followTipMs();
    // Match main chart x mapping (same canvas width as #main).
    eachVisibleSlot((s) => {
      const x = xOf(s, state.v0, state.v1, top.w);
      const col = slotColor(s, n);
      drawChevron(top.ctx, x, 2, 1, col);
      drawChevron(bot.ctx, x, bot.h - 2, -1, col);
    });
  }

  function paint() {
    try {
      const wall = nowMs();
      if (state.follow) {
        if (state.lastFollowNow <= 0) state.lastFollowNow = wall;
        const dt = wall - state.lastFollowNow;
        if (dt > 30) {
          if (state.live) {
            // Live button: pinned −1.5m / +45s window
            const tip = followTipMs();
            state.v1 = tip + LIVE_AHEAD_SEC * 1000;
            state.v0 = tip - LIVE_BACK_SEC * 1000;
          } else {
            // Scroll with time: same zoom & offset, just slide forward
            state.v0 += dt;
            state.v1 += dt;
          }
          state.lastFollowNow = wall;
          state.dirty = true;
        }
      }
      drawClock();
      tickWarnAudio();
      if (state.dirty || (state.follow && state.recording)) {
        drawMap();
        drawArrows();
        drawMain();
        drawBin();
        state.dirty = false;
      }
    } catch (err) {
      // never let a draw error kill the animation loop
      els.stats.textContent = `draw: ${err && err.message ? err.message : err}`;
    }
    requestAnimationFrame(paint);
  }

  function canvasPos(c, ev) {
    const r = c.getBoundingClientRect();
    return { x: ev.clientX - r.left, y: ev.clientY - r.top };
  }

  function zoomAt(c, x, factor) {
    leaveFollow();
    const w = c.clientWidth;
    const anchor = tOf(x, state.v0, state.v1, w);
    let span = (state.v1 - state.v0) * factor;
    const minSpan = 250;
    const maxSpan = 60 * 24 * 60 * 60 * 1000; // 60 days
    span = Math.max(minSpan, Math.min(maxSpan, span));
    let frac = (x - LEFT) / Math.max(1, w - LEFT - 10);
    frac = Math.max(0, Math.min(1, frac));
    state.v0 = anchor - span * frac;
    state.v1 = state.v0 + span;
    state.needData = true;
    state.dirty = true;
  }

  els.main.addEventListener("wheel", (ev) => {
    ev.preventDefault();
    const p = canvasPos(els.main, ev);
    zoomAt(els.main, p.x, ev.deltaY < 0 ? 0.8 : 1.25);
  }, { passive: false });

  els.bin.addEventListener("wheel", (ev) => {
    ev.preventDefault();
    const p = canvasPos(els.bin, ev);
    zoomAt(els.bin, p.x, ev.deltaY < 0 ? 0.8 : 1.25);
  }, { passive: false });

  function onPanDown(c, ev) {
    leaveFollow();
    const p = canvasPos(c, ev);
    state.drag = { x: p.x, v0: state.v0, v1: state.v1, c };
    els.tip.classList.add("hidden");
    c.setPointerCapture?.(ev.pointerId);
  }
  function onPanMove(c, ev) {
    const p = canvasPos(c, ev);
    if (!state.drag) {
      if (c !== els.main) return;
      let hit = null;
      for (const h of state.hits) {
        const dx = p.x - h.x, dy = p.y - h.y;
        if (dx * dx + dy * dy <= h.r * h.r) { hit = h; break; }
      }
      if (hit) {
        const s = hit.s;
        els.tip.textContent =
          `${fmtTime(s.t, true)}\nRTT ${s.rtt.toFixed(1)} ms` +
          `\nEvent lasted ${s.durMs} ms (${s.count} packet(s))` +
          (s.large ? "\nLARGE" : "") +
          (s.flow ? `\n${s.flow}` : "");
        els.tip.style.left = `${Math.min(c.clientWidth - 180, p.x + 12)}px`;
        els.tip.style.top = `${Math.max(4, p.y - 40)}px`;
        els.tip.classList.remove("hidden");
      } else els.tip.classList.add("hidden");
      return;
    }
    const w = state.drag.c.clientWidth;
    const dx = p.x - state.drag.x;
    const span = state.drag.v1 - state.drag.v0;
    const dt = -(dx / Math.max(1, w - LEFT - 10)) * span;
    state.v0 = state.drag.v0 + dt;
    state.v1 = state.drag.v1 + dt;
    state.needData = true;
    state.dirty = true;
  }
  function onPanUp() { state.drag = null; }

  for (const c of [els.main, els.bin]) {
    c.addEventListener("pointerdown", (ev) => onPanDown(c, ev));
    c.addEventListener("pointermove", (ev) => onPanMove(c, ev));
    c.addEventListener("pointerup", onPanUp);
    c.addEventListener("pointercancel", onPanUp);
  }

  els.map.addEventListener("pointerdown", (ev) => {
    leaveFollow();
    const p = canvasPos(els.map, ev);
    const w = els.map.clientWidth;
    const t = tOf(p.x, state.t0, state.t1, w, 8);
    const span = state.v1 - state.v0;
    state.v0 = t - span / 2;
    state.v1 = t + span / 2;
    state.needData = true;
    state.dirty = true;
  });

  els.liveBtn.addEventListener("click", () => {
    if (state.live && state.follow) {
      // unpin live window but keep scrolling at the current span
      state.live = false;
      state.lastFollowNow = nowMs();
      updateFollowBtns();
    } else {
      setLiveWindow();
    }
  });
  els.followBtn.addEventListener("click", () => {
    if (state.live && state.follow) {
      // unpin Live window; keep this exact zoom/position and only scroll
      state.live = false;
      state.lastFollowNow = nowMs();
      updateFollowBtns();
    } else if (state.follow) {
      leaveFollow();
    } else {
      enableFollow();
    }
  });
  if (els.soundBtn) {
    els.soundBtn.addEventListener("click", () => {
      state.sound = !state.sound;
      if (state.sound) {
        ensureAudio();
        // unlock + preview warn tone (browsers require a gesture)
        playTone("warn", 70);
      }
      updateSoundBtn();
    });
  }
  window.addEventListener("keydown", (ev) => {
    if (ev.key === "l" || ev.key === "L") setLiveWindow();
    if (ev.key === "t" || ev.key === "T") els.followBtn.click();
    if (ev.key === "s" || ev.key === "S") els.soundBtn?.click();
    if (ev.key === "r" || ev.key === "R") fitAll();
  });
  window.addEventListener("resize", () => {
    state.dirty = true;
    // force immediate relayout paint on next frame
  });

  async function tick() {
    try {
      const t = performance.now();
      const pollMs = state.recording ? 1000 : 2000;
      if (t - state.lastFetch > pollMs) {
        state.lastFetch = t;
        await refreshMeta();
        await refreshEvents();
      } else if (state.follow && state.recording) {
        // keep pulling samples/spikes while a live run is advancing
        state.needData = true;
      }
      if (state.needData) await refreshWindowData();
    } catch (e) {
      const hint = API_BASE
        ? " — start local probe: Open-SpikeTimeline.bat (port 8765)"
        : "";
      els.stats.textContent = `sync: ${e.message}${hint}`;
      els.title.textContent = API_BASE
        ? "Waiting for local probe on 127.0.0.1:8765"
        : els.title.textContent;
      state.needData = true; // retry next poll
    }
    setTimeout(tick, state.recording ? 250 : 500);
  }

  // Optional controls — don't crash if an older HTML shell is still loaded
  if (!els.followBtn) {
    els.followBtn = { classList: { toggle() {} }, textContent: "", click() {}, addEventListener() {} };
  }

  updateFollowBtns();
  updateSoundBtn();
  setLiveWindow();
  requestAnimationFrame(paint);
  tick();
})();
