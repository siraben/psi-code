/* Host dashboard glue: mounts the shared chat module and renders
 * serial / stats / gpio frames coming from esp_frontend.py over the
 * /serial WebSocket. */
(function () {
  'use strict';

  const SERIAL_URL = (location.protocol === 'https:' ? 'wss://' : 'ws://')
                   + location.host + '/serial';
  const CHAT_URL = (location.protocol === 'https:' ? 'wss://' : 'ws://')
                 + location.host + '/chat';
  const MAX_LINES = 1000;

  function fmtBytes(n) {
    if (n == null) return '—';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KiB';
    return (n / (1024 * 1024)).toFixed(2) + ' MiB';
  }
  function fmtDuration(s) {
    if (s == null) return '—';
    if (s < 60) return s.toFixed(1) + 's';
    const m = Math.floor(s / 60);
    const r = (s - m * 60) | 0;
    return m + 'm' + r + 's';
  }

  const chatRoot = document.getElementById('chat-root');
  createPsiChat({
    container: chatRoot,
    wsUrl: CHAT_URL,
    title: 'esp32 chat',
    welcome: 'Talking to the ESP via the host bridge. Try ' +
             '<code>system_info</code> or <code>lua_eval</code> ' +
             'and watch the serial log on the right.',
  });

  const serialLog = document.getElementById('serial-log');
  const qemuStatus = document.getElementById('qemu-status');
  const stats = {
    uptime: document.getElementById('stat-uptime'),
    heapFree: document.getElementById('stat-heap-free'),
    heapMin: document.getElementById('stat-heap-min'),
    psramFree: document.getElementById('stat-psram-free'),
    ip: document.getElementById('stat-ip'),
    tasks: document.getElementById('stat-tasks'),
  };
  const clearBtn = document.getElementById('serial-clear');
  const gpioSection = document.getElementById('gpio-section');
  const gpioGrid = document.getElementById('gpio-grid');

  // Pin grid is built once; applyGpio mutates className/title only on
  // pins whose state actually changed since the prior snapshot.
  const PIN_COUNT = 40;
  const pinEls = new Array(PIN_COUNT);
  const pinPrev = new Array(PIN_COUNT);
  for (let i = 0; i < PIN_COUNT; i++) {
    const el = document.createElement('div');
    el.className = 'pin mode-off';
    const num = document.createElement('div');
    num.className = 'num'; num.textContent = i;
    const dot = document.createElement('div'); dot.className = 'lvl';
    el.appendChild(num); el.appendChild(dot);
    el.title = 'GPIO ' + i + ': not configured';
    el._dot = dot;
    gpioGrid.appendChild(el);
    pinEls[i] = el;
    pinPrev[i] = '';
  }

  function applyGpio(snap) {
    const pins = snap.pins || [];
    for (let i = 0; i < pins.length && i < PIN_COUNT; i++) {
      const p = pins[i];
      const mode = p.mode || 'off';
      const lvl = (p.level == null) ? null : (p.level | 0);
      const unknown = p.unknown === true || lvl == null;
      // Cheap fingerprint guards the DOM writes: at 2 Hz with mostly
      // static pins, this skips ~all 40 className/title updates.
      const fp = mode + ':' + lvl + ':' + (unknown ? 1 : 0);
      if (pinPrev[p.n] === fp) continue;
      pinPrev[p.n] = fp;
      const el = pinEls[p.n];
      let cls = 'pin mode-' + mode;
      if (mode === 'out' && lvl != null) cls += ' lvl-' + lvl;
      el.className = cls;
      el._dot.classList.toggle('unknown', unknown);
      el.title = 'GPIO ' + p.n + ': ' + mode +
                 (lvl == null ? '' : ' = ' + lvl) +
                 (p.unknown ? ' (unknown)' : '');
    }
  }

  let lineCount = 0;
  function appendLine(item) {
    const pinned = serialLog.scrollHeight - serialLog.scrollTop - serialLog.clientHeight <= 60;
    const div = document.createElement('div');
    if (item.type === 'log') {
      div.className = 'line ' + (item.level || 'I');
      const lvl = document.createElement('span');
      lvl.className = 'lvl';
      lvl.textContent = item.level || '·';
      const tag = document.createElement('span');
      tag.className = 'tag';
      tag.textContent = item.tag || '';
      const msg = document.createElement('span');
      msg.className = 'msg';
      msg.textContent = item.message || '';
      div.appendChild(lvl); div.appendChild(tag); div.appendChild(msg);
    } else {
      div.className = 'line raw';
      const lvl = document.createElement('span');
      lvl.className = 'lvl';
      lvl.textContent = '·';
      const tag = document.createElement('span'); tag.className = 'tag'; tag.textContent = '';
      const msg = document.createElement('span'); msg.className = 'msg';
      msg.textContent = item.line || '';
      div.appendChild(lvl); div.appendChild(tag); div.appendChild(msg);
    }
    serialLog.appendChild(div);
    lineCount++;
    while (lineCount > MAX_LINES && serialLog.firstChild) {
      serialLog.removeChild(serialLog.firstChild);
      lineCount--;
    }
    if (pinned) serialLog.scrollTop = serialLog.scrollHeight;
  }

  function applyStats(m) {
    if (m.uptime_s != null) stats.uptime.textContent = fmtDuration(m.uptime_s);
    if (m.heap_free != null) stats.heapFree.textContent = fmtBytes(m.heap_free);
    if (m.heap_min != null) stats.heapMin.textContent = fmtBytes(m.heap_min);
    if (m.psram_free != null) stats.psramFree.textContent = fmtBytes(m.psram_free);
    if (m.ip) stats.ip.textContent = m.ip;
    if (m.tasks != null) stats.tasks.textContent = String(m.tasks);
  }

  function setQemuState(state) {
    qemuStatus.className = 'qemu-status ' + state;
    qemuStatus.querySelector('.label').textContent = state;
  }

  function connectSerial() {
    setQemuState('connecting');
    const ws = new WebSocket(SERIAL_URL);
    ws.onopen = function () {
      setQemuState('up');
      // Replay the backlog so a page loaded after boot still sees it.
      ws.send(JSON.stringify({ type: 'replay' }));
    };
    ws.onclose = function () {
      setQemuState('down');
      setTimeout(connectSerial, 1500);
    };
    ws.onerror = function () {};
    ws.onmessage = function (ev) {
      let m;
      try { m = JSON.parse(ev.data); } catch (_) {
        appendLine({ type: 'raw', line: ev.data });
        return;
      }
      if (m.type === 'log' || m.type === 'raw') appendLine(m);
      else if (m.type === 'stats') applyStats(m);
      else if (m.type === 'gpio') applyGpio(m);
      else if (m.type === 'gpio_unavailable') {
        if (gpioSection) gpioSection.style.display = 'none';
      }
      else if (m.type === 'qemu_state') setQemuState(m.state);
    };
  }

  clearBtn.addEventListener('click', function () {
    while (serialLog.firstChild) serialLog.removeChild(serialLog.firstChild);
    lineCount = 0;
  });

  connectSerial();
})();
