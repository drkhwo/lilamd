// Bridge between the native app and Vditor. All messages go to window.webkit.messageHandlers.mdedit.
(function () {
  "use strict";
  const CDN = "mdedit://app/vditor";
  const post = (msg) => window.webkit.messageHandlers.mdedit.postMessage(msg);
  let vditor = null;
  let generation = 0;
  let dark = false;
  const latencies = [];

  function hljsStyle() { return dark ? "github-dark" : "github"; }

  function applyBodyTheme() { document.body.classList.toggle("dark", dark); }

  function create(value, mode, scrollRatio) {
    const gen = ++generation;
    // Debounce of Vditor's "input" (= whole-document Markdown conversion): longer for big files.
    const lines = (value.match(/\n/g) || []).length;
    const delay = lines > 2000 ? 800 : 150;
    if (vditor) { try { vditor.destroy(); } catch (e) {} vditor = null; }
    const el = document.getElementById("editor");
    el.innerHTML = "";
    const v = new Vditor(el, {
      mode: mode === "source" ? "sv" : "ir",
      value: value,
      cdn: CDN,
      lang: "en_US",
      icon: "ant",
      height: "100%",
      theme: dark ? "dark" : "classic",
      cache: { enable: false },
      counter: { enable: false },
      outline: { enable: false },
      resize: { enable: false },
      typewriterMode: false,
      undoDelay: delay,
      toolbarConfig: { hide: true, pin: false },
      // Hidden toolbar: kept only because Vditor routes Cmd+B/I/K/Z/Shift+Z through toolbar items.
      toolbar: ["bold", "italic", "link", "undo", { name: "redo", hotkey: "⇧⌘Z" }],
      link: { isOpen: false },
      image: { isPreview: false },
      preview: {
        mode: "editor",
        actions: [],
        delay: 0,
        markdown: { sanitize: true, linkBase: "mdedit://doc/", codeBlockPreview: true, mathBlockPreview: false },
        hljs: { enable: true, style: hljsStyle(), lineNumber: false },
        theme: { current: dark ? "dark" : "light" },
      },
      input: (md) => onInput(gen, md, delay),
      after: () => {
        if (gen !== generation) return;
        vditor = v;
        speedUp(v);
        v.clearStack(); // record the loaded state as the first undo step right away
        hideEmojiHint(v);
        const root = scroller();
        if (root) root.focus({ preventScroll: true });
        if (scrollRatio) restoreScroll(scrollRatio);
        post({ type: "ready", baseline: v.getValue(), mode: mode });
      },
    });
  }

  // Vditor re-renders the whole outline (all headings through Lute) on every keystroke, even with the
  // outline panel disabled; only a [ToC] block needs it. And it converts the whole document to Markdown
  // synchronously inside some input events. Both are O(document) per key and make big files lag.
  const PREVIEW_RE = /<pre class="vditor-ir__preview"[^>]*>[\s\S]*?<\/pre>/g;
  const LAZY = "\u0000mdedit-lazy\u0000";
  let inInputEvent = false;
  document.addEventListener("input", () => { inInputEvent = true; setTimeout(() => { inInputEvent = false; }, 0); }, true);
  window.addEventListener("input", () => { inInputEvent = false; });

  function speedUp(v) {
    const inner = v.vditor;
    if (inner.__mdeditPatched) return;
    inner.__mdeditPatched = true;
    const outline = inner.outline;
    const render = outline.render.bind(outline);
    outline.render = (vd) => (vd[vd.currentMode].element.querySelector("[data-type='toc-block']") ? render(vd) : "");
    // Undo baseline: Vditor records the loaded HTML before code highlighting finishes, so the first undo
    // diff spans every code block (~2 s on big files). Re-take it right before the first edit (Vditor
    // does the same in recordFirstPosition, but skips it on Safari/WebKit).
    const undo = inner.undo;
    // Undo snapshots: store code-block previews unrendered (as Vditor already does for charts), so a
    // snapshot does not depend on whether highlight.js has run yet. Otherwise one diff spans every code
    // block of the file. Undo re-renders previews marked data-render="2".
    undo.addCaret = function (vd, setFocus) {
      const el = vd[vd.currentMode].element;
      let cloneRange = null;
      const sel = getSelection();
      if (sel.rangeCount !== 0 && !el.querySelector("wbr")) {
        const range = sel.getRangeAt(0);
        if (el.contains(range.startContainer)) {
          cloneRange = range.cloneRange();
          const wbr = document.createElement("span");
          wbr.className = "vditor-wbr";
          range.insertNode(wbr);
        }
      }
      const clone = el.cloneNode(true);
      clone.querySelectorAll(".vditor-" + vd.currentMode + "__preview").forEach((item) => {
        const src = item.previousElementSibling && item.previousElementSibling.firstElementChild;
        const code = item.firstElementChild;
        if (!src || !code) return;
        if (code.classList.contains("language-math")) {
          code.textContent = code.getAttribute("data-math"); code.removeAttribute("data-math");
        } else {
          item.innerHTML = "";
          const fresh = document.createElement("code");
          fresh.className = src.className;
          fresh.innerHTML = src.innerHTML;
          item.appendChild(fresh);
        }
        item.setAttribute("data-render", "2");
      });
      const text = clone.innerHTML;
      el.querySelectorAll(".vditor-wbr").forEach((item) => item.remove());
      if (setFocus && cloneRange) { sel.removeAllRanges(); sel.addRange(cloneRange); }
      return text.replace('<span class="vditor-wbr"></span>', "<wbr>");
    };
    const refreshUndoBase = () => {
      const st = undo[inner.currentMode];
      if (!st || st.undoStack.length !== 1 || st.redoStack.length !== 0 || !st.undoStack[0][0]) return;
      const html = undo.addCaret(inner, true);
      st.undoStack[0][0].diffs[0][1] = html;
      st.lastText = html;
    };
    // Done while idle (after highlighting has settled) so the first keystroke does not pay for it;
    // the keydown hook covers typing that starts before that.
    let refreshedIdle = false;
    for (const ms of [600, 2000]) setTimeout(() => { if (v === vditor) { refreshUndoBase(); refreshedIdle = true; } }, ms);
    for (const m of ["ir", "sv"]) {
      if (!inner[m]) continue;
      inner[m].element.addEventListener("keydown", () => { if (!refreshedIdle) refreshUndoBase(); }, true);
    }
    // Typing with the caret directly in the editor root (e.g. after Cmd+Down past a final code block)
    // makes Vditor re-render the whole document through Lute on the next keystrokes (~1 s on big files).
    // Give such text a paragraph of its own first.
    if (inner.ir) {
      const root = inner.ir.element;
      root.addEventListener("keydown", (e) => {
        if (e.metaKey || e.ctrlKey || e.altKey || e.key.length !== 1 || e.isComposing) return;
        const sel = getSelection();
        if (!sel.rangeCount || !sel.isCollapsed) return;
        const r = sel.getRangeAt(0);
        const n = r.startContainer;
        if (n !== root && !(n.nodeType === 3 && n.parentNode === root)) return;
        const p = document.createElement("p");
        p.setAttribute("data-block", "0");
        let text, offset = 0;
        if (n.nodeType === 3) { root.insertBefore(p, n); p.appendChild(n); text = n; offset = r.startOffset; }
        else { root.insertBefore(p, root.childNodes[r.startOffset] || null); text = document.createTextNode(""); p.appendChild(text); }
        const nr = document.createRange(); nr.setStart(text, offset); nr.collapse(true);
        sel.removeAllRanges(); sel.addRange(nr);
      }, true);
    }
    // A caret directly in the editor root in front of a table (document start, Cmd+Up, initial focus)
    // is drawn on an empty line that does not exist in the file. Put it into the first cell instead.
    if (inner.ir) {
      const root = inner.ir.element;
      document.addEventListener("selectionchange", () => {
        if (!vditor || vditor.vditor !== inner || inner.currentMode !== "ir") return;
        const sel = getSelection();
        if (!sel.rangeCount || !sel.isCollapsed) return;
        const r = sel.getRangeAt(0);
        if (r.startContainer !== root) return;
        const block = root.childNodes[r.startOffset];
        if (!block || block.nodeName !== "TABLE") return;
        const cell = block.querySelector("th, td");
        if (!cell) return;
        const nr = document.createRange();
        if (cell.firstChild && cell.firstChild.nodeType === 3) nr.setStart(cell.firstChild, 0); else nr.setStart(cell, 0);
        nr.collapse(true);
        sel.removeAllRanges();
        sel.addRange(nr);
      });
    }
    const lute = inner.lute;
    // Warm up the JIT for the per-keystroke Lute path so the first keys are not slow.
    try { for (let i = 0; i < 30; i++) lute.SpinVditorIRDOM('<p data-block="0">warm *up* `x` [a](b)<wbr></p>'); } catch (e) {}
    for (const name of ["VditorIRDOM2Md", "VditorSVDOM2Md"]) {
      const real = lute[name];
      if (typeof real !== "function") continue;
      lute[name] = function (html) {
        if (inInputEvent) return LAZY;
        // Rendered code previews (highlighted copy + copy button) are not part of the Markdown; dropping
        // them more than halves what Lute has to parse.
        if (name === "VditorIRDOM2Md") html = html.replace(PREVIEW_RE, '<pre class="vditor-ir__preview" data-render="2"><code></code></pre>');
        return real.call(lute, html);
      };
    }
  }

  // `pre.vditor-reset:empty::before` (a placeholder we never use) makes WebKit restyle every block of the
  // editor whenever one block is replaced, i.e. on each keystroke: ~30 ms per key on a 6000-line file.
  function dropSlowCSS() {
    for (const sheet of document.styleSheets) {
      let rules;
      try { rules = sheet.cssRules; } catch (e) { continue; }
      for (let i = rules.length - 1; i >= 0; i--) {
        if (rules[i].selectorText && /pre\.vditor-reset:empty/.test(rules[i].selectorText)) sheet.deleteRule(i);
      }
    }
  }

  let lazyTimer = null;
  function onInput(gen, md, delay) {
    if (gen !== generation) return;
    if (md === LAZY) {
      clearTimeout(lazyTimer);
      lazyTimer = setTimeout(() => { if (gen === generation && vditor) post({ type: "input", value: vditor.getValue() }); }, delay);
      return;
    }
    clearTimeout(lazyTimer);
    post({ type: "input", value: md });
  }

  function hideEmojiHint(v) {
    const hint = v.vditor && v.vditor.hint;
    if (!hint || hint.__patched) return;
    const render = hint.render.bind(hint);
    hint.render = (inner) => { render(inner); if (hint.splitChar === ":") hint.element.style.display = "none"; };
    hint.__patched = true;
  }

  function scroller() {
    if (!vditor) return null;
    const v = vditor.vditor;
    return v.currentMode === "sv" ? v.sv.element : v.ir.element;
  }
  function scrollRatio() {
    const s = scroller();
    if (!s || s.scrollHeight <= s.clientHeight) return 0;
    return s.scrollTop / (s.scrollHeight - s.clientHeight);
  }
  function restoreScroll(r) {
    const s = scroller();
    if (s) s.scrollTop = r * (s.scrollHeight - s.clientHeight);
  }

  // Cmd+click on a link opens it in the default browser; a plain click only places the caret.
  document.addEventListener("click", (e) => {
    const a = e.target.closest && e.target.closest("a[href]");
    if (a) e.preventDefault();
    if (!e.metaKey) return;
    let url = a ? a.getAttribute("href") : null;
    const node = e.target.closest && e.target.closest("[data-type='a']");
    if (!url && node) {
      const m = node.querySelector(".vditor-ir__marker--link");
      if (m) url = m.textContent;
    }
    if (url) { e.preventDefault(); e.stopPropagation(); post({ type: "openLink", url: url.trim() }); }
  }, true);

  // Input latency per character: from the keydown event's timestamp (taken when the event was created,
  // so it includes queueing) until the editor has finished handling the resulting input event.
  let pendingKey = null;
  document.addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.key.length !== 1) return;
    pendingKey = { stamp: e.timeStamp, seen: performance.now() };
  }, true);
  window.addEventListener("input", () => {
    const k = pendingKey;
    pendingKey = null;
    if (!k) return;
    setTimeout(() => {
      const now = performance.now();
      const ms = now - Math.min(k.stamp, k.seen);
      latencies.push(ms);
      if (latencies.length > 1000) latencies.shift();
      post({ type: "latency", ms: ms, queued: k.seen - k.stamp });
    }, 0);
  });

  document.addEventListener("securitypolicyviolation", (e) => {
    post({ type: "blocked", url: String(e.blockedURI) });
  });
  window.addEventListener("error", (e) => post({ type: "jsError", message: String(e.message) }));

  window.mdeditor = {
    init(opts) { dropSlowCSS(); dark = !!opts.dark; applyBodyTheme(); create(opts.value, opts.mode, 0); },
    setValue(value) {
      if (!vditor) return;
      const r = scrollRatio();
      vditor.setValue(value, true);
      restoreScroll(r);
      post({ type: "ready", baseline: vditor.getValue(), mode: vditor.getCurrentMode() === "sv" ? "source" : "visual" });
    },
    setMode(mode, value) { const r = scrollRatio(); create(value, mode, r); },
    setTheme(isDark) {
      dark = !!isDark; applyBodyTheme();
      if (vditor) vditor.setTheme(dark ? "dark" : "classic", dark ? "dark" : "light", hljsStyle());
    },
    undo() { if (vditor) vditor.vditor.undo.undo(vditor.vditor); },
    redo() { if (vditor) vditor.vditor.undo.redo(vditor.vditor); },
    getValue() { return vditor ? vditor.getValue() : null; },
    get instance() { return vditor; },
    root() { return scroller(); },
    latencies: latencies,
  };
  window.addEventListener("DOMContentLoaded", () => post({ type: "loaded" }));
})();
