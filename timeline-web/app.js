(() => {
  const CYCLE_SEC_DEFAULT = 31;
  // Learned from major-spike gaps (server); falls back to 31s until enough samples.
  const LIVE_BACK_SEC = 1.5 * 60;
  const LIVE_AHEAD_SEC = 45;
  const HIGHLIGHT_MS = 75; // floor; server also marks mean+1σ sample peaks (incl. past)
  const ON_TIME_MS = 100;   // major spike must land within this of expected slot
  const WARN_SEC = 3;       // red clock + warning beeps before expected
  const LEFT = 44;
  // GitHub Pages UI → local probe. Same-origin when opened via Serve-SpikeTimeline.py
  const API_BASE = /github\.io$/i.test(location.hostname) ? "http://127.0.0.1:8765" : "";

  const els = {
    title: document.getElementById("title"),
    stats: document.getElementById("stats"),
    next: document.getElementById("next"),
    nowClock: document.getElementById("nowClock"),
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
    tally: document.getElementById("tally"),
    tip: document.getElementById("tip"),
    events: document.getElementById("events"),
    probeBanner: document.getElementById("probeBanner"),
  };

  const state = {
    live: true,         // pinned to −1.5m / +45s window while following
    follow: true,       // scroll viewport forward with wall clock
    sound: false,       // warning beeps before expected spikes
    t0: 0, t1: 1,       // full data range (unix ms)
    v0: 0, v1: 1,       // visible range
    anchor: null,       // unix ms
    cycleMs: CYCLE_SEC_DEFAULT * 1000,
    cycleSamples: 0,
    status: "",
    recording: false,
    spikes: [],         // visible + buffer (padded for slot colouring)
    samples: [],        // visible buckets
    slotHits: new Map(), // expected-slot time → major on-time (survives scroll-off)
    slotResults: new Map(), // expected-slot time → true(hit)/false(miss) once window closes
    minimap: [],        // {has, large} server buckets
    peakMarks: new Map(), // t → {large} accumulated minors/majors for minimap
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

  function cycleMs() { return state.cycleMs || CYCLE_SEC_DEFAULT * 1000; }
  function cycleSec() { return cycleMs() / 1000; }

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

  /** Minimap domain = recorded data plus whatever the main view covers (incl. live future). */
  function mapRange() {
    let m0 = state.t0;
    let m1 = state.t1;
    if (state.v1 > state.v0) {
      if (!(m1 > m0)) {
        m0 = state.v0;
        m1 = state.v1;
      } else {
        m0 = Math.min(m0, state.v0);
        m1 = Math.max(m1, state.v1);
      }
    }
    return { m0, m1 };
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

  function spikesCoverSlot(slotT) {
    if (!state.spikes.length) return false;
    let lo = Infinity;
    let hi = -Infinity;
    for (const s of state.spikes) {
      if (s.t < lo) lo = s.t;
      if (s.t > hi) hi = s.t;
    }
    return slotT >= lo - ON_TIME_MS && slotT <= hi + ON_TIME_MS;
  }

  /** Mark spikes the server returned (σ outliers, ≥75ms floor, or large). */
  function isMarkedSpike(s) {
    if (!s) return false;
    if (s.large || s.rtt >= 200) return true;
    if (s.minor) return true;
    return s.rtt >= HIGHLIGHT_MS;
  }

  /** mean+1σ of previous 31s segment from currently loaded samples. */
  function prevSegmentThreshold(t, samples, thrCache) {
    if (state.anchor == null) return HIGHLIGHT_MS;
    const cycle = cycleMs();
    const idx = Math.floor((t - state.anchor) / cycle);
    if (idx < 1) return HIGHLIGHT_MS;
    const prev = idx - 1;
    if (thrCache.has(prev)) return thrCache.get(prev);
    const a0 = state.anchor + prev * cycle;
    const a1 = a0 + cycle;
    let sum = 0;
    let n = 0;
    for (const s of samples) {
      if (s.t < a0 || s.t >= a1) continue;
      sum += s.rtt;
      n++;
    }
    let thr = HIGHLIGHT_MS;
    if (n >= 8) {
      const mean = sum / n;
      let varSum = 0;
      for (const s of samples) {
        if (s.t < a0 || s.t >= a1) continue;
        const d = s.rtt - mean;
        varSum += d * d;
      }
      const std = Math.sqrt(varSum / n);
      thr = mean + Math.max(std, 5);
    }
    thrCache.set(prev, thr);
    return thr;
  }

  /** Persist a detected peak so the minimap keeps it after the view scrolls away. */
  function rememberPeakMark(t, large) {
    const prev = state.peakMarks.get(t);
    if (prev && prev.large) return;
    state.peakMarks.set(t, { large: !!(large || (prev && prev.large)) });
  }

  function rememberPeakMarksFromSpikes(spikes) {
    for (const s of spikes) {
      if (!isMarkedSpike(s)) continue;
      rememberPeakMark(s.t, !!(s.large || s.rtt >= 200));
    }
  }

  /**
   * Mark local maxima on the sample line (what you see) that beat mean+1σ
   * of the previous cycle — covers past bumps the probe never logged as spikes.
   */
  function mergeSamplePeakMarks(samples) {
    if (!samples || samples.length < 3) return;
    const thrCache = new Map();
    const extras = [];
    for (let i = 1; i < samples.length - 1; i++) {
      const s = samples[i];
      if (s.t < state.v0 || s.t > state.v1) continue;
      const rtt = s.rtt;
      // plateau-friendly peak
      if (rtt < samples[i - 1].rtt || rtt < samples[i + 1].rtt) continue;
      const large = rtt >= 200;
      // mean+1σ of prior segment, but never mark below the 75ms minor floor
      // (raw 1σ alone is ~30ms here and would mark ordinary jitter).
      const thr = Math.max(prevSegmentThreshold(s.t, samples, thrCache), HIGHLIGHT_MS);
      if (!large && rtt <= thr) continue;
      let near = false;
      for (const x of state.spikes) {
        if (Math.abs(x.t - s.t) <= 40) { near = true; break; }
      }
      if (near) {
        rememberPeakMark(s.t, large || state.spikes.some(
          (x) => Math.abs(x.t - s.t) <= 40 && (x.large || x.rtt >= 200)
        ));
        continue;
      }
      for (const x of extras) {
        if (Math.abs(x.t - s.t) <= 40) { near = true; break; }
      }
      if (near) continue;
      extras.push({
        t: s.t,
        rtt,
        large,
        minor: !large,
        durMs: 1,
        count: 1,
        fromSample: true,
      });
      rememberPeakMark(s.t, large);
    }
    if (!extras.length) return;
    state.spikes = state.spikes.concat(extras).sort((a, b) => a.t - b.t);
  }

  /** Finalize past slots into hit/miss results for the rolling tally. */
  function updateSlotResults() {
    if (state.anchor == null) return;
    const cycle = cycleMs();
    const tip = followTipMs();
    const finalizeAfter = ON_TIME_MS + 600;
    // Anchor slot is the first large spike by definition
    state.slotResults.set(state.anchor, true);
    state.slotHits.set(state.anchor, true);
    let s = state.anchor + cycle;
    let guard = 0;
    while (s + finalizeAfter < tip && guard < 20000) {
      guard++;
      if (majorOnTime(s)) {
        state.slotResults.set(s, true); // late data can upgrade a miss → hit
      } else if (!state.slotResults.has(s) && spikesCoverSlot(s)) {
        // Never mark miss without spike coverage — that painted the whole
        // minimap green on refresh before past windows were loaded.
        state.slotResults.set(s, false);
      }
      s += cycle;
    }
  }

  function streakStats() {
    const slots = [...state.slotResults.keys()].sort((a, b) => a - b);
    let outcomes = slots.map((t) => state.slotResults.get(t));
    // Drop the opening miss run before the first hit (recording warmup / pre-anchor gap)
    const firstHit = outcomes.indexOf(true);
    if (firstHit > 0) outcomes = outcomes.slice(firstHit);
    else if (firstHit < 0) outcomes = [];
    let hits = 0, misses = 0;
    for (const o of outcomes) {
      if (o) hits++;
      else misses++;
    }
    const total = hits + misses;
    const hitHist = {};
    const missHist = {};
    let maxHit = 0, maxMiss = 0;
    let i = 0;
    while (i < outcomes.length) {
      const val = outcomes[i];
      let j = i + 1;
      while (j < outcomes.length && outcomes[j] === val) j++;
      const len = j - i;
      if (val) {
        hitHist[len] = (hitHist[len] || 0) + 1;
        if (len > maxHit) maxHit = len;
      } else {
        missHist[len] = (missHist[len] || 0) + 1;
        if (len > maxMiss) maxMiss = len;
      }
      i = j;
    }
    let curKind = null, curLen = 0;
    if (outcomes.length) {
      curKind = outcomes[outcomes.length - 1] ? "hit" : "miss";
      curLen = 1;
      for (let k = outcomes.length - 2; k >= 0; k--) {
        if ((outcomes[k] ? "hit" : "miss") !== curKind) break;
        curLen++;
      }
    }
    return { hits, misses, total, hitHist, missHist, maxHit, maxMiss, curKind, curLen };
  }

  function fmtHist(hist, cls) {
    const keys = Object.keys(hist).map(Number).sort((a, b) => a - b);
    if (!keys.length) return `<span class="${cls}">(none)</span>`;
    return keys
      .map((n) => `<span class="${cls}">${n}-in-a-row ×${hist[n]}</span>`)
      .join("   ");
  }

  function renderTally() {
    if (!els.tally) return;
    updateSlotResults();
    const st = streakStats();
    if (st.total === 0) {
      els.tally.innerHTML = "Streak tally: waiting for resolved expected slots…";
      return;
    }
    const hitPct = ((100 * st.hits) / st.total).toFixed(1);
    const missPct = ((100 * st.misses) / st.total).toFixed(1);
    const cur =
      st.curKind == null
        ? ""
        : `  ·  current <span class="${st.curKind}">${st.curLen} ${st.curKind}${st.curLen === 1 ? "" : "s"}</span>`;
    els.tally.innerHTML =
      `<span class="hit">Hits ${st.hits}</span> (${hitPct}%)   ` +
      `<span class="miss">Misses ${st.misses}</span> (${missPct}%)   ` +
      `Total ${st.total}   ` +
      `best <span class="hit">${st.maxHit} hit</span> / <span class="miss">${st.maxMiss} miss</span>` +
      `${cur}\n` +
      `Hit streaks (length×count):   ${fmtHist(st.hitHist, "hit")}\n` +
      `Miss streaks (length×count):  ${fmtHist(st.missHist, "miss")}`;
  }

  /** Colour for an expected-slot marker (upcoming / past hit / past miss). */
  function slotColor(slotT, n = nowMs()) {
    if (slotT >= n) return "#4a90d9";
    if (majorOnTime(slotT) || state.slotResults.get(slotT) === true) return "#e85d4c";
    if (state.slotResults.get(slotT) === false) return "#7dcea0";
    // Past but not resolved yet (no spike coverage / waiting on server) — not a miss
    return "#5a6a7a";
  }

  function eachVisibleSlot(cb) {
    if (state.anchor == null || state.v1 <= state.v0) return;
    const cycle = cycleMs();
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

  function setProbeBanner(show) {
    if (!els.probeBanner) return;
    els.probeBanner.classList.toggle("hidden", !show);
  }

  async function refreshMeta() {
    const m = await api("/api/meta");
    setProbeBanner(false);
    state.t0 = m.t0;
    state.t1 = m.t1;
    state.anchor = m.anchor;
    if (typeof m.cycleMs === "number" && m.cycleMs > 0) state.cycleMs = m.cycleMs;
    if (typeof m.cycleSamples === "number") state.cycleSamples = m.cycleSamples;
    state.status = m.statusText || "";
    state.recording = !!m.recording;
    state.minimap = m.minimap || [];
    if (Array.isArray(m.slotOutcomes)) {
      for (const o of m.slotOutcomes) {
        state.slotResults.set(o.t, !!o.hit);
        if (o.hit) state.slotHits.set(o.t, true);
      }
    }
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
    // Pad samples by one cycle so mean+1σ can see the previous segment.
    const pad = cycleMs() + ON_TIME_MS;
    const samplePad = cycleMs();
    const spQ = `t0=${state.v0 - pad}&t1=${state.v1 + pad}`;
    const saQ = `t0=${state.v0 - samplePad}&t1=${state.v1}&budget=3600`;
    const [sp, sa] = await Promise.all([
      api(`/api/spikes?${spQ}`),
      api(`/api/samples?${saQ}`),
    ]);
    state.spikes = sp.spikes || [];
    rememberPeakMarksFromSpikes(state.spikes);
    const allSamples = sa.samples || [];
    // Chart line uses in-view samples only (padded points are for σ / peak merge).
    state.samples = allSamples.filter((s) => s.t >= state.v0 && s.t <= state.v1);
    mergeSamplePeakMarks(allSamples);
    for (const s of state.spikes) {
      if (!(s.large || s.rtt >= 200)) continue;
      if (state.anchor == null) continue;
      const cycle = cycleMs();
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
    const cycle = cycleMs();
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
      if (!isMarkedSpike(s)) continue;
      if (Math.abs(s.t - slotT) > win) continue;
      if (!best || s.rtt > best.rtt) best = s;
    }
    // Fallback: sample peaks (sometimes land in /api/samples before /api/spikes)
    for (const s of state.samples) {
      if (s.rtt < HIGHLIGHT_MS && s.rtt < 200) continue;
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
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = "high";
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
      const a0 = ((cycleSec() - WARN_SEC) / cycleSec()) * Math.PI * 2 - Math.PI / 2;
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
      const u = Math.max(0, Math.min(cycleSec(), until));
      ang = ((cycleSec() - u) / cycleSec()) * Math.PI * 2 - Math.PI / 2;
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
    const sized = sizeCanvas(els.map);
    if (!sized) return;
    const { ctx, w, h } = sized;
    ctx.fillStyle = "#0b0e12";
    ctx.fillRect(0, 0, w, h);
    const cols = state.minimap;
    const n = cols.length || 1;
    const mapLeft = 8;
    const { m0, m1 } = mapRange();
    if (!(m1 > m0)) return;

    // Expected cycle markers: blue upcoming / red hit / green miss
    updateSlotResults();
    if (state.anchor != null) {
      const cycle = cycleMs();
      const tip = followTipMs();
      let s = state.anchor + Math.floor((m0 - state.anchor) / cycle) * cycle;
      let guard = 0;
      for (; s <= m1 && guard < 20000; s += cycle, guard++) {
        if (s < m0) continue;
        const x = xOf(s, m0, m1, w, mapLeft);
        ctx.beginPath();
        ctx.moveTo(x, 4);
        ctx.lineTo(x, h - 4);
        ctx.strokeStyle = slotColor(s, tip);
        ctx.globalAlpha = s >= tip ? 0.95 : 0.8;
        ctx.lineWidth = s >= tip ? 1.5 : 1.25;
        ctx.stroke();
        ctx.globalAlpha = 1;
      }
    }

    // Spike markers: server buckets + every minor/major we've detected in-view
    const data0 = state.t0;
    const data1 = state.t1;
    if (data1 > data0) {
      for (let i = 0; i < cols.length; i++) {
        if (!cols[i].has) continue;
        const t = data0 + ((i + 0.5) / n) * (data1 - data0);
        const x = xOf(t, m0, m1, w, mapLeft);
        ctx.beginPath();
        ctx.moveTo(x, 6);
        ctx.lineTo(x, h - 6);
        ctx.strokeStyle = cols[i].large ? "#e85d4c" : "#e0a14a";
        ctx.globalAlpha = 0.85;
        ctx.lineWidth = 1;
        ctx.stroke();
        ctx.globalAlpha = 1;
      }
    }
    for (const [t, mark] of state.peakMarks) {
      if (t < m0 || t > m1) continue;
      const x = xOf(t, m0, m1, w, mapLeft);
      ctx.beginPath();
      ctx.moveTo(x, 6);
      ctx.lineTo(x, h - 6);
      ctx.strokeStyle = mark.large ? "#e85d4c" : "#e0a14a";
      ctx.globalAlpha = 0.9;
      ctx.lineWidth = mark.large ? 1.25 : 1;
      ctx.stroke();
      ctx.globalAlpha = 1;
    }

    const x1 = xOf(state.v0, m0, m1, w, mapLeft);
    const x2 = xOf(state.v1, m0, m1, w, mapLeft);
    ctx.fillStyle = "rgba(125,206,160,0.2)";
    ctx.strokeStyle = "#7dcea0";
    ctx.lineWidth = 2;
    ctx.fillRect(x1, 4, Math.max(3, x2 - x1), h - 8);
    ctx.strokeRect(x1, 4, Math.max(3, x2 - x1), h - 8);
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
    const slotTimes = [];
    eachVisibleSlot((s) => {
      slotTimes.push(s);
      const x = xOf(s, state.v0, state.v1, w);
      const future = s >= n;
      const col = slotColor(s, n);
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, h - 18);
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
        if (!isMarkedSpike(s)) continue;
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
        ctx.lineWidth = 1.35;
        ctx.lineJoin = "round";
        ctx.lineCap = "round";
        ctx.stroke();
      }
    }

    // Collapse multi-flow / sample-peak twins into one marker (peak RTT).
    const MARK_GAP_MS = 400;
    const markList = [];
    for (const s of state.spikes) {
      if (!isMarkedSpike(s)) continue;
      if (s.t < state.v0 || s.t > state.v1) continue;
      const prev = markList.length ? markList[markList.length - 1] : null;
      if (prev && s.t - prev.t <= MARK_GAP_MS) {
        if (s.rtt > prev.rtt) {
          prev.t = s.t; prev.rtt = s.rtt; prev.large = !!(s.large || s.rtt >= 200);
        } else if (s.large || s.rtt >= 200) {
          prev.large = true;
        }
        continue;
      }
      markList.push({ t: s.t, rtt: s.rtt, large: !!(s.large || s.rtt >= 200), s });
    }
    let lastLabelX = -1e9;
    for (const s of markList) {
      const x = xOf(s.t, state.v0, state.v1, w);
      const y = h - 20 - (Math.min(maxRtt, s.rtt) / maxRtt) * plotH;
      const large = s.large;
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
      if (x - lastLabelX >= 28) {
        lastLabelX = x;
        const label = s.rtt >= 100 ? `${Math.round(s.rtt)}ms` : `${s.rtt.toFixed(1)}ms`;
        ctx.fillStyle = large ? "#e85d4c" : "#e0a14a";
        ctx.font = "10px Consolas, monospace";
        ctx.textAlign = "left";
        ctx.fillText(label, x + rad + 2, y - 4);
      }
      state.hits.push({ x, y, r: rad + 4, s: s.s || s });
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

    // Bottom times anchored under each expected-slot line
    ctx.fillStyle = "#6b7c8f";
    ctx.font = "10px Consolas, monospace";
    ctx.textAlign = "center";
    let lastSlotLabelX = -1e9;
    for (const t of slotTimes) {
      const x = xOf(t, state.v0, state.v1, w);
      if (x - lastSlotLabelX < 36) continue;
      lastSlotLabelX = x;
      ctx.fillText(fmtTime(t), x, h - 6);
    }
    ctx.textAlign = "left";

    const viewMin = (state.v1 - state.v0) / 60000;
    const dataMin = (state.t1 - state.t0) / 60000;
    els.stats.textContent =
      `spikes ${state.spikes.length} (in view)  samples ${state.samples.length} buckets  ` +
      `view ${viewMin.toFixed(2)} min  data ${dataMin.toFixed(1)} min  cycle=${cycleSec().toFixed(3)}s` +
      (state.cycleSamples >= 10 ? "" : state.cycleSamples > 0 ? ` (learning ${state.cycleSamples}/10)` : "");
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
    const cycle = cycleMs();
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
      else if (majorOnTime(s) || state.slotResults.get(s) === true) fill = "#c0392b";
      else if (state.slotResults.get(s) === false) fill = "#1e8449"; // miss
      else fill = "#3d4f61"; // unresolved
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
      if (els.nowClock) els.nowClock.textContent = fmtTime(wall);
      drawClock();
      tickWarnAudio();
      if (state.dirty || (state.follow && state.recording)) {
        drawMap();
        drawArrows();
        drawMain();
        drawBin();
        renderTally();
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
    const { m0, m1 } = mapRange();
    const t = tOf(p.x, m0, m1, w, 8);
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
        try { await refreshEvents(); } catch {}
      } else if (state.follow && state.recording) {
        // keep pulling samples/spikes while a live run is advancing
        state.needData = true;
      }
      if (state.needData) await refreshWindowData();
    } catch (e) {
      if (API_BASE) setProbeBanner(true);
      const hint = API_BASE
        ? " — start Open-SpikeTimeline.bat, or open http://127.0.0.1:8765/"
        : "";
      els.stats.textContent = `sync: ${e.message}${hint}`;
      if (API_BASE) els.title.textContent = "Waiting for local probe on 127.0.0.1:8765";
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
