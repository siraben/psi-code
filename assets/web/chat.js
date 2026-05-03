/* createPsiChat({container, wsUrl, ...}) — mounts a streaming chat UI
 * inside `container` and owns its WebSocket. Used by both the
 * firmware-embedded SPA and the host dashboard. */
(function (global) {
  'use strict';

  function loadCdnLibs() {
    if (window.__psiCdnLoaded) return window.__psiCdnLoaded;
    // "@" is built at runtime so the literal "name@version" pattern
    // never appears in HTML attrs — dodges Cloudflare email-
    // obfuscation rewrites that otherwise mangle the CDN URL.
    const AT = String.fromCharCode(64);
    const CDN = 'https://cdn.jsdelivr.net/npm/';
    const libs = [
      { kind: 'css',    pkg: 'highlight.js', ver: '11.10.0', path: '/styles/github-dark.min.css' },
      { kind: 'script', pkg: 'marked',       ver: '15.0.7',  path: '/lib/marked.umd.min.js' },
      { kind: 'script', pkg: 'dompurify',    ver: '3.2.7',   path: '/dist/purify.min.js' },
      { kind: 'script', pkg: 'highlight.js', ver: '11.10.0', path: '/build/highlight.min.js' },
    ];
    libs.forEach(function (l) {
      const href = CDN + l.pkg + AT + l.ver + l.path;
      let el;
      if (l.kind === 'css') {
        el = document.createElement('link');
        el.rel = 'stylesheet';
        el.href = href;
      } else {
        el = document.createElement('script');
        el.src = href;
        el.defer = true;
      }
      document.head.appendChild(el);
    });
    window.__psiCdnLoaded = new Promise(function (resolve) {
      const tick = function () {
        if (window.marked && window.DOMPurify && window.hljs) resolve();
        else setTimeout(tick, 30);
      };
      tick();
    });
    return window.__psiCdnLoaded;
  }

  function createPsiChat(opts) {
    const container = opts.container;
    const wsUrl = opts.wsUrl;
    const welcomeText = opts.welcome ||
      'Connected. Try a tool like <code>system_info</code> or just chat.';
    const model = opts.model || 'claude-haiku-4-5';
    const maxTokens = opts.maxTokens || 1024;
    const ready = loadCdnLibs();

    container.classList.add('psi-chat');
    container.innerHTML =
      '<div class="psi-chat-header">' +
      '  <span class="dot" aria-label="connection status"></span>' +
      '  <h1>' + (opts.title || 'psi') + '</h1>' +
      '  <span class="meta">connecting…</span>' +
      '</div>' +
      '<div class="psi-chat-main">' +
      '  <div class="column">' +
      '    <div class="welcome">' + welcomeText + '</div>' +
      '  </div>' +
      '</div>' +
      '<div class="psi-chat-footer">' +
      '  <div class="column">' +
      '    <form>' +
      '      <textarea rows="1" placeholder="message…" autofocus></textarea>' +
      '      <button type="submit">send</button>' +
      '    </form>' +
      '  </div>' +
      '</div>';

    const dot = container.querySelector('.dot');
    const meta = container.querySelector('.meta');
    const main = container.querySelector('.psi-chat-main');
    const col = container.querySelector('.column');
    const welcome = container.querySelector('.welcome');
    const form = container.querySelector('form');
    const ta = container.querySelector('textarea');
    const send = container.querySelector('button');

    let ws, current = null, busy = false, currentRaw = '';
    const toolElems = new Map();

    // Only force-scroll if the user was already at the bottom; once
    // they scroll up to read history, deltas land below the viewport
    // without yanking them back.
    const STICK_THRESHOLD_PX = 96;
    function isPinned() {
      return main.scrollHeight - main.scrollTop - main.clientHeight <= STICK_THRESHOLD_PX;
    }
    function maybeScroll(wasPinned) {
      if (wasPinned) main.scrollTop = main.scrollHeight;
    }

    function clearWelcome() {
      if (welcome && welcome.parentNode) welcome.remove();
    }
    function append(el) {
      const pinned = isPinned();
      clearWelcome();
      col.appendChild(el);
      maybeScroll(pinned);
      return el;
    }
    function bubble(cls, text) {
      const el = document.createElement('div');
      el.className = 'bubble ' + cls;
      if (text != null) el.textContent = text;
      return append(el);
    }
    function makeAssistantBubble() {
      const el = document.createElement('div');
      el.className = 'bubble assistant md';
      return append(el);
    }
    function renderMarkdown(el, raw) {
      const pinned = isPinned();
      if (!window.marked || !window.DOMPurify) {
        el.textContent = raw;
        maybeScroll(pinned);
        return;
      }
      const html = window.marked.parse(raw, { breaks: true, gfm: true });
      el.innerHTML = window.DOMPurify.sanitize(html);
      if (window.hljs) {
        el.querySelectorAll('pre code').forEach(function (b) {
          window.hljs.highlightElement(b);
        });
      }
      maybeScroll(pinned);
    }
    function pretty(o) {
      try { return JSON.stringify(o, null, 2); } catch (_) { return String(o); }
    }
    function tool(name, id, input, ok) {
      const det = document.createElement('details');
      det.className = 'tool';
      det.dataset.id = id || '';
      const sum = document.createElement('summary');
      const nameEl = document.createElement('span');
      nameEl.className = 'name';
      nameEl.textContent = name + (ok === false ? ' ✕' : ok === true ? ' ✓' : ' …');
      sum.appendChild(nameEl);
      if (id) {
        const idEl = document.createElement('span');
        idEl.className = 'id';
        idEl.textContent = id.slice(-8);
        sum.appendChild(idEl);
      }
      det.appendChild(sum);
      const body = document.createElement('div');
      body.className = 'body';
      if (input != null) {
        const lab = document.createElement('div');
        lab.className = 'label'; lab.textContent = 'input';
        body.appendChild(lab);
        const pre = document.createElement('pre');
        pre.textContent = typeof input === 'string' ? input : pretty(input);
        body.appendChild(pre);
      }
      det.appendChild(body);
      det._body = body;
      return append(det);
    }
    function attachToolResult(det, output, ok) {
      if (!det) return;
      const pinned = isPinned();
      const sum = det.querySelector('summary .name');
      if (sum) {
        const txt = sum.textContent.replace(/[\s✓✕…]+$/, '');
        sum.textContent = txt + (ok ? ' ✓' : ' ✕');
      }
      const lab = document.createElement('div');
      lab.className = 'label'; lab.textContent = 'output';
      det._body.appendChild(lab);
      const pre = document.createElement('pre');
      pre.textContent = typeof output === 'string' ? output : pretty(output);
      det._body.appendChild(pre);
      maybeScroll(pinned);
    }
    function setBusy(b) {
      busy = b;
      send.textContent = b ? 'abort' : 'send';
      send.classList.toggle('abort', b);
      send.disabled = false;
      if (dot.classList.contains('off')) return;
      dot.classList.toggle('busy', b);
    }
    function ensureCurrent() {
      if (!current || current._kind === 'thinking') {
        current = makeAssistantBubble();
        current._kind = 'assistant';
        currentRaw = '';
      }
      return current;
    }
    function flushAssistant() {
      if (current) {
        if (current._kind === 'assistant') renderMarkdown(current, currentRaw);
        current = null;
        currentRaw = '';
      }
    }

    function connect() {
      ws = new WebSocket(wsUrl);
      ws.onopen = function () {
        dot.classList.remove('off');
        meta.textContent = 'connected';
      };
      ws.onclose = function () {
        dot.classList.add('off');
        dot.classList.remove('busy');
        meta.textContent = 'disconnected — reconnecting…';
        setBusy(false);
        flushAssistant();
        setTimeout(connect, 1500);
      };
      ws.onerror = function () { meta.textContent = 'error'; };
      ws.onmessage = function (ev) {
        let m;
        try { m = JSON.parse(ev.data); } catch (_) { return; }
        switch (m.type) {
          case 'assistant_delta':
            ensureCurrent();
            currentRaw += m.text || '';
            renderMarkdown(current, currentRaw);
            break;
          case 'thinking_delta': {
            if (!current || current._kind !== 'thinking') {
              flushAssistant();
              current = bubble('thinking', '');
              current._kind = 'thinking';
            }
            const pinned = isPinned();
            current.textContent += m.text || '';
            maybeScroll(pinned);
            break;
          }
          case 'tool_call': {
            flushAssistant();
            const det = tool(m.name, m.id, m.input);
            if (m.id) toolElems.set(m.id, det);
            break;
          }
          case 'tool_result': {
            const det = toolElems.get(m.id);
            if (det) attachToolResult(det, m.output, m.ok !== false);
            else tool(m.name || 'result', m.id, null, m.ok !== false);
            break;
          }
          case 'turn_end':
            flushAssistant();
            setBusy(false);
            break;
          case 'error':
            flushAssistant();
            bubble('error', m.message || 'error');
            setBusy(false);
            break;
        }
      };
    }

    async function submit() {
      if (busy) {
        if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'abort' }));
        return;
      }
      const text = ta.value.trim();
      if (!text || !ws || ws.readyState !== 1) return;
      bubble('user', text);
      ta.value = '';
      ta.style.height = 'auto';
      flushAssistant();
      toolElems.clear();
      setBusy(true);
      ws.send(JSON.stringify({
        type: 'user', text: text, model: model, max_tokens: maxTokens,
      }));
      await ready;
    }

    form.addEventListener('submit', function (e) { e.preventDefault(); submit(); });
    ta.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(); }
    });
    ta.addEventListener('input', function () {
      ta.style.height = 'auto';
      ta.style.height = Math.min(ta.scrollHeight, 240) + 'px';
    });

    connect();

    return {
      send: function (text) { ta.value = text; submit(); },
      ws: function () { return ws; },
    };
  }

  global.createPsiChat = createPsiChat;
})(typeof window !== 'undefined' ? window : this);
