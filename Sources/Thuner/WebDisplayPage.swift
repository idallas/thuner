/// The web display page, served by WebDisplayServer. Self-contained: no external scripts, fonts or styles.
enum WebDisplayPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ThUNER</title>
<style>
  :root { --bg: #070708; --text: #f2f0ec; --muted: rgba(242,240,236,.62); --accent: #ff7f22; }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text); overflow: hidden;
    font: 16px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", Helvetica, Arial, sans-serif;
    -webkit-font-smoothing: antialiased; }
  body.hide-cursor { cursor: none; }
  .mode { position: absolute; inset: 0; display: none; }
  body[data-mode="tuneshine"] #tuneshine, body[data-mode="cover"] #cover { display: flex; }

  /* Tuneshine: a 64×64 LED panel in a dark frame */
  #tuneshine { align-items: center; justify-content: center; flex-direction: column; gap: 3.5vmin;
    background: radial-gradient(ellipse at 50% 40%, #1a1a1d 0%, #070708 70%); }
  .device { --size: min(82vmin, 900px); width: var(--size); height: var(--size); padding: calc(var(--size) * .055);
    border-radius: calc(var(--size) * .035);
    background: linear-gradient(145deg, #2c2c30 0%, #18181b 55%, #101012 100%);
    box-shadow: 0 2.5vmin 7vmin rgba(0,0,0,.65), inset 0 1px 0 rgba(255,255,255,.08), inset 0 -1px 0 rgba(0,0,0,.6); }
  .panel { position: relative; width: 100%; height: 100%; background: #000; border-radius: calc(var(--size) * .008);
    overflow: hidden; box-shadow: inset 0 0 calc(var(--size) * .02) rgba(0,0,0,.9); }
  .panel canvas { position: absolute; inset: 0; width: 100%; height: 100%; image-rendering: pixelated;
    filter: saturate(1.25) contrast(1.08); transition: opacity 1.2s ease; }
  .panel .glow { filter: blur(calc(var(--size) * .012)) saturate(1.4); opacity: .32; mix-blend-mode: screen; }
  /* Each pixel becomes a round LED with dark gaps between them. */
  .panel .leds { position: absolute; inset: 0; pointer-events: none;
    background: radial-gradient(circle at center, transparent 0, transparent 52%, rgba(0,0,0,.92) 66%, #000 72%);
    background-size: calc(100% / 64) calc(100% / 64); }
  .panel.dim canvas { opacity: .55; }
  .caption { text-align: center; color: var(--muted); font-size: clamp(14px, 1.9vmin, 22px); min-height: 1.3em;
    transition: opacity .6s ease; max-width: 82vmin; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .caption b { color: var(--text); font-weight: 600; }
  body.no-caption .caption { display: none; }

  /* Large cover */
  #cover { align-items: center; justify-content: center; }
  .backdrop { position: absolute; inset: -10%; background-size: cover; background-position: center;
    filter: blur(70px) brightness(.45) saturate(1.3); transform: scale(1.1); transition: opacity 1s ease; }
  .stage { position: relative; display: flex; align-items: center; gap: 5vw; padding: 5vmin; width: 100%;
    justify-content: center; }
  .art { width: min(78vh, 52vw); aspect-ratio: 1; border-radius: 1.2vmin; background: #151517 center / cover;
    box-shadow: 0 3vmin 9vmin rgba(0,0,0,.6); flex: none; transition: opacity .7s ease; }
  .meta { max-width: 36vw; }
  .meta .title { font-size: clamp(28px, 5.2vmin, 72px); font-weight: 700; letter-spacing: -.02em; line-height: 1.08; }
  .meta .artist { font-size: clamp(20px, 3.4vmin, 44px); margin-top: .5em; }
  .meta .album { font-size: clamp(16px, 2.4vmin, 30px); color: var(--muted); margin-top: .35em; }
  .meta .source { font-size: clamp(12px, 1.6vmin, 18px); color: var(--muted); margin-top: 2.2em;
    text-transform: uppercase; letter-spacing: .12em; }
  .wordmark { font-weight: 800; letter-spacing: .08em; }
  .wordmark .t, .wordmark .uner { color: var(--accent); }
  .wordmark .h { font-weight: 400; color: var(--muted); }
  @media (orientation: portrait) {
    .stage { flex-direction: column; gap: 4vh; text-align: center; }
    .art { width: min(84vw, 60vh); }
    .meta { max-width: 88vw; }
  }
  .stage.idle { text-align: center; }
  .stage.idle .meta { max-width: none; }
  .idle-clock { font-size: clamp(48px, 14vmin, 200px); font-weight: 200; letter-spacing: -.02em; color: var(--muted); }

  /* Controls, shown briefly on mouse movement */
  .controls { position: fixed; top: 16px; right: 16px; display: flex; gap: 8px; opacity: 0; transition: opacity .3s;
    z-index: 10; }
  body.show-controls .controls { opacity: 1; }
  .controls button { font: inherit; font-size: 13px; color: var(--text); background: rgba(255,255,255,.12);
    border: 1px solid rgba(255,255,255,.18); border-radius: 8px; padding: 6px 12px; cursor: pointer;
    backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); }
  .controls button[aria-pressed="true"] { background: var(--accent); border-color: var(--accent); color: #fff; }
  .offline { position: fixed; bottom: 16px; left: 50%; transform: translateX(-50%); font-size: 13px;
    color: var(--muted); display: none; }
  body.is-offline .offline { display: block; }
</style>
</head>
<body data-mode="tuneshine">
  <div class="controls">
    <button id="btn-tuneshine" aria-pressed="true">Tuneshine</button>
    <button id="btn-cover" aria-pressed="false">Cover</button>
    <button id="btn-full">Full Screen</button>
  </div>

  <section class="mode" id="tuneshine">
    <div class="device"><div class="panel" id="panel">
      <canvas id="led" width="64" height="64"></canvas>
      <canvas id="led-glow" class="glow" width="64" height="64"></canvas>
      <div class="leds"></div>
    </div></div>
    <div class="caption" id="caption"></div>
  </section>

  <section class="mode" id="cover">
    <div class="backdrop" id="backdrop"></div>
    <div class="stage" id="stage">
      <div class="art" id="art"></div>
      <div class="meta">
        <div class="title" id="title"></div>
        <div class="artist" id="artist"></div>
        <div class="album" id="album"></div>
        <div class="source" id="source"></div>
      </div>
    </div>
  </section>

  <div class="offline">Waiting for <span class="wordmark"><span class="t">T</span><span class="h">h</span><span class="uner">UNER</span></span>…</div>

<script>
(() => {
  const params = new URLSearchParams(location.search);
  const body = document.body;
  let mode = params.get('mode') === 'cover' || location.pathname === '/cover' ? 'cover' : 'tuneshine';
  if (params.get('caption') === '0') body.classList.add('no-caption');
  let now = { state: 'idle' }, version = -1, shownArt = null;

  // Apple's image CDN serves any size: ask for what each mode needs.
  function sized(url, px) {
    if (!url) return null;
    url = url.replace(/^http:/, 'https:');
    return /mzstatic\.com/.test(url) ? url.replace(/\/\d+x\d+bb\.\w+$/, `/${px}x${px}bb.jpg`) : url;
  }

  function setMode(m) {
    mode = m;
    body.dataset.mode = m;
    document.getElementById('btn-tuneshine').setAttribute('aria-pressed', m === 'tuneshine');
    document.getElementById('btn-cover').setAttribute('aria-pressed', m === 'cover');
    const p = new URLSearchParams(location.search); p.set('mode', m);
    history.replaceState(null, '', '?' + p.toString());
    shownArt = null;
    render();
  }

  // ---- Tuneshine: draw the cover into a 64×64 canvas, revealed with a random-pixel dissolve ----
  const led = document.getElementById('led'), glow = document.getElementById('led-glow');
  const ledCtx = led.getContext('2d'), glowCtx = glow.getContext('2d');
  const staging = document.createElement('canvas'); staging.width = staging.height = 64;
  const stagingCtx = staging.getContext('2d');
  let dissolveTimer = null;

  function dissolveTo(source) {
    clearInterval(dissolveTimer);
    const order = [...Array(4096).keys()];
    for (let i = order.length - 1; i > 0; i--) { const j = Math.random() * (i + 1) | 0; [order[i], order[j]] = [order[j], order[i]]; }
    let index = 0;
    dissolveTimer = setInterval(() => {
      // ~1s total: about 70 pixels per frame at 60fps.
      for (let n = 0; n < 72 && index < order.length; n++, index++) {
        const x = order[index] % 64, y = order[index] / 64 | 0;
        ledCtx.drawImage(source, x, y, 1, 1, x, y, 1, 1);
      }
      glowCtx.clearRect(0, 0, 64, 64); glowCtx.drawImage(led, 0, 0);
      if (index >= order.length) clearInterval(dissolveTimer);
    }, 16);
  }

  function drawClock() {
    stagingCtx.fillStyle = '#000'; stagingCtx.fillRect(0, 0, 64, 64);
    const t = new Date(), hh = t.getHours() % 12 || 12, mm = String(t.getMinutes()).padStart(2, '0');
    stagingCtx.fillStyle = '#ff7f22'; stagingCtx.textAlign = 'center'; stagingCtx.textBaseline = 'middle';
    stagingCtx.font = 'bold 15px -apple-system, Helvetica, Arial, sans-serif';
    stagingCtx.fillText(`${hh}:${mm}`, 32, 33);
    ledCtx.drawImage(staging, 0, 0); glowCtx.clearRect(0, 0, 64, 64); glowCtx.drawImage(led, 0, 0);
  }

  function renderTuneshine() {
    const panel = document.getElementById('panel'), caption = document.getElementById('caption');
    const art = sized(now.artwork, 128);
    panel.classList.toggle('dim', now.state !== 'playing');
    caption.innerHTML = now.title ? `<b>${esc(now.title)}</b> · ${esc(now.artist || '')}` : '';
    if (!art) { shownArt = null; drawClock(); return; }
    if (art === shownArt) return;
    shownArt = art;
    const img = new Image();
    img.onload = () => {
      stagingCtx.imageSmoothingQuality = 'high';
      stagingCtx.clearRect(0, 0, 64, 64);
      stagingCtx.drawImage(img, 0, 0, 64, 64);
      dissolveTo(staging);
    };
    img.src = art;
  }

  // ---- Large cover ----
  function renderCover() {
    const art = sized(now.artwork, 1200);
    const el = id => document.getElementById(id);
    if (art !== shownArt) {
      shownArt = art;
      const artEl = el('art'), back = el('backdrop');
      artEl.style.opacity = 0; back.style.opacity = 0;
      const apply = () => {
        artEl.style.backgroundImage = art ? `url("${art}")` : 'none';
        back.style.backgroundImage = art ? `url("${art}")` : 'none';
        artEl.style.opacity = 1; back.style.opacity = 1;
      };
      if (art) { const img = new Image(); img.onload = apply; img.onerror = apply; img.src = art; } else apply();
    }
    el('art').style.display = art ? '' : 'none';
    el('stage').classList.toggle('idle', !now.title);
    if (now.title) {
      el('title').textContent = now.title;
      el('artist').textContent = now.artist || '';
      el('album').textContent = now.album || '';
      el('source').innerHTML = now.source ? esc(now.source) : '';
    } else {
      const t = new Date();
      el('title').innerHTML = `<div class="idle-clock">${t.getHours() % 12 || 12}:${String(t.getMinutes()).padStart(2, '0')}</div>`;
      el('artist').textContent = now.state === 'identifying' ? 'Listening…' : '';
      el('album').textContent = '';
      el('source').innerHTML = '<span class="wordmark"><span class="t">T</span><span class="h">h</span><span class="uner">UNER</span></span>';
    }
  }

  function render() { mode === 'cover' ? renderCover() : renderTuneshine(); }
  function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]); }

  async function poll() {
    try {
      const response = await fetch('/now.json', { cache: 'no-store' });
      const data = await response.json();
      body.classList.remove('is-offline');
      if (data.version !== version) { version = data.version; now = data; render(); }
    } catch (e) {
      body.classList.add('is-offline');
    }
  }

  // Keep the idle clocks ticking.
  setInterval(() => { if (!now.artwork) render(); }, 15000);
  setInterval(poll, 1000);
  poll();

  // ---- Controls ----
  document.getElementById('btn-tuneshine').onclick = () => setMode('tuneshine');
  document.getElementById('btn-cover').onclick = () => setMode('cover');
  const fullscreen = () => document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen?.();
  document.getElementById('btn-full').onclick = fullscreen;
  document.addEventListener('dblclick', fullscreen);
  document.addEventListener('keydown', e => {
    if (e.key === 'm' || e.key === 'M') setMode(mode === 'cover' ? 'tuneshine' : 'cover');
    if (e.key === 'f' || e.key === 'F') fullscreen();
  });
  let idleTimer;
  document.addEventListener('mousemove', () => {
    body.classList.add('show-controls'); body.classList.remove('hide-cursor');
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => { body.classList.remove('show-controls'); body.classList.add('hide-cursor'); }, 2500);
  });

  setMode(mode);
})();
</script>
</body>
</html>
"""#
}
