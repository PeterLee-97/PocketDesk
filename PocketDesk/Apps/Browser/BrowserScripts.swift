import Foundation

/// JavaScript injected into every page. The bridge runs in an isolated content world (pages
/// can't see or tamper with it) and turns the virtual pointer / keyboard into DOM events,
/// focus, selection and editing commands. The fullscreen shim runs in the page world because
/// it has to replace page-visible APIs.
enum BrowserScripts {
    /// Shared secret so injected frames only obey messages from our own script in the parent.
    static let frameToken = UUID().uuidString

    static var bridge: String {
        bridgeSource.replacingOccurrences(of: "__PD_TOKEN__", with: frameToken)
    }

    private static let bridgeSource = #"""
(function () {
  'use strict';
  if (window.__pd) { return; }
  var PD = {};
  window.__pd = PD;
  var TOKEN = '__PD_TOKEN__';
  var isTop = (window === window.top);
  var drag = null, hoverEl = null, hoverFrame = null;
  var scrollEl = null, scrollFrame = null, wheelTarget = null, wheelX = 0, wheelY = 0;
  var lastSelect = null;

  // ---------- helpers ----------
  function viewport(x, y, vw, vh) {
    var v = window.visualViewport;
    if (v && vw > 0 && vh > 0) {
      var k = v.width / vw;
      return { x: v.offsetLeft + x * k, y: v.offsetTop + y * (v.height / vh), k: k, ox: v.offsetLeft, oy: v.offsetTop };
    }
    return { x: x, y: y, k: 1, ox: 0, oy: 0 };
  }
  function scaleFor(vw) {
    var v = window.visualViewport;
    return (v && vw > 0) ? v.width / vw : 1;
  }
  function parentOf(n) {
    if (!n) { return null; }
    if (n.parentElement) { return n.parentElement; }
    var root = n.getRootNode ? n.getRootNode() : null;
    return (root && root !== n && root.host) ? root.host : null;
  }
  function elementAt(x, y) {
    var el = document.elementFromPoint(x, y), guard = 0;
    while (el && el.shadowRoot && guard++ < 20) {
      var inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) { break; }
      el = inner;
    }
    return el;
  }
  function activeElement() {
    var a = document.activeElement, guard = 0;
    while (a && a.shadowRoot && a.shadowRoot.activeElement && guard++ < 20) { a = a.shadowRoot.activeElement; }
    return a;
  }
  function isFrame(el) { return !!el && (el.tagName === 'IFRAME' || el.tagName === 'FRAME'); }
  var TEXT_TYPES = { text: 1, search: 1, url: 1, email: 1, password: 1, tel: 1, number: 1 };
  function isTextField(el) {
    if (!el || !el.tagName) { return false; }
    if (el.tagName === 'TEXTAREA') { return !el.readOnly && !el.disabled; }
    if (el.tagName === 'INPUT') {
      var t = (el.getAttribute('type') || 'text').toLowerCase();
      return !!TEXT_TYPES[t] && !el.readOnly && !el.disabled;
    }
    return false;
  }
  function isEditable(el) { return !!el && (isTextField(el) || !!el.isContentEditable); }
  function frameLocal(frame, x, y) {
    var r = frame.getBoundingClientRect(), cs = getComputedStyle(frame);
    return {
      x: x - r.left - (parseFloat(cs.borderLeftWidth) || 0) - (parseFloat(cs.paddingLeft) || 0),
      y: y - r.top - (parseFloat(cs.borderTopWidth) || 0) - (parseFloat(cs.paddingTop) || 0)
    };
  }
  function post(frame, msg) {
    msg.token = TOKEN;
    try { frame.contentWindow.postMessage({ __pd: msg }, '*'); } catch (e) {}
  }
  function linkFor(el) {
    var a = (el && el.closest) ? el.closest('a[href]') : null;
    return a ? a.href : null;
  }
  function commonAncestor(a, b) {
    if (!a) { return b; }
    if (!b || a === b || a.contains(b)) { return a; }
    var n = b;
    while (n && !n.contains(a)) { n = n.parentElement; }
    return n || b;
  }

  // ---------- events ----------
  function mouseInit(x, y, btn, buttons, detail, mods) {
    mods = mods || {};
    return {
      bubbles: true, cancelable: true, composed: true, view: window, detail: detail || 0,
      clientX: x, clientY: y, screenX: x, screenY: y, button: btn, buttons: buttons,
      ctrlKey: !!mods.ctrl, shiftKey: !!mods.shift, altKey: !!mods.alt, metaKey: !!mods.meta
    };
  }
  function copy(init) { var c = {}; for (var k in init) { c[k] = init[k]; } return c; }
  function fire(el, type, init) {
    if (!el || !el.dispatchEvent) { return true; }
    var ev;
    try {
      if (type.indexOf('pointer') === 0) {
        var p = copy(init);
        p.pointerId = 1; p.pointerType = 'mouse'; p.isPrimary = true; p.width = 1; p.height = 1;
        p.pressure = init.buttons ? 0.5 : 0;
        ev = new PointerEvent(type, p);
      } else {
        ev = new MouseEvent(type, init);
      }
    } catch (e) { return true; }
    return el.dispatchEvent(ev);
  }
  function fireQuiet(el, type, init) { var c = copy(init); c.bubbles = false; return fire(el, type, c); }

  function hoverTo(el, init) {
    var old = hoverEl;
    if (old === el) { return; }
    if (hoverFrame && old === hoverFrame) { post(hoverFrame, { t: 'leave' }); hoverFrame = null; }
    if (old && old.isConnected) {
      fire(old, 'pointerout', init); fire(old, 'mouseout', init);
      for (var n = old; n && n.isConnected && !(el && n.contains(el)); n = n.parentElement) {
        fireQuiet(n, 'pointerleave', init); fireQuiet(n, 'mouseleave', init);
      }
    }
    hoverEl = el;
    if (el) {
      fire(el, 'pointerover', init); fire(el, 'mouseover', init);
      var chain = [];
      for (var m = el; m && !(old && old.isConnected && m.contains(old)); m = m.parentElement) { chain.push(m); }
      for (var i = chain.length - 1; i >= 0; i--) { fireQuiet(chain[i], 'pointerenter', init); fireQuiet(chain[i], 'mouseenter', init); }
    }
  }

  // ---------- selection ----------
  function caretAt(x, y) {
    try {
      if (document.caretRangeFromPoint) { return document.caretRangeFromPoint(x, y); }
      if (document.caretPositionFromPoint) {
        var p = document.caretPositionFromPoint(x, y);
        if (!p) { return null; }
        var r = document.createRange(); r.setStart(p.offsetNode, p.offset); r.collapse(true); return r;
      }
    } catch (e) {}
    return null;
  }
  function selectAround(r, granularity) {
    var sel = window.getSelection();
    try {
      sel.collapse(r.startContainer, r.startOffset);
      sel.modify('move', 'backward', granularity);
      sel.modify('extend', 'forward', granularity);
    } catch (e) {}
  }
  var FOCUSABLE = { INPUT: 1, TEXTAREA: 1, SELECT: 1, BUTTON: 1, IFRAME: 1 };
  function focusTarget(el) {
    for (var n = el, i = 0; n && i < 80; n = parentOf(n), i++) {
      if (n.nodeType !== 1) { continue; }
      if (n.isContentEditable) {
        var host = n;
        while (host.parentElement && host.parentElement.isContentEditable) { host = host.parentElement; }
        return host;
      }
      if (FOCUSABLE[n.tagName]) { return n; }
      if (n.tagName === 'A' && n.hasAttribute('href')) { return n; }
      if (n.hasAttribute && n.hasAttribute('tabindex')) { return n; }
    }
    return null;
  }

  // ---------- pointer (CSS client coordinates) ----------
  PD.downCSS = function (x, y, button, detail, mods) {
    mods = mods || {};
    var el = elementAt(x, y);
    hoverTo(el, mouseInit(x, y, 0, 0, 0, mods));
    if (!el) { drag = null; return { editable: false }; }
    if (isFrame(el)) {
      var p = frameLocal(el, x, y);
      drag = { frame: el };
      try { el.focus(); } catch (e) {}
      post(el, { t: 'down', x: p.x, y: p.y, button: button, detail: detail, mods: mods });
      return { editable: true, frame: true };
    }
    var btn = button === 'right' ? 2 : (button === 'middle' ? 1 : 0);
    var buttons = btn === 2 ? 2 : (btn === 1 ? 4 : 1);
    var init = mouseInit(x, y, btn, buttons, detail, mods);
    var pointerOK = fire(el, 'pointerdown', init);
    var mouseOK = pointerOK ? fire(el, 'mousedown', init) : false;
    drag = { el: el, btn: btn, buttons: buttons, detail: detail, selecting: false, anchor: null, sx: x, sy: y, select: null };
    if (btn === 0 && mouseOK) {
      var target = focusTarget(el), active = activeElement();
      if (target) {
        if (target !== active) {
          try { target.focus({ preventScroll: true }); } catch (e) { try { target.focus(); } catch (e2) {} }
          if (isTextField(target)) { try { var len = target.value.length; target.setSelectionRange(len, len); } catch (e3) {} }
        }
      } else if (active && active !== document.body && active.blur) {
        try { active.blur(); } catch (e4) {}
      }
      var focused = activeElement();
      if (isTextField(focused)) {
        if (detail >= 2) { try { focused.select(); } catch (e5) {} }
      } else {
        var r = caretAt(x, y);
        if (r) {
          var sel = window.getSelection();
          if (detail >= 3) { selectAround(r, 'paragraphboundary'); }
          else if (detail === 2) { selectAround(r, 'word'); }
          else if (mods.shift && sel.rangeCount) { try { sel.extend(r.startContainer, r.startOffset); } catch (e6) {} }
          else { try { sel.collapse(r.startContainer, r.startOffset); } catch (e7) {} }
          drag.selecting = detail <= 2;
          drag.anchor = r;
          if (detail === 2 && sel.rangeCount) {
            // Double-click-and-drag extends from the start of the selected word.
            var word = sel.getRangeAt(0), start = document.createRange();
            start.setStart(word.startContainer, word.startOffset);
            start.collapse(true);
            drag.anchor = start;
          }
        }
      }
      var select = el.closest ? el.closest('select') : null;
      if (select && !select.disabled && !select.multiple) { drag.select = select; }
    }
    return { editable: isEditable(activeElement()) };
  };

  PD.moveCSS = function (x, y, mods) {
    if (!drag) { return null; }
    if (drag.frame) {
      var p = frameLocal(drag.frame, x, y);
      post(drag.frame, { t: 'move', x: p.x, y: p.y, mods: mods });
      return null;
    }
    var el = elementAt(x, y) || drag.el;
    var init = mouseInit(x, y, drag.btn, drag.buttons, 0, mods);
    hoverTo(el, init);
    fire(el, 'pointermove', init);
    fire(el, 'mousemove', init);
    if (drag.selecting && drag.anchor && (Math.abs(x - drag.sx) + Math.abs(y - drag.sy) > 3)) {
      var r = caretAt(x, y);
      if (r) {
        try { window.getSelection().setBaseAndExtent(drag.anchor.startContainer, drag.anchor.startOffset, r.startContainer, r.startOffset); } catch (e) {}
      }
    }
    return null;
  };

  PD.upCSS = function (x, y, mods) {
    mods = mods || {};
    var d = drag; drag = null;
    if (!d) { return { editable: isEditable(activeElement()) }; }
    if (d.frame) {
      var p = frameLocal(d.frame, x, y);
      post(d.frame, { t: 'up', x: p.x, y: p.y, mods: mods });
      return { editable: true, frame: true };
    }
    var el = elementAt(x, y) || d.el;
    var init = mouseInit(x, y, d.btn, 0, d.detail, mods);
    fire(el, 'pointerup', init);
    fire(el, 'mouseup', init);
    var result = {};
    var link = linkFor(el);
    if (d.btn === 0) {
      var newTab = !!(link && (mods.meta || mods.ctrl));
      var target = commonAncestor(d.el, el);
      if (target && !newTab) {
        fire(target, 'click', init);
        if (d.detail === 2) { fire(target, 'dblclick', init); }
      }
      if (newTab) { result.link = link; result.newTab = true; }
      if (d.select && d.select.isConnected) {
        lastSelect = d.select;
        var r = d.select.getBoundingClientRect();
        var options = [];
        for (var i = 0; i < d.select.options.length; i++) {
          var o = d.select.options[i];
          options.push({ label: (o.label || o.text || '').trim(), disabled: !!o.disabled });
        }
        result.select = { options: options, selected: d.select.selectedIndex, x: r.left, y: r.bottom, w: r.width };
      }
    } else if (d.btn === 1) {
      fire(el, 'auxclick', init);
      if (link) { result.link = link; result.newTab = true; }
    } else {
      result.contextmenu = fire(el, 'contextmenu', init);
      result.link = link;
      var img = el.closest ? el.closest('img') : null;
      if (img) { result.image = img.currentSrc || img.src; }
      result.selection = String(window.getSelection() || '').slice(0, 300);
    }
    result.editable = isEditable(activeElement());
    return result;
  };

  function cursorFor(el) {
    if (!el) { return 'default'; }
    try {
      var c = getComputedStyle(el).cursor;
      if (c && c !== 'auto') { return c; }
    } catch (e) {}
    if (isEditable(el)) { return 'text'; }
    if (linkFor(el)) { return 'pointer'; }
    return 'auto';
  }

  PD.hoverCSS = function (x, y) {
    var el = elementAt(x, y);
    var init = mouseInit(x, y, 0, 0, 0, {});
    if (isFrame(el)) {
      hoverTo(el, init);
      hoverFrame = el;
      var p = frameLocal(el, x, y);
      post(el, { t: 'hover', x: p.x, y: p.y });
      return { cursor: 'default' };
    }
    hoverTo(el, init);
    if (el) { fire(el, 'pointermove', init); fire(el, 'mousemove', init); }
    return { cursor: cursorFor(el) };
  };

  // ---------- scrolling ----------
  function canScroll(n, dx, dy) {
    if (!n || n.nodeType !== 1) { return false; }
    var cs;
    try { cs = getComputedStyle(n); } catch (e) { return false; }
    var oy = cs.overflowY, ox = cs.overflowX;
    var sy = (oy === 'auto' || oy === 'scroll' || oy === 'overlay') && n.scrollHeight > n.clientHeight + 1;
    var sx = (ox === 'auto' || ox === 'scroll' || ox === 'overlay') && n.scrollWidth > n.clientWidth + 1;
    if (dy && sy && (dy > 0 ? n.scrollTop + n.clientHeight < n.scrollHeight - 1 : n.scrollTop > 0)) { return true; }
    if (dx && sx && (dx > 0 ? n.scrollLeft + n.clientWidth < n.scrollWidth - 1 : n.scrollLeft > 0)) { return true; }
    return false;
  }
  function wheel(el, x, y, dx, dy) {
    try {
      return el.dispatchEvent(new WheelEvent('wheel', {
        bubbles: true, cancelable: true, composed: true, view: window,
        clientX: x, clientY: y, deltaX: dx, deltaY: dy, deltaMode: 0
      }));
    } catch (e) { return true; }
  }
  PD.scrollStartCSS = function (x, y, dx, dy) {
    scrollEl = null; scrollFrame = null; wheelTarget = null;
    var el = elementAt(x, y);
    if (isFrame(el)) {
      scrollFrame = el;
      var p = frameLocal(el, x, y);
      post(el, { t: 'scrollStart', x: p.x, y: p.y, dx: dx, dy: dy });
      return { handled: true };
    }
    if (el && !wheel(el, x, y, dx, dy)) {
      scrollEl = 'wheel'; wheelTarget = el; wheelX = x; wheelY = y;
      return { handled: true };
    }
    for (var n = el, i = 0; n && i < 80; n = parentOf(n), i++) {
      if (n === document.body || n === document.documentElement || n === document.scrollingElement) { break; }
      if (canScroll(n, dx, dy)) { scrollEl = n; n.scrollBy(dx, dy); return { handled: true }; }
    }
    if (!isTop) {
      var root = document.scrollingElement || document.documentElement;
      scrollEl = root; root.scrollBy(dx, dy);
      return { handled: true };
    }
    return { handled: false };
  };
  PD.scrollMoreCSS = function (dx, dy) {
    if (scrollFrame) { post(scrollFrame, { t: 'scrollMore', dx: dx, dy: dy }); return { handled: true }; }
    if (scrollEl === 'wheel') {
      if (wheelTarget && wheelTarget.isConnected) { wheel(wheelTarget, wheelX, wheelY, dx, dy); }
      return { handled: true };
    }
    if (scrollEl && scrollEl.isConnected) {
      var top = scrollEl.scrollTop, left = scrollEl.scrollLeft;
      scrollEl.scrollBy(dx, dy);
      return { handled: (scrollEl.scrollTop !== top || scrollEl.scrollLeft !== left) || !isTop };
    }
    return { handled: false };
  };
  function keyScrollTarget() {
    for (var n = hoverEl, i = 0; n && i < 80; n = parentOf(n), i++) {
      if (n === document.body || n === document.documentElement) { break; }
      if (canScroll(n, 0, 1) || canScroll(n, 0, -1)) { return n; }
    }
    return document.scrollingElement || document.documentElement;
  }
  function scrollByKey(dx, dy) {
    try { keyScrollTarget().scrollBy({ left: dx, top: dy, behavior: 'smooth' }); } catch (e) {}
  }

  // ---------- keyboard ----------
  var KEYCODES = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ArrowLeft: 37, ArrowUp: 38,
    ArrowRight: 39, ArrowDown: 40, Home: 36, End: 35, PageUp: 33, PageDown: 34, ' ': 32 };
  var PUNCT = { '/': 191, '.': 190, ',': 188, '-': 189, '=': 187, ';': 186, "'": 222, '[': 219, ']': 221, '\\': 220, '`': 192 };
  function keyCodeFor(key) {
    if (KEYCODES[key]) { return KEYCODES[key]; }
    if (key.length === 1) {
      var c = key.toUpperCase().charCodeAt(0);
      if ((c >= 65 && c <= 90) || (c >= 48 && c <= 57)) { return c; }
      return PUNCT[key] || 0;
    }
    return 0;
  }
  function codeFor(key) {
    if (KEYCODES[key]) { return key === ' ' ? 'Space' : key; }
    if (key.length === 1) {
      var u = key.toUpperCase();
      if (u >= 'A' && u <= 'Z') { return 'Key' + u; }
      if (u >= '0' && u <= '9') { return 'Digit' + u; }
    }
    return '';
  }
  function keyEvent(target, type, key, mods) {
    mods = mods || {};
    var kc = keyCodeFor(key);
    var charCode = 0;
    if (type === 'keypress') { charCode = key === 'Enter' ? 13 : key.charCodeAt(0); }
    var ev;
    try {
      ev = new KeyboardEvent(type, {
        key: key, code: codeFor(key), keyCode: type === 'keypress' ? charCode : kc, which: kc, charCode: charCode,
        bubbles: true, cancelable: true, composed: true, view: window,
        ctrlKey: !!mods.ctrl, shiftKey: !!mods.shift, altKey: !!mods.alt, metaKey: !!mods.meta
      });
    } catch (e) { return true; }
    return target.dispatchEvent(ev);
  }
  function keyTarget() {
    var a = activeElement();
    return (a && a !== document.body) ? a : (document.body || document.documentElement);
  }
  function insertInto(el, text) {
    var ok = false;
    try { ok = document.execCommand('insertText', false, text); } catch (e) {}
    if (ok || !isTextField(el)) { return; }
    try {
      var s = el.selectionStart, e2 = el.selectionEnd;
      if (s === null || s === undefined) { el.value += text; } else { el.setRangeText(text, s, e2, 'end'); }
    } catch (err) { el.value += text; }
    try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text })); }
    catch (e3) { el.dispatchEvent(new Event('input', { bubbles: true })); }
  }
  function edit(command, el, direction) {
    var ok = false;
    try { ok = document.execCommand(command, false, null); } catch (e) {}
    if (ok || !isTextField(el)) { return; }
    try {
      var s = el.selectionStart, e2 = el.selectionEnd, v = el.value;
      if (s === null || s === undefined) {
        if (direction < 0) { el.value = v.slice(0, -1); }
      } else if (s !== e2) {
        el.setRangeText('', s, e2, 'start');
      } else if (direction < 0 && s > 0) {
        var n = (s >= 2 && /[\uDC00-\uDFFF]/.test(v.charAt(s - 1))) ? 2 : 1;
        el.setRangeText('', s - n, s, 'start');
      } else if (direction > 0 && s < v.length) {
        var m = /[\uD800-\uDBFF]/.test(v.charAt(s)) ? 2 : 1;
        el.setRangeText('', s, s + m, 'start');
      }
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: direction < 0 ? 'deleteContentBackward' : 'deleteContentForward' }));
    } catch (err) {}
  }
  function lineStart(v, i) { if (i <= 0) { return 0; } return v.lastIndexOf('\n', i - 1) + 1; }
  function lineEnd(v, i) { var n = v.indexOf('\n', i); return n < 0 ? v.length : n; }
  function verticalMove(v, i, dir) {
    var start = lineStart(v, i), col = i - start;
    if (dir < 0) {
      if (start === 0) { return 0; }
      var prev = lineStart(v, start - 1);
      return Math.min(prev + col, start - 1);
    }
    var end = lineEnd(v, i);
    if (end >= v.length) { return v.length; }
    return Math.min(end + 1 + col, lineEnd(v, end + 1));
  }
  function wordLeft(v, i) { var p = i; while (p > 0 && /\s/.test(v.charAt(p - 1))) { p--; } while (p > 0 && !/\s/.test(v.charAt(p - 1))) { p--; } return p; }
  function wordRight(v, i) { var p = i; while (p < v.length && /\s/.test(v.charAt(p))) { p++; } while (p < v.length && !/\s/.test(v.charAt(p))) { p++; } return p; }
  function moveInField(el, key, mods) {
    var v = el.value || '', s, e2;
    try { s = el.selectionStart; e2 = el.selectionEnd; } catch (e) { return; }
    if (s === null || s === undefined) { return; }
    var backward = el.selectionDirection === 'backward';
    var focus = backward ? s : e2, anchor = backward ? e2 : s;
    var multiline = el.tagName === 'TEXTAREA';
    var word = mods.alt || mods.ctrl, line = mods.meta;
    var pos = focus;
    switch (key) {
      case 'ArrowLeft':
        if (!mods.shift && s !== e2) { pos = s; break; }
        pos = line ? lineStart(v, focus) : (word ? wordLeft(v, focus) : Math.max(0, focus - 1)); break;
      case 'ArrowRight':
        if (!mods.shift && s !== e2) { pos = e2; break; }
        pos = line ? lineEnd(v, focus) : (word ? wordRight(v, focus) : Math.min(v.length, focus + 1)); break;
      case 'Home': pos = (multiline && !(mods.meta || mods.ctrl)) ? lineStart(v, focus) : 0; break;
      case 'End': pos = (multiline && !(mods.meta || mods.ctrl)) ? lineEnd(v, focus) : v.length; break;
      case 'ArrowUp': pos = (multiline && !line) ? verticalMove(v, focus, -1) : 0; break;
      case 'ArrowDown': pos = (multiline && !line) ? verticalMove(v, focus, 1) : v.length; break;
    }
    try {
      if (mods.shift) { el.setSelectionRange(Math.min(anchor, pos), Math.max(anchor, pos), pos < anchor ? 'backward' : 'forward'); }
      else { el.setSelectionRange(pos, pos); }
    } catch (e3) {}
  }
  function moveSelection(key, mods) {
    var sel = window.getSelection();
    if (!sel) { return; }
    var alter = mods.shift ? 'extend' : 'move';
    var dir = (key === 'ArrowLeft' || key === 'ArrowUp' || key === 'Home') ? 'backward' : 'forward';
    var gran = 'character';
    if (key === 'ArrowUp' || key === 'ArrowDown') { gran = (mods.meta || mods.ctrl) ? 'documentboundary' : 'line'; }
    else if (key === 'Home' || key === 'End') { gran = (mods.meta || mods.ctrl) ? 'documentboundary' : 'lineboundary'; }
    else if (mods.meta) { gran = 'lineboundary'; }
    else if (mods.alt || mods.ctrl) { gran = 'word'; }
    try {
      if (!mods.shift && !sel.isCollapsed && gran === 'character') {
        if (dir === 'backward') { sel.collapseToStart(); } else { sel.collapseToEnd(); }
        return;
      }
      sel.modify(alter, dir, gran);
    } catch (e) {}
  }
  function moveFocus(direction) {
    var nodes = document.querySelectorAll('a[href], button, input, select, textarea, [tabindex], [contenteditable="true"], [contenteditable=""]');
    var list = [];
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.disabled || n.tabIndex < 0 || (n.tagName === 'INPUT' && n.type === 'hidden')) { continue; }
      var r = n.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) { list.push(n); }
    }
    if (!list.length) { return; }
    var current = list.indexOf(activeElement());
    var index = current < 0 ? (direction > 0 ? 0 : list.length - 1) : (current + direction + list.length) % list.length;
    var next = list[index];
    try { next.focus(); } catch (e) {}
    if (isTextField(next)) { try { next.select(); } catch (e2) {} }
  }
  function defaultKeyAction(key, mods, el) {
    var editable = isEditable(el), field = isTextField(el);
    switch (key) {
      case 'Backspace': if (editable) { edit('delete', el, -1); } return;
      case 'Delete': if (editable) { edit('forwardDelete', el, 1); } return;
      case 'Enter':
        if (field && el.tagName === 'INPUT') {
          var form = el.form;
          if (form) { try { if (form.requestSubmit) { form.requestSubmit(); } else { form.submit(); } } catch (e) {} }
          return;
        }
        if (field) { insertInto(el, '\n'); return; }
        if (editable) {
          var ok = false;
          try { ok = document.execCommand(mods.shift ? 'insertLineBreak' : 'insertParagraph', false, null); } catch (e2) {}
          if (!ok) { insertInto(el, '\n'); }
          return;
        }
        if (el && el !== document.body && el.click && (el.tagName === 'A' || el.tagName === 'BUTTON' || el.getAttribute('role') === 'button')) {
          try { el.click(); } catch (e3) {}
        }
        return;
      case 'Tab': moveFocus(mods.shift ? -1 : 1); return;
      case 'ArrowLeft': case 'ArrowRight': case 'ArrowUp': case 'ArrowDown': case 'Home': case 'End':
        if (field) { moveInField(el, key, mods); return; }
        if (editable) { moveSelection(key, mods); return; }
        if (key === 'ArrowDown') { scrollByKey(0, 60); }
        else if (key === 'ArrowUp') { scrollByKey(0, -60); }
        else if (key === 'ArrowLeft') { scrollByKey(-60, 0); }
        else if (key === 'ArrowRight') { scrollByKey(60, 0); }
        else if (key === 'Home') { try { keyScrollTarget().scrollTo({ top: 0, behavior: 'smooth' }); } catch (e4) {} }
        else { try { var t = keyScrollTarget(); t.scrollTo({ top: t.scrollHeight, behavior: 'smooth' }); } catch (e5) {} }
        return;
      case 'PageUp': if (!editable) { scrollByKey(0, -window.innerHeight * 0.85); } return;
      case 'PageDown': if (!editable) { scrollByKey(0, window.innerHeight * 0.85); } return;
    }
  }

  PD.text = function (text) {
    var el = activeElement();
    if (isFrame(el)) { post(el, { t: 'text', text: text }); return { editable: true }; }
    if (isEditable(el)) { insertInto(el, text); return { editable: true }; }
    // Nothing editable focused: deliver key presses so site shortcuts (YouTube "k", "/", …) work.
    var target = keyTarget();
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      var ok = keyEvent(target, 'keydown', ch, {});
      if (ok) { keyEvent(target, 'keypress', ch, {}); }
      keyEvent(target, 'keyup', ch, {});
      if (ok && ch === ' ') { scrollByKey(0, window.innerHeight * 0.85); }
      var now = activeElement();
      if (isEditable(now)) {
        if (i + 1 < text.length) { insertInto(now, text.slice(i + 1)); }
        return { editable: true };
      }
    }
    return { editable: false };
  };

  PD.key = function (key, mods) {
    mods = mods || {};
    var el = activeElement();
    if (isFrame(el)) { post(el, { t: 'key', key: key, mods: mods }); return { editable: true }; }
    var target = keyTarget();
    var ok = keyEvent(target, 'keydown', key, mods);
    if (ok) {
      if (key === 'Enter') { keyEvent(target, 'keypress', 'Enter', mods); }
      defaultKeyAction(key, mods, el);
    }
    keyEvent(target, 'keyup', key, mods);
    return { editable: isEditable(activeElement()) };
  };

  PD.shortcut = function (key, mods) {
    mods = mods || {};
    var el = activeElement();
    if (isFrame(el)) { post(el, { t: 'shortcut', key: key, mods: mods }); return null; }
    var target = keyTarget();
    var ok = keyEvent(target, 'keydown', key, mods);
    if (ok) {
      var editable = isEditable(el);
      try {
        switch (key) {
          case 'a': if (isTextField(el)) { el.select(); } else { document.execCommand('selectAll', false, null); } break;
          case 'z': document.execCommand(mods.shift ? 'redo' : 'undo', false, null); break;
          case 'y': document.execCommand('redo', false, null); break;
          case 'b': if (editable) { document.execCommand('bold', false, null); } break;
          case 'i': if (editable) { document.execCommand('italic', false, null); } break;
          case 'u': if (editable) { document.execCommand('underline', false, null); } break;
        }
      } catch (e) {}
    }
    keyEvent(target, 'keyup', key, mods);
    return null;
  };

  PD.copy = function (cut) {
    var el = activeElement(), text = '';
    if (isTextField(el)) {
      try { text = el.value.substring(el.selectionStart, el.selectionEnd); } catch (e) { text = ''; }
      if (cut && text) { edit('delete', el, -1); }
    } else {
      text = String(window.getSelection() || '');
      if (cut && text && isEditable(el)) { try { document.execCommand('delete', false, null); } catch (e2) {} }
    }
    return text;
  };

  PD.choose = function (index) {
    var s = lastSelect; lastSelect = null;
    if (!s || !s.isConnected) { return null; }
    s.selectedIndex = index;
    s.dispatchEvent(new Event('input', { bubbles: true }));
    s.dispatchEvent(new Event('change', { bubbles: true }));
    return null;
  };

  // ---------- entry points from native (view coordinates) ----------
  function withViewport(result, c) {
    result = result || {};
    result.k = c.k; result.ox = c.ox; result.oy = c.oy;
    return result;
  }
  PD.down = function (x, y, vw, vh, button, detail, mods) {
    var c = viewport(x, y, vw, vh);
    return withViewport(PD.downCSS(c.x, c.y, button, detail, mods), c);
  };
  PD.move = function (x, y, vw, vh, mods) {
    var c = viewport(x, y, vw, vh);
    PD.moveCSS(c.x, c.y, mods);
    return null;
  };
  PD.up = function (x, y, vw, vh, mods) {
    var c = viewport(x, y, vw, vh);
    return withViewport(PD.upCSS(c.x, c.y, mods), c);
  };
  PD.hover = function (x, y, vw, vh) {
    var c = viewport(x, y, vw, vh);
    return PD.hoverCSS(c.x, c.y);
  };
  PD.leave = function () {
    hoverTo(null, mouseInit(0, 0, 0, 0, 0, {}));
    return null;
  };
  PD.scrollStart = function (x, y, vw, vh, dx, dy) {
    var c = viewport(x, y, vw, vh);
    return PD.scrollStartCSS(c.x, c.y, dx * c.k, dy * c.k);
  };
  PD.scrollMore = function (dx, dy, vw) {
    var k = scaleFor(vw);
    return PD.scrollMoreCSS(dx * k, dy * k);
  };
  PD.editable = function () { return { editable: isEditable(activeElement()) }; };

  // ---------- messages from the parent frame ----------
  window.addEventListener('message', function (e) {
    var d = e.data && e.data.__pd;
    if (!d || d.token !== TOKEN || isTop || e.source !== window.parent) { return; }
    try {
      switch (d.t) {
        case 'down': PD.downCSS(d.x, d.y, d.button, d.detail, d.mods); break;
        case 'move': PD.moveCSS(d.x, d.y, d.mods); break;
        case 'up': PD.upCSS(d.x, d.y, d.mods); break;
        case 'hover': PD.hoverCSS(d.x, d.y); break;
        case 'leave': PD.leave(); break;
        case 'scrollStart': PD.scrollStartCSS(d.x, d.y, d.dx, d.dy); break;
        case 'scrollMore': PD.scrollMoreCSS(d.dx, d.dy); break;
        case 'text': PD.text(d.text); break;
        case 'key': PD.key(d.key, d.mods); break;
        case 'shortcut': PD.shortcut(d.key, d.mods); break;
      }
    } catch (err) {}
  }, false);

  // A visible ring on the focused field, since WebKit hides the caret while the view isn't first responder.
  function addFocusStyle() {
    if (!document.documentElement || document.getElementById('__pd_focus_style')) { return; }
    var style = document.createElement('style');
    style.id = '__pd_focus_style';
    style.textContent = 'input:focus,textarea:focus,[contenteditable]:focus{outline:2px solid rgba(74,143,255,.85)!important;outline-offset:1px!important}';
    (document.head || document.documentElement).appendChild(style);
  }
  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', addFocusStyle); } else { addFocusStyle(); }
})();
"""#

    /// Keep desktop-user-agent pages tied to the actual window, rather than iPhone's 980px canvas.
    static let viewport = #"""
