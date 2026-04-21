/*
 * ConjureDSP custom-UI component library.
 *
 * Injected by CustomUIWebView as a WKUserScript at document start, right
 * after customui-bridge.js. Adds a set of Web Components and helper
 * primitives on top of `window.ConjureDSP`, so bundle authors can drop
 * in stock controls that match the Swift parameter panel's behavior
 * (parity target), style them via CSS, and reach for creative widgets
 * (XY pad) without writing canvas code themselves.
 *
 * Public surface (v1):
 *
 *   ConjureDSP.ui.version                 // integer; bumped on breaking changes
 *   ConjureDSP.ui.requireVersion(n)       // throws if library is older than n
 *
 *   ConjureDSP.ui.control(i)              // primitive: { value, setValue(v),
 *                                         //             metadata, onChange(cb),
 *                                         //             normalize(v), denormalize(t) }
 *   ConjureDSP.ui.formatValue(v, meta)    // "440 Hz", "-3.2 dB", "12%", etc.
 *   ConjureDSP.ui.denormalize(t, meta)    // 0..1 -> actual (respects log curve)
 *   ConjureDSP.ui.normalize(v, meta)      // actual -> 0..1
 *
 *   <cdp-panel auto>                      // renders one control per parameter
 *   <cdp-slider param="0">                // maps any slider/integer-style param
 *   <cdp-toggle param="1">                // boolean switch for style:"toggle"
 *   <cdp-choice param="2">                // segmented (<=2 opts) or dropdown
 *   <cdp-xy param-x="0" param-y="1">      // 2D pad mapping two parameters
 *
 * Component styling hooks (in order of escalation):
 *   1. CSS custom properties on the host — see THEME_VARS below for the
 *      full list. Cheap and composable.
 *   2. `::part(...)` selectors — `label`, `value`, `track`, `thumb`, `pad`,
 *      `puck`, `option`.
 *   3. Named slots — `label`, `value`.
 *
 * Theme auto-adoption:
 *   The library reads `ConjureDSP.theme` and sets `data-cdp-theme` on each
 *   component host; CSS defaults flip to appropriate light/dark tints. Authors
 *   who want to drive theming themselves can override the attribute.
 */

