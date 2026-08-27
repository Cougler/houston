// Houston's element inspector, injected into web previews as a WKUserScript
// at document start (main frame only). Everything here is best-effort: each
// probe degrades to null/[] rather than throwing, because the page's own
// code must never break — and vice versa.
(function () {
    'use strict';
    if (window.__houston) { return; }

    var HANDLER = 'houstonInspect';
    var MAX_HTML = 1024;
    var MAX_TEXT = 200;
    var MAX_STYLE_MATCHES = 30;

    function post(type, payload) {
        try {
            var bridge = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers[HANDLER];
            if (bridge) { bridge.postMessage(JSON.stringify({ type: type, payload: payload || null })); }
        } catch (e) { /* bridge gone (teardown) — nothing to do */ }
    }

    // ---- addEventListener patch -------------------------------------------
    // Must run before app code: records which script registered a listener on
    // which target. The source comes from the stack AT REGISTRATION TIME —
    // JavaScriptCore frames look like `fnName@http://localhost:5173/src/a.ts:10:20`
    // (no Chrome-style "at fn (...)"), so the parse is anchored on "@".
    var listenerMap = new WeakMap();

    function registrationSource() {
        try {
            var lines = String(new Error().stack || '').split('\n');
            for (var i = 0; i < lines.length; i++) {
                var at = lines[i].indexOf('@');
                if (at < 0) { continue; }
                var url = lines[i].slice(at + 1);
                // Skip our own frames — injected user scripts carry no
                // http(s) URL.
                if (url.indexOf('http://') === 0 || url.indexOf('https://') === 0) {
                    return url;
                }
            }
        } catch (e) { /* stack shape surprised us — no source, not a failure */ }
        return null;
    }

    try {
        var originalAdd = EventTarget.prototype.addEventListener;
        EventTarget.prototype.addEventListener = function (type, listener, options) {
            try {
                if (this instanceof Element && typeof listener === 'function') {
                    var records = listenerMap.get(this);
                    if (!records) { records = []; listenerMap.set(this, records); }
                    if (records.length < 20) {
                        records.push({
                            type: String(type),
                            source: registrationSource(),
                            name: listener.name || null
                        });
                    }
                }
            } catch (e) { /* recording must never block the real call */ }
            return originalAdd.call(this, type, listener, options);
        };
    } catch (e) { /* frozen prototype — inspect still works minus listeners */ }

    // ---- overlay ----------------------------------------------------------
    var overlay = null, label = null, pinLayer = null;
    var inspecting = false;
    var hoverTarget = null, rafPending = false;
    // The clicked element: while set, the overlay stays pinned to it and
    // hover tracking pauses, so mousing toward the inspector doesn't
    // re-highlight everything on the way.
    var lockedEl = null;

    function ownedNode(el) {
        return el && (el === overlay || el === label
            || (overlay && overlay.contains(el)) || (label && label.contains(el))
            || (pinLayer && pinLayer.contains(el)));
    }

    function ensureOverlay() {
        if (overlay) { return; }
        overlay = document.createElement('div');
        overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;'
            + 'background:rgba(94,129,255,0.18);border:1px solid rgba(94,129,255,0.9);'
            + 'border-radius:2px;display:none;';
        label = document.createElement('div');
        label.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;'
            + 'background:#1e1e1e;color:#fff;font:11px -apple-system,sans-serif;'
            + 'padding:2px 6px;border-radius:4px;display:none;white-space:nowrap;';
        document.documentElement.appendChild(overlay);
        document.documentElement.appendChild(label);
    }

    function positionOverlay(el) {
        var r = el.getBoundingClientRect();
        overlay.style.display = 'block';
        overlay.style.left = r.left + 'px';
        overlay.style.top = r.top + 'px';
        overlay.style.width = r.width + 'px';
        overlay.style.height = r.height + 'px';
        label.style.display = 'block';
        label.textContent = describe(el);
        var top = r.top - 22;
        label.style.left = Math.max(4, r.left) + 'px';
        label.style.top = (top < 4 ? r.bottom + 4 : top) + 'px';
    }

    function describe(el) {
        var s = el.tagName.toLowerCase();
        if (el.id) { s += '#' + el.id; }
        var classes = classList(el);
        for (var i = 0; i < Math.min(classes.length, 2); i++) { s += '.' + classes[i]; }
        return s;
    }

    function onMove(event) {
        if (lockedEl) { return; }
        var el = event.target;
        if (!(el instanceof Element) || ownedNode(el)) { return; }
        hoverTarget = el;
        if (rafPending) { return; }
        rafPending = true;
        requestAnimationFrame(function () {
            rafPending = false;
            if (inspecting && !lockedEl && hoverTarget) { positionOverlay(hoverTarget); }
        });
    }

    function onClick(event) {
        if (!inspecting) { return; }
        var el = event.target;
        if (!(el instanceof Element) || ownedNode(el)) { return; }
        event.preventDefault();
        event.stopImmediatePropagation();
        lockedEl = el;
        ensureOverlay();
        positionOverlay(el);
        post('selected', buildPayload(el));
    }

    // Keep the pinned highlight glued to its element through scrolls and
    // resizes (the overlay is position:fixed, so viewport rects go stale).
    function onViewportChange() {
        if (inspecting && lockedEl) { positionOverlay(lockedEl); }
    }

    function clearSelection() {
        lockedEl = null;
        if (overlay) { overlay.style.display = 'none'; }
        if (label) { label.style.display = 'none'; }
    }

    function onKey(event) {
        if (inspecting && event.key === 'Escape') {
            event.preventDefault();
            event.stopImmediatePropagation();
            setInspect(false);
            post('inspectExited');
        }
    }

    function setInspect(on) {
        on = !!on;
        if (on === inspecting) { return; }
        inspecting = on;
        if (on) {
            ensureOverlay();
            window.addEventListener('mousemove', onMove, true);
            window.addEventListener('click', onClick, true);
            window.addEventListener('keydown', onKey, true);
            window.addEventListener('scroll', onViewportChange, { capture: true, passive: true });
            window.addEventListener('resize', onViewportChange);
        } else {
            window.removeEventListener('mousemove', onMove, true);
            window.removeEventListener('click', onClick, true);
            window.removeEventListener('keydown', onKey, true);
            window.removeEventListener('scroll', onViewportChange, { capture: true });
            window.removeEventListener('resize', onViewportChange);
            clearSelection();
            hoverTarget = null;
        }
    }

    // ---- payload builders -------------------------------------------------
    function classList(el) {
        try {
            // SVG className is an SVGAnimatedString — go through the attribute.
            var raw = el.getAttribute('class') || '';
            return raw.split(/\s+/).filter(function (c) { return c.length > 0; });
        } catch (e) { return []; }
    }

    function cssEscapeIdent(s) {
        try { return CSS.escape(s); } catch (e) { return s.replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }
    }

    function buildSelector(el) {
        try {
            if (el.id) {
                var byId = '#' + cssEscapeIdent(el.id);
                if (document.querySelectorAll(byId).length === 1) { return byId; }
            }
            var parts = [];
            var node = el;
            for (var depth = 0; node && node instanceof Element && depth < 5; depth++) {
                var part = node.tagName.toLowerCase();
                if (node.id) {
                    parts.unshift('#' + cssEscapeIdent(node.id));
                    break;
                }
                var classes = classList(node).slice(0, 2);
                for (var i = 0; i < classes.length; i++) { part += '.' + cssEscapeIdent(classes[i]); }
                var parent = node.parentElement;
                if (parent) {
                    var sameTag = 0, index = 0;
                    for (var c = 0; c < parent.children.length; c++) {
                        if (parent.children[c].tagName === node.tagName) {
                            sameTag++;
                            if (parent.children[c] === node) { index = sameTag; }
                        }
                    }
                    if (sameTag > 1) { part += ':nth-of-type(' + index + ')'; }
                }
                parts.unshift(part);
                if (node.tagName === 'BODY') { break; }
                node = parent;
            }
            var selector = parts.join(' > ');
            return selector || el.tagName.toLowerCase();
        } catch (e) {
            return el.tagName ? el.tagName.toLowerCase() : '*';
        }
    }

    function buildStructure(el) {
        // React ≤18: fiber._debugSource {fileName, lineNumber, columnNumber}.
        // React 19 removed it — expected, fall through silently.
        try {
            var keys = Object.keys(el);
            for (var i = 0; i < keys.length; i++) {
                if (keys[i].indexOf('__reactFiber$') === 0) {
                    var fiber = el[keys[i]];
                    for (var hop = 0; fiber && hop < 10; hop++) {
                        var src = fiber._debugSource;
                        if (src && src.fileName) {
                            return {
                                file: String(src.fileName),
                                line: src.lineNumber || null,
                                column: src.columnNumber || null,
                                framework: 'react'
                            };
                        }
                        fiber = fiber.return;
                    }
                    break;
                }
            }
        } catch (e) { }
        try {
            var vue = el.__vueParentComponent;
            if (vue && vue.type && vue.type.__file) {
                return { file: String(vue.type.__file), line: null, column: null, framework: 'vue' };
            }
        } catch (e) { }
        try {
            var meta = el.__svelte_meta;
            if (meta && meta.loc && meta.loc.file) {
                return {
                    file: String(meta.loc.file),
                    line: (meta.loc.line != null) ? meta.loc.line : null,
                    column: (meta.loc.column != null) ? meta.loc.column : null,
                    framework: 'svelte'
                };
            }
        } catch (e) { }
        return null;
    }

    function collectRules(rules, el, out) {
        for (var i = 0; i < rules.length && out.length < MAX_STYLE_MATCHES; i++) {
            var rule = rules[i];
            try {
                if (rule.selectorText) {
                    if (el.matches(rule.selectorText)) {
                        var sheet = rule.parentStyleSheet;
                        var source = (sheet && sheet.href) || null;
                        if (!source && sheet && sheet.ownerNode && sheet.ownerNode.getAttribute) {
                            // Vite dev injects <style data-vite-dev-id="/abs/file.css">.
                            source = sheet.ownerNode.getAttribute('data-vite-dev-id');
                        }
                        out.push({
                            selector: rule.selectorText,
                            source: source || 'inline <style>',
                            inline: false
                        });
                    }
                } else if (rule.cssRules) {
                    // One level into @media / @supports.
                    collectRules(rule.cssRules, el, out);
                }
            } catch (e) { /* exotic selector — skip the rule */ }
        }
    }

    function buildStyles(el) {
        var out = [];
        try {
            var sheets = document.styleSheets;
            for (var i = 0; i < sheets.length && out.length < MAX_STYLE_MATCHES; i++) {
                var rules;
                try { rules = sheets[i].cssRules; } catch (e) { continue; } // cross-origin
                if (rules) { collectRules(rules, el, out); }
            }
        } catch (e) { }
        try {
            if (el.getAttribute('style')) {
                out.push({ selector: 'style attribute', source: 'style attribute', inline: true });
            }
        } catch (e) { }
        return out;
    }

    function buildScripts(el) {
        var out = [];
        // Patched-listener records for the element and 2 ancestor levels.
        try {
            var node = el;
            for (var level = 0; node && level < 3; level++) {
                var records = listenerMap.get(node);
                if (records) {
                    for (var i = 0; i < records.length && out.length < 20; i++) {
                        out.push({
                            type: records[i].type,
                            source: records[i].source,
                            name: records[i].name,
                            origin: 'listener'
                        });
                    }
                }
                node = node.parentElement;
            }
        } catch (e) { }
        // Inline on* attributes.
        try {
            for (var a = 0; a < el.attributes.length; a++) {
                var attr = el.attributes[a];
                if (attr.name.indexOf('on') === 0) {
                    out.push({ type: attr.name, source: null, name: null, origin: 'inline' });
                }
            }
        } catch (e) { }
        // React delegates real listeners at the root, so the WeakMap is
        // usually empty for React apps — the fiber's on* props are the
        // React answer.
        try {
            var keys = Object.keys(el);
            for (var k = 0; k < keys.length; k++) {
                if (keys[k].indexOf('__reactProps$') === 0) {
                    var props = el[keys[k]];
                    for (var p in props) {
                        if (p.indexOf('on') === 0 && typeof props[p] === 'function' && out.length < 20) {
                            out.push({ type: p, source: null, name: props[p].name || null, origin: 'reactProp' });
                        }
                    }
                    break;
                }
            }
        } catch (e) { }
        return out;
    }

    function buildPayload(el) {
        var rect = { x: 0, y: 0, width: 0, height: 0 };
        try {
            var r = el.getBoundingClientRect();
            rect = { x: r.left, y: r.top, width: r.width, height: r.height };
        } catch (e) { }
        var html = '';
        try { html = String(el.outerHTML || '').slice(0, MAX_HTML); } catch (e) { }
        var text = null;
        try {
            text = String(el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, MAX_TEXT) || null;
        } catch (e) { }
        return {
            tagName: el.tagName ? el.tagName.toLowerCase() : 'unknown',
            id: el.id || null,
            classes: classList(el),
            selector: buildSelector(el),
            outerHTML: html,
            text: text,
            rect: rect,
            structure: buildStructure(el),
            styles: buildStyles(el),
            scripts: buildScripts(el),
            pageURL: String(location.href)
        };
    }

    // ---- annotation pins --------------------------------------------------
    function hidePins() {
        if (pinLayer) {
            try { pinLayer.remove(); } catch (e) { }
            pinLayer = null;
        }
    }

    function showPins(entries) {
        hidePins();
        if (!entries || !entries.length) { return; }
        pinLayer = document.createElement('div');
        pinLayer.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none;z-index:2147483645;';
        for (var i = 0; i < entries.length; i++) {
            try {
                var el = document.querySelector(entries[i].selector);
                if (!el) { continue; } // stale selector — silently skip
                var r = el.getBoundingClientRect();
                var pin = document.createElement('div');
                pin.textContent = String(entries[i].n);
                pin.style.cssText = 'position:absolute;min-width:18px;height:18px;'
                    + 'border-radius:9px;background:#C4506A;color:#fff;'
                    + 'font:600 11px/18px -apple-system,sans-serif;text-align:center;'
                    + 'padding:0 3px;box-shadow:0 1px 3px rgba(0,0,0,0.35);'
                    + 'left:' + (r.left + window.scrollX - 8) + 'px;'
                    + 'top:' + (r.top + window.scrollY - 8) + 'px;';
                pinLayer.appendChild(pin);
            } catch (e) { /* bad selector — skip the pin */ }
        }
        document.documentElement.appendChild(pinLayer);
    }

    window.__houston = {
        version: 1,
        setInspect: setInspect,
        clearSelection: clearSelection,
        showPins: showPins,
        hidePins: hidePins
    };
})();