(function () {
  function fit() {
    if (!document.documentElement) { return; }
    var meta = document.querySelector('meta[name="viewport"]');
    if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; (document.head || document.documentElement).appendChild(meta); }
    var content = 'width=device-width, initial-scale=1';
    if (meta.content !== content) { meta.content = content; }
  }
  fit();
  document.addEventListener('DOMContentLoaded', fit, { once: true });
})();
"""#

    static let media = #"""
(function () {
  function inlineVideos(root) {
    if (root.tagName === 'VIDEO') { root.setAttribute('playsinline', ''); root.setAttribute('webkit-playsinline', ''); }
    if (root.querySelectorAll) { root.querySelectorAll('video').forEach(function (v) { v.setAttribute('playsinline', ''); v.setAttribute('webkit-playsinline', ''); }); }
  }
  function started() {
    try { window.webkit.messageHandlers.pocketdesk.postMessage({ type: 'mediaPlayback' }); } catch (e) {}
  }
  document.addEventListener('play', started, true);
  document.addEventListener('playing', started, true);
  function observe() {
    inlineVideos(document);
    new MutationObserver(function (changes) {
      changes.forEach(function (change) { change.addedNodes.forEach(inlineVideos); });
    }).observe(document.documentElement, { childList: true, subtree: true });
  }
  if (document.documentElement) { observe(); } else { document.addEventListener('DOMContentLoaded', observe, { once: true }); }
  window.__pdEnableSound = function () {
    started();
    document.querySelectorAll('video,audio').forEach(function (m) {
      if (!m.paused && !m.ended) { m.muted = false; m.defaultMuted = false; if (!m.volume) { m.volume = 1; } }
    });
    for (var i = 0; i < window.frames.length; i++) { window.frames[i].postMessage({ __pdEnableSound: true }, '*'); }
  };
  window.addEventListener('message', function (e) {
    if (window !== window.top && e.source === window.parent && e.data && e.data.__pdEnableSound === true) { window.__pdEnableSound(); }
  });
})();
"""#

    /// Page-world shim: iPhone WebKit has no element fullscreen, so videos would try to open the
    /// native player (which can't be controlled on a non-interactive display). Instead the element
    /// fills the viewport and the window goes fullscreen on the monitor.
    ///
    /// Sites look for the API the way browsers expose it: YouTube only listens for fullscreen
    /// changes once `"onfullscreenchange" in document` is true, so the handler properties exist
    /// too. An element inside a frame asks its parent to fill the viewport with that frame,
    /// and only the top frame tells the app.
    static let fullscreen = #"""