(function () {
    'use strict';

    if (!window.ConjureDSP) return;
    if (window.ConjureDSP.ui) return;   // already loaded — don't double-install
    var CDP = window.ConjureDSP;

    var VERSION = 1;

    // ------------------------------------------------------------------
    // Primitives
    // ------------------------------------------------------------------

    /**
     * Map a normalized 0..1 value to the parameter's declared range.
     * Honors curve:"log" the same way the Rust kernel does:
     *   linear: min + t*(max-min)
     *   log:    min * (max/min)^t   (min, max > 0)
     */
    function denormalize(t, meta) {
        if (!meta) return t;
        var min = meta.min, max = meta.max;
        if (typeof min !== 'number' || typeof max !== 'number') return t;
        if (meta.curve === 'log' && min > 0 && max > 0) {
            return min * Math.pow(max / min, t);
        }
        return min + t * (max - min);
    }

    function normalize(v, meta) {
        if (!meta) return v;
        var min = meta.min, max = meta.max;
        if (typeof min !== 'number' || typeof max !== 'number' || min === max) return v;
        if (meta.curve === 'log' && min > 0 && max > 0) {
            return Math.log(v / min) / Math.log(max / min);
        }
        return (v - min) / (max - min);
    }

    /**
     * Unit-aware formatting. Matches the AU's formatParamValue intent:
     * Hz -> kHz above 1000, ms -> s above 1000, dB two decimals, etc.
     */
    function formatValue(v, meta) {
        if (v == null || isNaN(v)) return '—';
        if (!meta) return String(+v.toFixed(3));

        if (meta.style === 'toggle') return v >= 0.5 ? 'on' : 'off';
        if (meta.style === 'choice' && Array.isArray(meta.options)) {
            var idx = Math.max(0, Math.min(meta.options.length - 1, Math.round(v)));
            return String(meta.options[idx]);
        }
        if (meta.style === 'integer') return String(Math.round(v)) + (meta.unit ? ' ' + meta.unit : '');

        var unit = meta.unit || '';
        var abs = Math.abs(v);
        // Special-case human-scale rollovers.
        if (unit === 'Hz' && abs >= 1000) {
            return (v / 1000).toFixed(abs >= 10000 ? 1 : 2) + ' kHz';
        }
        if (unit === 'ms' && abs >= 1000) {
            return (v / 1000).toFixed(2) + ' s';
        }
        if (unit === 'dB') return v.toFixed(2) + ' dB';
        if (unit === '%') return Math.round(v) + '%';

        // Generic: two decimals, strip trailing zeros, tack on the unit.
        var s = (Math.abs(v) < 1 ? v.toFixed(3) : v.toFixed(2)).replace(/\.?0+$/, '');
        return unit ? s + ' ' + unit : s;
    }

    /**
     * Wrap a parameter index in an observable control object. Reads
     * actual (denormalized) values from the bridge; writes pass through
     * to `CDP.parameters.set`, which routes to the AU parameter tree.
     */
    function control(index) {
        var meta = CDP.parameters.metadata(index);
        var listeners = [];
        CDP.parameters.onChange(index, function (v) {
            for (var i = 0; i < listeners.length; i++) listeners[i](v);
        });
        return {
            index: index,
            metadata: meta,
            get value() { return CDP.parameters.get(index); },
            setValue: function (v) { CDP.parameters.set(index, v); },
            onChange: function (cb) {
                if (typeof cb === 'function') listeners.push(cb);
                return function off() {
                    var i = listeners.indexOf(cb);
                    if (i >= 0) listeners.splice(i, 1);
                };
            },
            normalize: function (v) { return normalize(v, meta); },
            denormalize: function (t) { return denormalize(t, meta); },
            format: function (v) { return formatValue(v == null ? this.value : v, meta); },
        };
    }

    function requireVersion(n) {
        if (VERSION < n) {
            throw new Error('cdp-ui v' + VERSION + ' too old; need >= v' + n);
        }
    }

    // ------------------------------------------------------------------
    // Shared style block — injected into every component's Shadow DOM.
    // ------------------------------------------------------------------

    // Dark/light CSS custom-property defaults. Authors override at the
    // host level to restyle without piercing the shadow tree.
    var THEME_CSS = [
        ':host {',
        '  display: block;',
        '  --cdp-accent: currentColor;',
        '  --cdp-fg: CanvasText;',
        '  --cdp-bg: Canvas;',
        '  --cdp-muted: color-mix(in srgb, CanvasText 55%, transparent);',
        '  --cdp-track-bg: color-mix(in srgb, CanvasText 14%, transparent);',
        '  --cdp-track-fill: var(--cdp-accent);',
        '  --cdp-border: color-mix(in srgb, CanvasText 20%, transparent);',
        '  --cdp-thumb-size: 16px;',
        '  --cdp-radius: 6px;',
        '  --cdp-font: -apple-system, system-ui, sans-serif;',
        '  --cdp-font-size: 13px;',
        '  --cdp-label-width: 120px;',
        '  --cdp-value-width: 76px;',
        '  font: var(--cdp-font-size) var(--cdp-font);',
        '  color: var(--cdp-fg);',
        '}',
        ':host([hidden]) { display: none; }',
    ].join('\n');

    var ROW_CSS = [
        '.row {',
        '  display: grid;',
        '  grid-template-columns: var(--cdp-label-width) 1fr var(--cdp-value-width);',
        '  align-items: center;',
        '  gap: 12px;',
        '  min-height: 28px;',
        '}',
        '.row > [part="label"] {',
        '  font-weight: 500;',
        '  white-space: nowrap;',
        '  overflow: hidden;',
        '  text-overflow: ellipsis;',
        '}',
        '.row > [part="value"] {',
        '  text-align: right;',
        '  font-variant-numeric: tabular-nums;',
        '  color: var(--cdp-muted);',
        '}',
    ].join('\n');

    // Cross-browser range styling: vendor pseudo-elements have to be
    // listed separately; no WebKit-only shortcut.
    var RANGE_CSS = [
        'input[type=range] {',
        '  appearance: none;',
        '  -webkit-appearance: none;',
        '  width: 100%;',
        '  background: transparent;',
        '  margin: 0;',
        '}',
        'input[type=range]::-webkit-slider-runnable-track {',
        '  height: 4px;',
        '  border-radius: 2px;',
        '  background: var(--cdp-track-bg);',
        '}',
        'input[type=range]::-webkit-slider-thumb {',
        '  -webkit-appearance: none;',
        '  width: var(--cdp-thumb-size);',
        '  height: var(--cdp-thumb-size);',
        '  border-radius: 50%;',
        '  background: var(--cdp-accent);',
        '  margin-top: calc((4px - var(--cdp-thumb-size)) / 2);',
        '  border: none;',
        '  cursor: pointer;',
        '}',
        'input[type=range]:focus { outline: none; }',
        'input[type=range]:focus::-webkit-slider-thumb {',
        '  box-shadow: 0 0 0 3px color-mix(in srgb, var(--cdp-accent) 30%, transparent);',
        '}',
    ].join('\n');

    function styleEl(css) {
        var s = document.createElement('style');
        s.textContent = css;
        return s;
    }

    // ------------------------------------------------------------------
    // Shared behavior: resolve `param` attribute (name or index) to
    // a metadata record + control object. Accepts numeric index or
    // a case-sensitive name match against metadata.name / metadata.key.
    // ------------------------------------------------------------------

    function resolveParamAttr(attr) {
        if (attr == null || attr === '') return -1;
        var n = Number(attr);
        if (!isNaN(n) && n >= 0 && n < CDP.parameters.count) return n | 0;
        // Exact match first (wins over case-insensitive if both are present).
        for (var i = 0; i < CDP.parameters.count; i++) {
            var m = CDP.parameters.metadata(i);
            if (!m) continue;
            if (m.name === attr || m.key === attr) return i;
        }
        // Case-insensitive fallback so the same UI HTML can target both
        // Python presets (lowercase names like `cutoff`) and Rust presets
        // (uppercase names like `CUTOFF` emitted by the params!() macro's
        // `stringify!($NAME)` call).
        var low = String(attr).toLowerCase();
        for (var j = 0; j < CDP.parameters.count; j++) {
            var mj = CDP.parameters.metadata(j);
            if (!mj) continue;
            if ((mj.name && mj.name.toLowerCase() === low) ||
                (mj.key && mj.key.toLowerCase() === low)) return j;
        }
        return -1;
    }

    // Fire `cb` when CDP has sent `_init`. `ready` is safe to call
    // immediately (synchronously invokes if already ready).
    function whenReady(cb) { CDP.ready(cb); }

    // Apply theme attribute + listen for flips.
    function adoptTheme(host) {
        function apply(t) { host.setAttribute('data-cdp-theme', t || 'light'); }
        apply(CDP.theme);
        window.addEventListener('themechange', function (e) {
            apply(e && e.detail && e.detail.theme);
        });
    }

    // ------------------------------------------------------------------
    // <cdp-slider>
    // ------------------------------------------------------------------

    class CdpSlider extends HTMLElement {
        static get observedAttributes() { return ['param']; }

        constructor() {
            super();
            var root = this.attachShadow({ mode: 'open' });
            root.append(
                styleEl(THEME_CSS + '\n' + ROW_CSS + '\n' + RANGE_CSS),
                document.createElement('div')
            );
            root.lastChild.className = 'row';
            root.lastChild.innerHTML = [
                '<span part="label"><slot name="label"></slot></span>',
                '<input type="range" part="track">',
                '<span part="value"><slot name="value"></slot></span>',
            ].join('');
            this._label = root.querySelector('[part="label"]');
            this._input = root.querySelector('input');
            this._value = root.querySelector('[part="value"]');
            adoptTheme(this);
        }

        connectedCallback() { whenReady(() => this._bind()); }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }

        _bind() {
            if (this._offChange) { this._offChange(); this._offChange = null; }
            var idx = resolveParamAttr(this.getAttribute('param'));
            if (idx < 0) {
                this._label.textContent = 'unknown';
                this._input.disabled = true;
                return;
            }
            this._ctrl = control(idx);
            var meta = this._ctrl.metadata || {};
            // Default slot content — authors can override via <span slot="label">.
            if (!this._label.textContent.trim()) {
                this._label.textContent = meta.name || ('Param ' + idx);
            }
            var isInt = meta.style === 'integer';
            // Slider UI works in normalized space so log curves feel uniform.
            this._input.min = 0;
            this._input.max = 1;
            // For integer/choice we still operate on the actual range so the
            // step resolves to integer increments sensibly.
            if (isInt) {
                this._input.min = meta.min;
                this._input.max = meta.max;
                this._input.step = 1;
            } else {
                this._input.step = 0.001;
            }
            var updateUI = (v) => {
                this._input.value = isInt ? v : normalize(v, meta);
                if (!this._value.textContent || !this._value.firstElementChild) {
                    this._value.textContent = formatValue(v, meta);
                }
            };
            updateUI(this._ctrl.value);
            this._offChange = this._ctrl.onChange(updateUI);

            this._input.oninput = () => {
                var actual = isInt
                    ? Math.round(Number(this._input.value))
                    : denormalize(Number(this._input.value), meta);
                this._ctrl.setValue(actual);
                this._value.textContent = formatValue(actual, meta);
            };
        }

        disconnectedCallback() {
            if (this._offChange) this._offChange();
        }
    }

    // ------------------------------------------------------------------
    // <cdp-toggle>
    // ------------------------------------------------------------------

    var TOGGLE_CSS = [
        '.row { grid-template-columns: var(--cdp-label-width) 1fr var(--cdp-value-width); }',
        '.switch {',
        '  --w: 36px; --h: 20px;',
        '  width: var(--w); height: var(--h);',
        '  border-radius: var(--h);',
        '  background: var(--cdp-track-bg);',
        '  position: relative;',
        '  cursor: pointer;',
        '  transition: background 120ms ease;',
        '  flex: 0 0 auto;',
        '  justify-self: start;',
        '}',
        '.switch::before {',
        '  content: ""; position: absolute;',
        '  top: 2px; left: 2px;',
        '  width: calc(var(--h) - 4px); height: calc(var(--h) - 4px);',
        '  border-radius: 50%;',
        '  background: Canvas;',
        '  box-shadow: 0 1px 2px rgba(0,0,0,0.2);',
        '  transition: transform 120ms ease;',
        '}',
        '.switch[aria-checked="true"] { background: var(--cdp-accent); }',
        '.switch[aria-checked="true"]::before {',
        '  transform: translateX(calc(var(--w) - var(--h)));',
        '}',
        '.switch:focus { outline: 3px solid color-mix(in srgb, var(--cdp-accent) 30%, transparent); }',
    ].join('\n');

    class CdpToggle extends HTMLElement {
        static get observedAttributes() { return ['param']; }
        constructor() {
            super();
            var root = this.attachShadow({ mode: 'open' });
            root.append(styleEl(THEME_CSS + '\n' + ROW_CSS + '\n' + TOGGLE_CSS));
            root.innerHTML += [
                '<div class="row">',
                '  <span part="label"><slot name="label"></slot></span>',
                '  <div class="switch" part="thumb" role="switch" tabindex="0" aria-checked="false"></div>',
                '  <span part="value"><slot name="value"></slot></span>',
                '</div>',
            ].join('\n');
            this._label = root.querySelector('[part="label"]');
            this._sw = root.querySelector('.switch');
            this._value = root.querySelector('[part="value"]');
            adoptTheme(this);
        }

        connectedCallback() {
            whenReady(() => this._bind());
            this._sw.addEventListener('click', () => this._flip());
            this._sw.addEventListener('keydown', (e) => {
                if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); this._flip(); }
            });
        }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }
        disconnectedCallback() { if (this._offChange) this._offChange(); }

        _flip() {
            if (!this._ctrl) return;
            var v = this._ctrl.value >= 0.5 ? 0 : 1;
            this._ctrl.setValue(v);
            this._render(v);
        }

        _bind() {
            if (this._offChange) { this._offChange(); this._offChange = null; }
            var idx = resolveParamAttr(this.getAttribute('param'));
            if (idx < 0) { this._label.textContent = 'unknown'; return; }
            this._ctrl = control(idx);
            var meta = this._ctrl.metadata || {};
            if (!this._label.textContent.trim()) {
                this._label.textContent = meta.name || ('Param ' + idx);
            }
            this._render(this._ctrl.value);
            this._offChange = this._ctrl.onChange((v) => this._render(v));
        }

        _render(v) {
            var on = v >= 0.5;
            this._sw.setAttribute('aria-checked', on ? 'true' : 'false');
            this._value.textContent = on ? 'on' : 'off';
        }
    }

    // ------------------------------------------------------------------
    // <cdp-choice> — segmented when options.length <= 2, dropdown otherwise.
    // ------------------------------------------------------------------

    var CHOICE_CSS = [
        '.seg {',
        '  display: inline-flex;',
        '  border: 1px solid var(--cdp-border);',
        '  border-radius: var(--cdp-radius);',
        '  overflow: hidden;',
        '  justify-self: start;',
        '}',
        '.seg button {',
        '  all: unset;',
        '  padding: 4px 12px;',
        '  cursor: pointer;',
        '  color: var(--cdp-fg);',
        '  background: transparent;',
        '}',
        '.seg button[aria-pressed="true"] {',
        '  background: var(--cdp-accent);',
        '  color: Canvas;',
        '}',
        'select {',
        '  font: inherit; color: inherit;',
        '  background: Canvas;',
        '  border: 1px solid var(--cdp-border);',
        '  border-radius: var(--cdp-radius);',
        '  padding: 3px 6px;',
        '  justify-self: start;',
        '}',
    ].join('\n');

    class CdpChoice extends HTMLElement {
        static get observedAttributes() { return ['param']; }
        constructor() {
            super();
            this.attachShadow({ mode: 'open' }).append(
                styleEl(THEME_CSS + '\n' + ROW_CSS + '\n' + CHOICE_CSS),
                document.createElement('div')
            );
            this.shadowRoot.lastChild.className = 'row';
            this.shadowRoot.lastChild.innerHTML = [
                '<span part="label"><slot name="label"></slot></span>',
                '<span class="slot-mount"></span>',
                '<span part="value"><slot name="value"></slot></span>',
            ].join('');
            this._label = this.shadowRoot.querySelector('[part="label"]');
            this._slotMount = this.shadowRoot.querySelector('.slot-mount');
            this._value = this.shadowRoot.querySelector('[part="value"]');
            adoptTheme(this);
        }

        connectedCallback() { whenReady(() => this._bind()); }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }
        disconnectedCallback() { if (this._offChange) this._offChange(); }

        _bind() {
            if (this._offChange) { this._offChange(); this._offChange = null; }
            var idx = resolveParamAttr(this.getAttribute('param'));
            if (idx < 0) { this._label.textContent = 'unknown'; return; }
            this._ctrl = control(idx);
            var meta = this._ctrl.metadata || {};
            var opts = Array.isArray(meta.options) ? meta.options : [];
            if (!this._label.textContent.trim()) {
                this._label.textContent = meta.name || ('Param ' + idx);
            }
            this._slotMount.innerHTML = '';
            if (opts.length <= 2 && opts.length > 0) {
                this._mountSegmented(opts);
            } else {
                this._mountDropdown(opts);
            }
            this._render(this._ctrl.value);
            this._offChange = this._ctrl.onChange((v) => this._render(v));
        }

        _mountSegmented(opts) {
            var seg = document.createElement('div');
            seg.className = 'seg';
            seg.setAttribute('part', 'option');
            opts.forEach((label, i) => {
                var b = document.createElement('button');
                b.type = 'button';
                b.textContent = label;
                b.dataset.i = i;
                b.onclick = () => this._ctrl.setValue(i);
                seg.append(b);
            });
            this._slotMount.append(seg);
            this._buttons = Array.from(seg.children);
            this._select = null;
        }

        _mountDropdown(opts) {
            var sel = document.createElement('select');
            sel.setAttribute('part', 'option');
            opts.forEach((label, i) => {
                var o = document.createElement('option');
                o.value = String(i);
                o.textContent = label;
                sel.append(o);
            });
            sel.onchange = () => this._ctrl.setValue(Number(sel.value));
            this._slotMount.append(sel);
            this._select = sel;
            this._buttons = null;
        }

        _render(v) {
            var meta = this._ctrl.metadata || {};
            var opts = Array.isArray(meta.options) ? meta.options : [];
            var i = Math.max(0, Math.min(opts.length - 1, Math.round(v)));
            if (this._buttons) {
                this._buttons.forEach((b, j) => b.setAttribute('aria-pressed', String(j === i)));
            }
            if (this._select) this._select.value = String(i);
            this._value.textContent = opts[i] != null ? String(opts[i]) : '';
        }
    }

    // ------------------------------------------------------------------
    // <cdp-xy> — 2D pad mapping two parameters.
    //   <cdp-xy param-x="0" param-y="1" [invert-y]>
    // ------------------------------------------------------------------

    var XY_CSS = [
        ':host { --cdp-xy-size: 160px; }',
        '.pad {',
        '  position: relative;',
        '  width: 100%;',
        '  aspect-ratio: 1;',
        '  max-width: var(--cdp-xy-size);',
        '  background: var(--cdp-track-bg);',
        '  border: 1px solid var(--cdp-border);',
        '  border-radius: var(--cdp-radius);',
        '  touch-action: none;',
        '  overflow: hidden;',
        '}',
        '.puck {',
        '  position: absolute;',
        '  width: 16px; height: 16px;',
        '  margin: -8px 0 0 -8px;',
        '  border-radius: 50%;',
        '  background: var(--cdp-accent);',
        '  box-shadow: 0 1px 3px rgba(0,0,0,0.25);',
        '  pointer-events: none;',
        '}',
        '.pad:focus { outline: 3px solid color-mix(in srgb, var(--cdp-accent) 30%, transparent); }',
        '.xy-label { display: flex; gap: 8px; font-size: 0.9em; color: var(--cdp-muted); margin-top: 4px; }',
    ].join('\n');

    class CdpXY extends HTMLElement {
        static get observedAttributes() { return ['param-x', 'param-y', 'invert-y']; }
        constructor() {
            super();
            var root = this.attachShadow({ mode: 'open' });
            root.append(styleEl(THEME_CSS + '\n' + XY_CSS));
            root.innerHTML += [
                '<div class="pad" part="pad" tabindex="0">',
                '  <div class="puck" part="puck"></div>',
                '</div>',
                '<div class="xy-label"><span class="vx"></span><span class="vy"></span></div>',
            ].join('\n');
            this._pad = root.querySelector('.pad');
            this._puck = root.querySelector('.puck');
            this._vx = root.querySelector('.vx');
            this._vy = root.querySelector('.vy');
            adoptTheme(this);
        }

        connectedCallback() {
            whenReady(() => this._bind());
            this._pad.addEventListener('pointerdown', (e) => this._startDrag(e));
            this._pad.addEventListener('keydown', (e) => this._onKey(e));
        }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }
        disconnectedCallback() {
            if (this._offX) this._offX();
            if (this._offY) this._offY();
        }

        _bind() {
            if (this._offX) this._offX();
            if (this._offY) this._offY();
            var ix = resolveParamAttr(this.getAttribute('param-x'));
            var iy = resolveParamAttr(this.getAttribute('param-y'));
            if (ix < 0 || iy < 0) return;
            this._cx = control(ix);
            this._cy = control(iy);
            this._invertY = this.hasAttribute('invert-y');
            this._render();
            this._offX = this._cx.onChange(() => this._render());
            this._offY = this._cy.onChange(() => this._render());
        }

        _render() {
            if (!this._cx || !this._cy) return;
            var tx = normalize(this._cx.value, this._cx.metadata);
            var ty = normalize(this._cy.value, this._cy.metadata);
            if (this._invertY) ty = 1 - ty;
            this._puck.style.left = (tx * 100) + '%';
            this._puck.style.top = (ty * 100) + '%';
            this._vx.textContent = this._cx.format();
            this._vy.textContent = this._cy.format();
        }

        _startDrag(e) {
            if (!this._cx || !this._cy) return;
            var rect = this._pad.getBoundingClientRect();
            this._pad.setPointerCapture(e.pointerId);
            var apply = (ev) => {
                var tx = clamp((ev.clientX - rect.left) / rect.width, 0, 1);
                var ty = clamp((ev.clientY - rect.top) / rect.height, 0, 1);
                var tyParam = this._invertY ? 1 - ty : ty;
                this._cx.setValue(denormalize(tx, this._cx.metadata));
                this._cy.setValue(denormalize(tyParam, this._cy.metadata));
            };
            apply(e);
            var move = (ev) => apply(ev);
            var up = (ev) => {
                try { this._pad.releasePointerCapture(ev.pointerId); } catch (_) {}
                this._pad.removeEventListener('pointermove', move);
                this._pad.removeEventListener('pointerup', up);
                this._pad.removeEventListener('pointercancel', up);
            };
            this._pad.addEventListener('pointermove', move);
            this._pad.addEventListener('pointerup', up);
            this._pad.addEventListener('pointercancel', up);
        }

        _onKey(e) {
            if (!this._cx || !this._cy) return;
            var step = e.shiftKey ? 0.01 : 0.05;
            var dx = 0, dy = 0;
            if (e.key === 'ArrowLeft') dx = -step;
            else if (e.key === 'ArrowRight') dx = step;
            else if (e.key === 'ArrowUp') dy = this._invertY ? step : -step;
            else if (e.key === 'ArrowDown') dy = this._invertY ? -step : step;
            else return;
            e.preventDefault();
            var tx = clamp(normalize(this._cx.value, this._cx.metadata) + dx, 0, 1);
            var ty = clamp(normalize(this._cy.value, this._cy.metadata) + (this._invertY ? -dy : dy), 0, 1);
            this._cx.setValue(denormalize(tx, this._cx.metadata));
            this._cy.setValue(denormalize(ty, this._cy.metadata));
        }
    }

    function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

    // ------------------------------------------------------------------
    // <cdp-panel auto> — renders one appropriate control per parameter.
    // Replaces the previous hand-rolled starterIndexHTML() slider list
    // and matches the Swift ParameterSlidersView component-picking logic.
    // ------------------------------------------------------------------

    var PANEL_CSS = [
        ':host { display: block; }',
        '.rows { display: flex; flex-direction: column; gap: 10px; }',
    ].join('\n');

    class CdpPanel extends HTMLElement {
        constructor() {
            super();
            this.attachShadow({ mode: 'open' });
            adoptTheme(this);
        }
        connectedCallback() { whenReady(() => this._render()); }

        _render() {
            this.shadowRoot.innerHTML = '';
            this.shadowRoot.append(styleEl(THEME_CSS + '\n' + PANEL_CSS));
            if (!this.hasAttribute('auto')) {
                // Honor whatever light-DOM children the author provided.
                var slot = document.createElement('slot');
                this.shadowRoot.append(slot);
                return;
            }
            var rows = document.createElement('div');
            rows.className = 'rows';
            rows.setAttribute('part', 'rows');
            for (var i = 0; i < CDP.parameters.count; i++) {
                var meta = CDP.parameters.metadata(i) || {};
                var tag;
                if (meta.style === 'toggle') tag = 'cdp-toggle';
                else if (meta.style === 'choice') tag = 'cdp-choice';
                else tag = 'cdp-slider';
                var el = document.createElement(tag);
                el.setAttribute('param', String(i));
                rows.append(el);
            }
            this.shadowRoot.append(rows);
        }
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    // Guard against double-registration if the bundle also loads its
    // own copy of the library (harmless but tidier).
    function define(name, ctor) {
        if (!customElements.get(name)) customElements.define(name, ctor);
    }
    define('cdp-slider', CdpSlider);
    define('cdp-toggle', CdpToggle);
    define('cdp-choice', CdpChoice);
    define('cdp-xy', CdpXY);
    define('cdp-panel', CdpPanel);

    CDP.ui = {
        version: VERSION,
        requireVersion: requireVersion,
        control: control,
        formatValue: formatValue,
        denormalize: denormalize,
        normalize: normalize,
    };
})();
