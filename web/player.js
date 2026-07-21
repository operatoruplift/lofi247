/* LOFI 247 — web player
   Vanilla JS, no dependencies, no external requests.
   Audio comes from the same-origin /radio proxy; track metadata
   from /nowplaying.json. Both may be absent (local dev) — the page
   degrades to a designed "off air" state and keeps retrying quietly. */
(() => {
  'use strict';

  const STATION_NAME = 'LOFI 247';
  const STATION_FALLBACK_LINE = `${STATION_NAME} — beats till sunrise`;
  const STREAM_URL = '/radio';
  const NOWPLAYING_URL = '/nowplaying.json';
  const CONFIG_URL = '/config.json';
  const POLL_INTERVAL_MS = 5000;
  const OFFLINE_AFTER_FAILURES = 3;
  const AUDIO_RETRY_MS = 6000;
  const VOLUME_STEP = 0.05;
  const TRACK_SWAP_MS = 260;
  const MARQUEE_MIN_OVERFLOW_PX = 8;
  const MARQUEE_PX_PER_SECOND = 18;
  const BAR_COUNT = 48;
  const STORAGE_KEY = 'lofi247-player';

  // Neutral pre-signal copy — the badge must not assert "live" until real audio
  // is proven (a successful nowplaying poll or the audio 'playing' event).
  const CONNECTING_LABEL = 'connecting';
  const CONNECTING_STATUS = 'tuning in…';

  // The active now-playing fallback line. Defaults to the station line above but
  // /config.json (applyStationConfig) can rebrand it at runtime.
  let activeFallbackLine = STATION_FALLBACK_LINE;

  const $ = (id) => document.getElementById(id);
  const els = {
    audio: $('radio-audio'),
    playBtn: $('btn-play'),
    playHint: $('play-hint'),
    muteBtn: $('btn-mute'),
    volume: $('vol'),
    npTrack: $('np-track'),
    npText: $('np-text'),
    liveLabel: $('live-label'),
    statusLine: $('status-line'),
    xLink: $('x-link'),
    canvas: $('viz'),
    wordmarkLofi: document.querySelector('.wordmark-lofi'),
    wordmark247: document.querySelector('.wordmark-247'),
  };

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = window.matchMedia('(pointer: fine)');

  const state = {
    wantsPlayback: false,
    isPlaying: false,
    audioDown: false,
    // Latches true the first time real audio is proven (a successful nowplaying
    // poll or the audio 'playing' event). Until then the badge stays neutral
    // ("connecting") rather than asserting "live" on faith.
    hasSignal: false,
    npFailures: 0,
    trackLine: '',
    retryTimer: 0,
    swapTimer: 0,
    // Source of truth for volume: once the Web Audio graph exists the level
    // lives on a GainNode (iOS ignores element.volume) and element volume
    // pins to 1, so the element can no longer be read back for persistence.
    volume: 0.8,
  };

  /* ---------------------------------------------------------- *
   * audio graph (Web Audio analyser, wired lazily on first play)
   * ---------------------------------------------------------- */

  let audioCtx = null;
  let analyser = null;
  let freqData = null;
  let gainNode = null;

  function wireAudioGraph() {
    // createMediaElementSource throws if called twice for the same
    // element — guard with the context so this only ever runs once.
    if (audioCtx) return;
    const Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return; // playback still works, visualizer stays idle
    // Declared out here so the catch can still reach it: once
    // createMediaElementSource() reroutes the element into the graph, a later
    // node failure would otherwise trap its audio in a dead graph -> silence.
    let source = null;
    try {
      audioCtx = new Ctx();
      source = audioCtx.createMediaElementSource(els.audio);
      analyser = audioCtx.createAnalyser();
      analyser.fftSize = 256;
      analyser.smoothingTimeConstant = 0.82;
      gainNode = audioCtx.createGain();
      source.connect(analyser);
      analyser.connect(gainNode);
      gainNode.connect(audioCtx.destination);
      freqData = new Uint8Array(analyser.frequencyBinCount);
      // Move the volume onto the gain node (audible on iOS, where
      // element.volume is read-only).
      applyVolume(state.volume, { persist: false });
    } catch (err) {
      analyser = null;
      freqData = null;
      gainNode = null;
      // The visualizer graph failed. If the element was already captured,
      // route it straight to the speakers so audio still plays instead of
      // being trapped, silent, in a half-built graph.
      if (source && audioCtx) {
        try {
          source.connect(audioCtx.destination);
        } catch (err2) { /* best effort — nothing more we can do */ }
      }
    }
  }

  /* ---------------------------------------------------------- *
   * playback
   * ---------------------------------------------------------- */

  function startPlayback() {
    state.wantsPlayback = true;
    wireAudioGraph();
    if (audioCtx && audioCtx.state === 'suspended') {
      audioCtx.resume().catch(() => {});
    }
    // (Re)attach the stream and load so we join the live edge instead
    // of a stale buffer — pause detaches src to drop the connection.
    els.audio.src = STREAM_URL;
    els.audio.load();
    const attempt = els.audio.play();
    if (attempt && typeof attempt.catch === 'function') {
      attempt.catch(() => {
        // NotAllowedError (no gesture) or source failure; error events
        // handle the stream-down case, so just settle the UI here.
        if (els.audio.paused) {
          state.isPlaying = false;
          renderPlaybackUi();
        }
      });
    }
    renderPlaybackUi();
  }

  function stopPlayback() {
    state.wantsPlayback = false;
    state.audioDown = false; // stopped by choice — let nowplaying drive the badge
    clearAudioRetry();
    els.audio.pause();
    // Detach the source so the browser releases the icecast connection
    // instead of buffering a live stream forever while paused.
    els.audio.removeAttribute('src');
    els.audio.load();
    renderPlaybackUi();
    renderLiveState();
  }

  function togglePlayback() {
    if (state.wantsPlayback) stopPlayback();
    else startPlayback();
  }

  function clearAudioRetry() {
    if (state.retryTimer) {
      window.clearTimeout(state.retryTimer);
      state.retryTimer = 0;
    }
  }

  function scheduleAudioRetry() {
    if (state.retryTimer || !state.wantsPlayback) return;
    state.retryTimer = window.setTimeout(() => {
      state.retryTimer = 0;
      if (!state.wantsPlayback) return;
      els.audio.src = STREAM_URL;
      els.audio.load();
      const attempt = els.audio.play();
      if (attempt && typeof attempt.catch === 'function') {
        attempt.catch(() => scheduleAudioRetry());
      }
    }, AUDIO_RETRY_MS);
  }

  function handleAudioTrouble() {
    if (!state.wantsPlayback) return;
    state.isPlaying = false;
    state.audioDown = true;
    renderPlaybackUi();
    renderLiveState();
    scheduleAudioRetry();
  }

  function renderPlaybackUi() {
    const playing = state.isPlaying;
    document.body.classList.toggle('is-playing', playing);
    els.playBtn.setAttribute('aria-label', playing ? 'Pause' : 'Play');
    if (playing) {
      els.playHint.textContent = 'on air — you’re tuned in';
    } else if (state.wantsPlayback && state.audioDown) {
      els.playHint.textContent = 'reconnecting to the stream…';
    } else if (state.wantsPlayback) {
      els.playHint.textContent = 'tuning…';
    } else {
      els.playHint.textContent = 'press play to tune in';
    }
  }

  /* ---------------------------------------------------------- *
   * volume
   * ---------------------------------------------------------- */

  function applyVolume(value, { persist = true } = {}) {
    const level = Math.min(1, Math.max(0, value));
    state.volume = level;
    if (gainNode) {
      // Gain carries the level; element volume must sit at 1 or the two
      // multiply and everything plays double-attenuated.
      gainNode.gain.value = level;
      els.audio.volume = 1;
    } else {
      els.audio.volume = level;
    }
    els.volume.value = String(level);
    els.volume.style.setProperty('--fill', `${Math.round(level * 100)}%`);
    // Announce a percentage to assistive tech instead of the raw 0–1 value.
    els.volume.setAttribute('aria-valuetext', `${Math.round(level * 100)}%`);
    if (persist) persistPrefs();
  }

  function setMuted(muted, { persist = true } = {}) {
    els.audio.muted = muted;
    els.muteBtn.classList.toggle('is-muted', muted);
    // No aria-pressed: the Mute/Unmute aria-label already conveys state; pairing
    // both makes AT announce "Unmute, pressed" (double-signalled).
    els.muteBtn.setAttribute('aria-label', muted ? 'Unmute' : 'Mute');
    if (persist) persistPrefs();
  }

  function nudgeVolume(delta) {
    if (els.audio.muted && delta > 0) setMuted(false);
    applyVolume(state.volume + delta);
  }

  function persistPrefs() {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify({
        volume: state.volume,
        muted: els.audio.muted,
      }));
    } catch (err) { /* private mode etc. — non-essential */ }
  }

  function restorePrefs() {
    let prefs = null;
    try {
      prefs = JSON.parse(window.localStorage.getItem(STORAGE_KEY) || 'null');
    } catch (err) { prefs = null; }
    const volume = typeof prefs?.volume === 'number' ? prefs.volume : 0.8;
    applyVolume(volume, { persist: false });
    setMuted(Boolean(prefs?.muted), { persist: false });
  }

  /* ---------------------------------------------------------- *
   * now playing
   * ---------------------------------------------------------- */

  function trackLineFrom(data) {
    const artist = typeof data?.artist === 'string' ? data.artist.trim() : '';
    const title = typeof data?.title === 'string' ? data.title.trim() : '';
    if (artist && title) return `${artist} — ${title}`;
    return title || artist || activeFallbackLine;
  }

  async function pollNowPlaying() {
    if (document.hidden) return; // resumes via visibilitychange
    try {
      const res = await fetch(NOWPLAYING_URL, {
        cache: 'no-store',
        // A hung request must count as a failure, not pile up behind the
        // next poll. (Older browsers without AbortSignal.timeout just skip it.)
        signal: AbortSignal.timeout ? AbortSignal.timeout(4000) : undefined,
      });
      if (!res.ok) throw new Error(`http ${res.status}`);
      const data = await res.json();
      state.npFailures = 0;
      state.hasSignal = true; // real metadata arrived — the stream is proven
      renderTrack(trackLineFrom(data));
    } catch (err) {
      state.npFailures += 1;
      // One dropped poll shouldn't visibly swap the track line (and fire an
      // aria-live announcement); degrade only past the same threshold the
      // badge uses. With nothing known yet, show the station line right away.
      if (!state.trackLine || state.npFailures >= OFFLINE_AFTER_FAILURES) {
        renderTrack(activeFallbackLine);
      }
    }
    renderLiveState();
  }

  function renderTrack(line) {
    if (line === state.trackLine) return;
    state.trackLine = line;
    // Cancel any pending swap in BOTH paths — a stale timer from before a
    // reduced-motion flip would overwrite the new line with the old one.
    window.clearTimeout(state.swapTimer);
    if (reducedMotion.matches) {
      els.npText.textContent = line;
      updateMarquee();
      return;
    }
    els.npText.classList.remove('marquee');
    els.npTrack.classList.add('is-swapping');
    state.swapTimer = window.setTimeout(() => {
      els.npText.textContent = line;
      els.npTrack.classList.remove('is-swapping');
      updateMarquee();
    }, TRACK_SWAP_MS);
  }

  function updateMarquee() {
    const text = els.npText;
    text.classList.remove('marquee');
    text.style.removeProperty('--marquee-shift');
    text.style.removeProperty('--marquee-dur');
    if (reducedMotion.matches) return;
    const overflow = text.scrollWidth - els.npTrack.clientWidth;
    if (overflow > MARQUEE_MIN_OVERFLOW_PX) {
      const seconds = Math.max(8, overflow / MARQUEE_PX_PER_SECOND);
      text.style.setProperty('--marquee-shift', `${-overflow}px`);
      text.style.setProperty('--marquee-dur', `${seconds.toFixed(1)}s`);
      text.classList.add('marquee');
    }
  }

  function renderLiveState() {
    // Until real audio is proven, hold the neutral "connecting" state rather
    // than guessing live/off-air on first paint or during the first outage.
    if (!state.hasSignal) {
      document.body.classList.add('is-connecting');
      document.body.classList.remove('is-offair');
      if (els.liveLabel.textContent !== CONNECTING_LABEL) {
        els.liveLabel.textContent = CONNECTING_LABEL;
      }
      if (els.statusLine.textContent !== CONNECTING_STATUS) {
        els.statusLine.textContent = CONNECTING_STATUS;
      }
      return;
    }
    document.body.classList.remove('is-connecting');
    const offAir = state.audioDown || state.npFailures >= OFFLINE_AFTER_FAILURES;
    document.body.classList.toggle('is-offair', offAir);
    // liveLabel sits in a role=status region: rewriting an identical text
    // node still re-announces in some screen readers, so only write changes.
    const label = offAir ? 'off air' : 'live';
    if (els.liveLabel.textContent !== label) els.liveLabel.textContent = label;
    const status = offAir ? 'signal lost — retrying quietly' : 'signal nominal';
    if (els.statusLine.textContent !== status) els.statusLine.textContent = status;
  }

  /* ---------------------------------------------------------- *
   * visualizer (canvas, devicePixelRatio-aware)
   * ---------------------------------------------------------- */

  function createVisualizer(canvas) {
    const brush = canvas.getContext('2d');
    if (!brush) return { refresh: () => {} };

    const levels = new Float32Array(BAR_COUNT);
    let width = 0;
    let height = 0;
    let gradient = null;
    let rafId = 0;

    function resize() {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const rect = canvas.getBoundingClientRect();
      width = Math.max(1, Math.round(rect.width * dpr));
      height = Math.max(1, Math.round(rect.height * dpr));
      canvas.width = width;
      canvas.height = height;
      gradient = brush.createLinearGradient(0, height, 0, 0);
      gradient.addColorStop(0, '#f2a65a');
      gradient.addColorStop(0.55, '#e07a5f');
      gradient.addColorStop(1, '#b0567c');
    }

    function idleLevel(i, now) {
      const wave = Math.sin(now / 900 + i * 0.35) + Math.sin(now / 1400 + i * 0.9);
      return 0.07 + 0.035 * (wave + 2) * 0.5;
    }

    function liveLevel(i) {
      const bins = freqData.length;
      const idx = Math.min(
        bins - 1,
        Math.floor(Math.pow(i / BAR_COUNT, 1.6) * (bins - 6))
      );
      return Math.max(0.03, freqData[idx] / 255);
    }

    function drawBars() {
      brush.clearRect(0, 0, width, height);
      const baseline = height * 0.8;
      const slot = width / BAR_COUNT;
      const barW = Math.max(2, slot * 0.6);
      brush.fillStyle = gradient;
      for (let i = 0; i < BAR_COUNT; i += 1) {
        const h = Math.max(2, levels[i] * baseline * 0.96);
        const x = i * slot + (slot - barW) / 2;
        drawRoundedBar(x, baseline - h, barW, h);
      }
      // soft reflection below the baseline
      brush.save();
      brush.globalAlpha = 0.16;
      for (let i = 0; i < BAR_COUNT; i += 1) {
        const h = Math.max(2, levels[i] * baseline * 0.28);
        const x = i * slot + (slot - barW) / 2;
        brush.fillRect(x, baseline + 2, barW, h);
      }
      brush.restore();
    }

    function drawRoundedBar(x, y, w, h) {
      const r = Math.min(w / 2, 4);
      if (typeof brush.roundRect === 'function') {
        brush.beginPath();
        brush.roundRect(x, y, w, h, [r, r, 0, 0]);
        brush.fill();
      } else {
        brush.fillRect(x, y, w, h);
      }
    }

    let lastIdlePaint = 0;

    function frame(now) {
      const live = analyser && state.isPlaying && freqData;
      // Idle ambience doesn't need 60fps — ~24fps halves the battery cost
      // of a page that's just sitting there looking pretty.
      if (!live && now - lastIdlePaint < 41) {
        rafId = window.requestAnimationFrame(frame);
        return;
      }
      lastIdlePaint = now;
      if (live) analyser.getByteFrequencyData(freqData);
      for (let i = 0; i < BAR_COUNT; i += 1) {
        const target = live ? liveLevel(i) : idleLevel(i, now);
        levels[i] += (target - levels[i]) * 0.22;
      }
      drawBars();
      rafId = window.requestAnimationFrame(frame);
    }

    function drawStatic() {
      for (let i = 0; i < BAR_COUNT; i += 1) {
        levels[i] = 0.07 + 0.05 * Math.abs(Math.sin(i * 0.42));
      }
      drawBars();
    }

    function start() {
      stop();
      resize();
      if (reducedMotion.matches) drawStatic();
      else rafId = window.requestAnimationFrame(frame);
    }

    function stop() {
      if (rafId) {
        window.cancelAnimationFrame(rafId);
        rafId = 0;
      }
    }

    let resizeTimer = 0;
    window.addEventListener('resize', () => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        start();
        updateMarquee();
      }, 150);
    });

    document.addEventListener('visibilitychange', () => {
      if (document.hidden) stop();
      else start();
    });

    start();
    return { refresh: start };
  }

  /* ---------------------------------------------------------- *
   * parallax (mouse only, motion permitting)
   * ---------------------------------------------------------- */

  function initParallax() {
    if (reducedMotion.matches || !finePointer.matches) return;
    const layers = Array.from(document.querySelectorAll('[data-depth]'));
    if (!layers.length) return;
    const depths = layers.map((el) => Number(el.dataset.depth) || 0);
    let targetX = 0;
    let targetY = 0;
    let currentX = 0;
    let currentY = 0;
    let rafId = 0;

    function step() {
      rafId = 0;
      if (reducedMotion.matches) return; // honor a mid-session toggle
      currentX += (targetX - currentX) * 0.06;
      currentY += (targetY - currentY) * 0.06;
      layers.forEach((el, i) => {
        const d = depths[i];
        el.style.transform =
          `translate3d(${(-currentX * d).toFixed(2)}px, ${(-currentY * d * 0.5).toFixed(2)}px, 0)`;
      });
      const settled =
        Math.abs(targetX - currentX) < 0.001 && Math.abs(targetY - currentY) < 0.001;
      if (!settled) rafId = window.requestAnimationFrame(step);
    }

    window.addEventListener('pointermove', (event) => {
      if (reducedMotion.matches) return; // honor a mid-session toggle
      targetX = event.clientX / window.innerWidth - 0.5;
      targetY = event.clientY / window.innerHeight - 0.5;
      if (!rafId) rafId = window.requestAnimationFrame(step);
    }, { passive: true });
  }

  /* ---------------------------------------------------------- *
   * keyboard
   * ---------------------------------------------------------- */

  function isInteractive(target) {
    if (!(target instanceof HTMLElement)) return false;
    return (
      ['INPUT', 'BUTTON', 'A', 'SELECT', 'TEXTAREA'].includes(target.tagName) ||
      target.isContentEditable
    );
  }

  function onKeyDown(event) {
    if (event.repeat) return; // a held spacebar must not thrash the stream
    if (event.code === 'Space' && !isInteractive(event.target)) {
      event.preventDefault();
      togglePlayback();
    } else if (event.key === 'ArrowUp' && !isInteractive(event.target)) {
      event.preventDefault();
      nudgeVolume(VOLUME_STEP);
    } else if (event.key === 'ArrowDown' && !isInteractive(event.target)) {
      event.preventDefault();
      nudgeVolume(-VOLUME_STEP);
    }
  }

  /* ---------------------------------------------------------- *
   * boot
   * ---------------------------------------------------------- */

  function initXLink() {
    const handle = (els.xLink.dataset.xHandle || '').trim().replace(/^@/, '');
    if (handle) els.xLink.href = `https://x.com/${handle}`;
  }

  /* ---------------------------------------------------------- *
   * station identity (optional branding from /config.json)
   * ---------------------------------------------------------- */

  function applyStationName(name) {
    const station = typeof name === 'string' ? name.trim() : '';
    if (!station) return;
    activeFallbackLine = `${station} — beats till sunrise`;
    document.title = activeFallbackLine;
    // Split on the LAST space: first part -> .wordmark-lofi, last token ->
    // .wordmark-247 (so "LOFI 247" reproduces exactly and "MIDNIGHT FM" ->
    // "MIDNIGHT"/"FM"). A single-word name fills lofi and empties 247.
    const lastSpace = station.lastIndexOf(' ');
    if (els.wordmarkLofi) {
      els.wordmarkLofi.textContent =
        lastSpace === -1 ? station : station.slice(0, lastSpace);
    }
    if (els.wordmark247) {
      els.wordmark247.textContent =
        lastSpace === -1 ? '' : station.slice(lastSpace + 1);
    }
  }

  async function applyStationConfig() {
    let config = null;
    try {
      const res = await fetch(CONFIG_URL, { cache: 'no-store' });
      if (!res.ok) throw new Error(`http ${res.status}`);
      config = await res.json();
    } catch (err) {
      // No /config.json (local dev, or a 404) — keep every hardcoded default,
      // including the data-x-handle link wired by initXLink(). Never throw:
      // a config failure must not touch playback.
      return;
    }
    const handle = typeof config?.handle === 'string'
      ? config.handle.trim().replace(/^@/, '')
      : '';
    // A config-supplied handle replaces the data-x-handle fallback.
    if (handle) els.xLink.href = `https://x.com/${handle}`;
    applyStationName(config?.station);
  }

  function initAudioEvents() {
    els.audio.addEventListener('playing', () => {
      state.isPlaying = true;
      state.audioDown = false;
      state.hasSignal = true; // audio is actually flowing — proven live
      clearAudioRetry();
      renderPlaybackUi();
      renderLiveState();
    });
    els.audio.addEventListener('pause', () => {
      state.isPlaying = false;
      renderPlaybackUi();
    });
    els.audio.addEventListener('error', handleAudioTrouble);
    els.audio.addEventListener('ended', handleAudioTrouble); // live streams don't end
  }

  function initControls() {
    els.playBtn.addEventListener('click', togglePlayback);
    els.muteBtn.addEventListener('click', () => setMuted(!els.audio.muted));
    els.volume.addEventListener('input', () => {
      const value = Number.parseFloat(els.volume.value);
      if (els.audio.muted && value > 0) setMuted(false);
      applyVolume(value);
    });
    document.addEventListener('keydown', onKeyDown);
  }

  function boot() {
    restorePrefs();
    initXLink();
    // Overrides the X link + station name from /config.json when present;
    // silently keeps the hardcoded defaults on failure (local dev has none).
    applyStationConfig();
    initAudioEvents();
    initControls();
    initParallax();
    const viz = createVisualizer(els.canvas);
    reducedMotion.addEventListener?.('change', () => {
      viz.refresh();
      updateMarquee();
    });
    pollNowPlaying();
    window.setInterval(pollNowPlaying, POLL_INTERVAL_MS);
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) pollNowPlaying(); // catch up right away
    });
    updateMarquee();
  }

  boot();
})();