(function () {
  if (window.__pdFullscreenInstalled) { return; }
  window.__pdFullscreenInstalled = true;
  var isTop = window === window.top;
  var current = null, lifted = [];
  var CHANGE = ['fullscreenchange', 'webkitfullscreenchange'];
  var css = '.__pd_fs{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;' +
    'min-width:0!important;min-height:0!important;max-width:none!important;max-height:none!important;margin:0!important;' +
    'padding:0!important;border:0!important;box-sizing:border-box!important;z-index:2147483647!important;background:#000!important;' +
    'transform:none!important;translate:none!important;rotate:none!important;scale:none!important}' +
    'video.__pd_fs,.__pd_fs video{object-fit:contain!important}' +
    /* Real fullscreen uses the top layer; without it these ancestor styles would trap or clip the element. */
    '.__pd_fs_up{transform:none!important;translate:none!important;rotate:none!important;scale:none!important;' +
    'perspective:none!important;filter:none!important;backdrop-filter:none!important;-webkit-backdrop-filter:none!important;' +
    'contain:none!important;container-type:normal!important;content-visibility:visible!important;will-change:auto!important;' +
    'clip-path:none!important;mask:none!important;-webkit-mask:none!important;opacity:1!important;z-index:2147483647!important}';

  function parentOf(node) {
    if (node.parentElement) { return node.parentElement; }
    var root = node.getRootNode ? node.getRootNode() : null;
    return root && root.host ? root.host : null;
  }
  function addStyle(node) {
    var root = node.getRootNode ? node.getRootNode() : document;
    var shadow = root.nodeType === 11;
    if ((shadow ? root : document).getElementById('__pd_fs_style')) { return; }
    var container = shadow ? root : (document.head || document.documentElement);
    if (!container) { return; }
    var style = document.createElement('style'); style.id = '__pd_fs_style'; style.textContent = css;
    container.appendChild(style);
  }
  function lift(el) {
    addStyle(el);
    el.classList.add('__pd_fs');
    for (var node = parentOf(el); node; node = parentOf(node)) {
      addStyle(node);
      node.classList.add('__pd_fs_up');
      lifted.push(node);
    }
  }
  function drop() {
    if (current) { current.classList.remove('__pd_fs'); }
    lifted.forEach(function (node) { node.classList.remove('__pd_fs_up'); });
    lifted = [];
  }
  function fire(el, names) {
    var target = el && el.isConnected ? el : document;
    names.forEach(function (name) {
      try { target.dispatchEvent(new Event(name, { bubbles: true, composed: true })); } catch (e) {}
    });
  }
  function tell(on) {
    if (isTop) {
      try { window.webkit.messageHandlers.pocketdesk.postMessage({ type: 'fullscreen', on: on }); } catch (e) {}
    } else {
      try { window.parent.postMessage({ __pdFullscreen: on ? 'enter' : 'exit' }, '*'); } catch (e2) {}
    }
  }
  function enter(el) {
    if (!el || el.nodeType !== 1) { return Promise.reject(new TypeError('Not an element')); }
    if (el === current) { return Promise.resolve(); }
    var previous = current;
    drop();
    current = el;
    // The whole page going fullscreen only needs the window to fill the monitor.
    if (el !== document.documentElement && el !== document.body) { lift(el); }
    tell(true);
    setTimeout(function () {
      if (previous) { fire(previous, CHANGE); }
      fire(el, CHANGE);
      if (el.tagName === 'VIDEO') { fire(el, ['webkitbeginfullscreen']); }
    }, 0);
    return Promise.resolve();
  }
  function exit(fromParent) {
    var el = current;
    if (el) {
      drop();
      current = null;
      if (!fromParent) { tell(false); }
      setTimeout(function () { fire(el, CHANGE.concat(['webkitendfullscreen'])); }, 0);
    }
    for (var i = 0; i < window.frames.length; i++) {
      try { window.frames[i].postMessage({ __pdExitFullscreen: true }, '*'); } catch (e) {}
    }
    return Promise.resolve();
  }
  function frameFor(source) {
    var frames = document.querySelectorAll('iframe,frame');
    for (var i = 0; i < frames.length; i++) { if (frames[i].contentWindow === source) { return frames[i]; } }
    return null;
  }
  function allowed(frame) {
    if (frame.hasAttribute('allowfullscreen') || frame.hasAttribute('webkitallowfullscreen') ||
        /(^|[;\s])fullscreen\b/.test(frame.getAttribute('allow') || '')) { return true; }
    try { return !!frame.contentDocument; } catch (e) { return false; }
  }
  window.addEventListener('message', function (e) {
    var data = e.data;
    if (!data || typeof data !== 'object' || !e.source) { return; }
    if (data.__pdExitFullscreen === true) {
      if (!isTop && e.source === window.parent) { exit(true); }
      return;
    }
    if (data.__pdFullscreen !== 'enter' && data.__pdFullscreen !== 'exit') { return; }
    var frame = frameFor(e.source);
    if (!frame) { return; }
    if (data.__pdFullscreen === 'exit') { if (current === frame) { exit(); } } else if (allowed(frame)) { enter(frame); }
  });

  function handlerProperty(proto, type) {
    if (!proto || ('on' + type) in proto) { return; }
    var slot = Symbol(type);
    try {
      Object.defineProperty(proto, 'on' + type, {
        configurable: true, enumerable: true,
        get: function () { return this[slot] || null; },
        set: function (fn) {
          if (this[slot]) { this.removeEventListener(type, this[slot]); }
          this[slot] = typeof fn === 'function' ? fn : null;
          if (this[slot]) { this.addEventListener(type, this[slot]); }
        }
      });
    } catch (e) {}
  }
  ['fullscreenchange', 'fullscreenerror', 'webkitfullscreenchange', 'webkitfullscreenerror'].forEach(function (type) {
    handlerProperty(window.Document && Document.prototype, type);
    handlerProperty(window.Element && Element.prototype, type);
  });

  var EP = Element.prototype;
  EP.requestFullscreen = function () { return enter(this); };
  EP.webkitRequestFullscreen = EP.requestFullscreen;
  EP.webkitRequestFullScreen = EP.requestFullscreen;
  if (window.HTMLVideoElement) {
    var VP = HTMLVideoElement.prototype;
    VP.webkitEnterFullscreen = function () { enter(this); };
    VP.webkitEnterFullScreen = VP.webkitEnterFullscreen;
    VP.webkitExitFullscreen = function () { if (current === this) { exit(); } };
    VP.webkitExitFullScreen = VP.webkitExitFullscreen;
    try { Object.defineProperty(VP, 'webkitSupportsFullscreen', { get: function () { return true; }, configurable: true }); } catch (e) {}
    try { Object.defineProperty(VP, 'webkitDisplayingFullscreen', { get: function () { return current === this; }, configurable: true }); } catch (e) {}
  }
  document.exitFullscreen = function () { return exit(); };
  document.webkitExitFullscreen = document.exitFullscreen;
  document.webkitCancelFullScreen = document.exitFullscreen;
  function define(name, getter) {
    try { Object.defineProperty(document, name, { get: getter, configurable: true }); } catch (e) {}
  }
  define('fullscreenElement', function () { return current; });
  define('webkitFullscreenElement', function () { return current; });
  define('webkitCurrentFullScreenElement', function () { return current; });
  define('fullscreenEnabled', function () { return true; });
  define('webkitFullscreenEnabled', function () { return true; });
  define('fullscreen', function () { return !!current; });
  define('webkitIsFullScreen', function () { return !!current; });
  window.__pdExitFullscreen = function () { exit(); };
})();
"""#
}
