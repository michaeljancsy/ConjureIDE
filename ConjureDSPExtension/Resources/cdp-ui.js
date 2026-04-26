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
     * Inverse of formatValue, used by the click-to-edit value text:
     * parse a user-typed string back into an actual parameter value.
     *
     * Accepts the same SI rollovers `formatValue` produces — "1.5kHz"
     * for an Hz param resolves to 1500; "2 s" for a ms param resolves
     * to 2000 — so the user can copy-edit the displayed text in place
     * without thinking about units.
     *
     * Returns null when the input has no parseable leading number, so
     * the caller can revert to the previous value cleanly. The value
     * is clamped to `meta.min`/`meta.max` and rounded for integer
     * style. Toggle/choice are NOT handled here — they have their
     * own widgets and don't expose the type-in editor.
     */
    function parseUserValue(raw, meta) {
        if (raw == null) return null;
        var s = String(raw).trim();
        if (!s) return null;
        // Leading number: optional sign, digits, optional decimal, optional exponent.
        var m = s.match(/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?/);
        if (!m) return null;
        var num = parseFloat(m[0]);
        if (!isFinite(num)) return null;
        var rest = s.slice(m[0].length).trim().toLowerCase();
        var unit = ((meta && meta.unit) || '').toLowerCase();

        // Unit-prefix scaling — must mirror `formatValue`'s rollovers.
        if (unit === 'hz') {
            if (rest === 'k' || rest.indexOf('khz') === 0) num *= 1000;
        } else if (unit === 'ms') {
            // Match a bare "s" / "sec" / "second(s)" — but NOT "ms" /
            // "msec" (which means milliseconds, no scaling).
            if (rest === 's' || rest === 'sec' || rest === 'second' ||
                rest === 'seconds' || /^s\b/.test(rest)) {
                num *= 1000;
            }
        }
        // Other units: parse as-is. Authors picking exotic units get
        // literal values; that's the safest default.

        if (meta && meta.style === 'integer') num = Math.round(num);

        if (meta && typeof meta.min === 'number') num = Math.max(meta.min, num);
        if (meta && typeof meta.max === 'number') num = Math.min(meta.max, num);
        return num;
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
        '  border-radius: 3px;',
        '  padding: 1px 2px;',
        '  margin: -1px -2px;',
        '}',
        // Hover/focus tint signals the value text is click-editable.
        // Only fires once the editor is installed (cursor: text is set
        // inline by installValueEditor; the rule selector matches
        // either the inline style or the cursor having been applied).
        '.row > [part="value"][tabindex] {',
        '  cursor: text;',
        '}',
        '.row > [part="value"][tabindex]:hover,',
        '.row > [part="value"][tabindex]:focus {',
        '  background: color-mix(in srgb, var(--cdp-fg) 8%, transparent);',
        '  outline: none;',
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

    /// Collapse a string to its alphanumeric-lowercase form. Used to
    /// equate parameter names across variants: Python ships the dict
    /// key literally (`"low_gain"`), Rust's `params!` macro Title-Cases
    /// the ident (`LOW_GAIN` → `"Low Gain"` with a space). All three
    /// collapse to `"lowgain"` and compare equal.
    function normalizeParamName(s) {
        return String(s == null ? '' : s).toLowerCase().replace(/[^a-z0-9]/g, '');
    }

    function resolveParamAttr(attr) {
        if (attr == null || attr === '') return -1;
        var n = Number(attr);
        if (!isNaN(n) && n >= 0 && n < CDP.parameters.count) return n | 0;
        // Exact match first (wins if multiple params normalize to the
        // same thing, which shouldn't happen in practice).
        for (var i = 0; i < CDP.parameters.count; i++) {
            var m = CDP.parameters.metadata(i);
            if (!m) continue;
            if (m.name === attr || m.key === attr) return i;
        }
        // Normalized fallback so the same UI HTML targets both Python
        // (`"low_gain"`) and Rust (`"Low Gain"` from params!() title-
        // casing) variants of a preset.
        var target = normalizeParamName(attr);
        for (var j = 0; j < CDP.parameters.count; j++) {
            var mj = CDP.parameters.metadata(j);
            if (!mj) continue;
            if ((mj.name && normalizeParamName(mj.name) === target) ||
                (mj.key && normalizeParamName(mj.key) === target)) return j;
        }
        return -1;
    }

    // Fire `cb` when CDP has sent `_init`. `ready` is safe to call
    // immediately (synchronously invokes if already ready).
    function whenReady(cb) { CDP.ready(cb); }

    // Apply theme attribute + listen for flips. MUST be called from
    // `connectedCallback`, NEVER from the constructor — per the Custom
    // Elements spec, a constructor may not set attributes on itself,
    // and WebKit silently skips element upgrade (the element stays
    // `HTMLUnknownElement`) if the constructor does so. Idempotent so
    // repeated connectedCallback calls on reinsert don't stack
    // themechange listeners.
    function adoptTheme(host) {
        function apply(t) { host.setAttribute('data-cdp-theme', t || 'light'); }
        apply(CDP.theme);
        if (host.__cdpThemeBound) return;
        host.__cdpThemeBound = true;
        window.addEventListener('themechange', function (e) {
            apply(e && e.detail && e.detail.theme);
        });
    }

    /**
     * Wire up click-to-edit on a `[part="value"]` element. The display
     * span becomes a focusable target; clicking it (or pressing Enter
     * while focused) replaces the formatted text with a transparent
     * `<input>` pre-filled with the raw current value. Enter or blur
     * commits via `parseUserValue`; Escape reverts. Per-component
     * `_render` / `updateUI` paths must check `valueEl.__cdpEditing`
     * and skip the textContent write while the editor is open —
     * otherwise an automation tick or the user's own setValue (which
     * fires onChange synchronously) would clobber the input mid-type.
     *
     * Idempotent: a re-bind on the same element won't double-install
     * listeners. The editor refuses to open for `style: "toggle"` /
     * `style: "choice"` params — those have widgets that already cover
     * "set this exact value" and a text editor would be confusing.
     */
    function installValueEditor(valueEl, getCtrl) {
        if (valueEl.__cdpEditorInstalled) return;
        valueEl.__cdpEditorInstalled = true;
        valueEl.setAttribute('tabindex', '0');
        valueEl.setAttribute('role', 'button');
        valueEl.setAttribute('aria-label', 'Edit value');
        valueEl.style.cursor = 'text';

        function startEdit() {
            if (valueEl.__cdpEditing) return;
            var ctrl = getCtrl();
            if (!ctrl) return;
            var meta = ctrl.metadata || {};
            if (meta.style === 'toggle' || meta.style === 'choice') return;

            valueEl.__cdpEditing = true;
            var v = ctrl.value;
            // Pre-fill with the bare number (no unit text). Easier to
            // overwrite "440" than "440 Hz".
            var raw = (typeof v === 'number')
                ? String(+v.toFixed(4)).replace(/\.?0+$/, '')
                : '';

            var input = document.createElement('input');
            input.type = 'text';
            input.value = raw;
            input.setAttribute('part', 'value-input');
            input.setAttribute('inputmode', 'decimal');
            input.setAttribute('role', 'spinbutton');
            input.setAttribute('aria-label',
                (meta.name ? meta.name + ' value' : 'Param value'));
            if (typeof meta.min === 'number') input.setAttribute('aria-valuemin', String(meta.min));
            if (typeof meta.max === 'number') input.setAttribute('aria-valuemax', String(meta.max));
            if (typeof v === 'number') input.setAttribute('aria-valuenow', String(v));
            // Inherit the host span's typography so the editor visually
            // matches the static display.
            input.style.font = 'inherit';
            input.style.color = 'inherit';
            input.style.textAlign = 'inherit';
            input.style.width = '100%';
            input.style.minWidth = '0';
            input.style.boxSizing = 'border-box';
            input.style.background = 'transparent';
            input.style.border = '1px solid var(--cdp-border)';
            input.style.borderRadius = '4px';
            input.style.padding = '1px 4px';
            input.style.fontVariantNumeric = 'tabular-nums';
            input.style.outline = 'none';

            // Snapshot the current children so we can restore the
            // original (`<slot>` plus any author-supplied content)
            // verbatim on cancel/commit, instead of just a text
            // string that loses the slot wiring.
            var prevChildren = Array.prototype.slice.call(valueEl.childNodes);
            while (valueEl.firstChild) valueEl.removeChild(valueEl.firstChild);
            valueEl.appendChild(input);
            input.focus();
            input.select();

            var done = false;
            function finish(commit) {
                if (done) return;
                done = true;
                valueEl.__cdpEditing = false;
                if (commit) {
                    var n = parseUserValue(input.value, meta);
                    if (n != null && isFinite(n)) ctrl.setValue(n);
                }
                input.remove();
                // Restore the original DOM structure first so the slot
                // wiring is intact, then refresh with the latest value.
                for (var i = 0; i < prevChildren.length; i++) {
                    valueEl.appendChild(prevChildren[i]);
                }
                var latest = ctrl.value;
                // Match the same "don't clobber author slot" rule the
                // components use: if there's a slotted child with
                // assigned nodes, leave it alone.
                var slot = valueEl.querySelector('slot');
                var slotted = slot && slot.assignedNodes
                    && slot.assignedNodes().length > 0;
                if (!slotted) {
                    valueEl.textContent = formatValue(latest, ctrl.metadata);
                }
            }

            input.addEventListener('keydown', function (e) {
                // Don't let arrow-keys / Enter leak to a parent host's
                // keydown handler (cdp-knob steps the value on arrows).
                e.stopPropagation();
                if (e.key === 'Enter') { e.preventDefault(); finish(true); }
                else if (e.key === 'Escape') { e.preventDefault(); finish(false); }
            });
            input.addEventListener('blur', function () { finish(true); });
        }

        valueEl.addEventListener('click', startEdit);
        valueEl.addEventListener('keydown', function (e) {
            if (valueEl.__cdpEditing) return;
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                startEdit();
            }
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
        }

        connectedCallback() {
            adoptTheme(this);
            whenReady(() => this._bind());
        }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }

        _bind() {
            if (this._offChange) { this._offChange(); this._offChange = null; }
            var idx = resolveParamAttr(this.getAttribute('param'));
            if (idx < 0) {
                this._label.textContent = 'unknown';
                this._input.disabled = true;
                return;
            }
            this._input.disabled = false;
            this._ctrl = control(idx);
            var meta = this._ctrl.metadata || {};
            // Always refresh the label. A prior bind when this param
            // wasn't yet in metadata would have set "unknown"; without
            // an unconditional overwrite here, that string sticks
            // forever even after the real param arrives.
            this._label.textContent = meta.name || ('Param ' + idx);
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
                // Don't clobber the type-in editor while the user is
                // mid-edit; commit/cancel paths refresh the text on exit.
                if (this._value.__cdpEditing) return;
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
                if (!this._value.__cdpEditing) {
                    this._value.textContent = formatValue(actual, meta);
                }
            };

            installValueEditor(this._value, () => this._ctrl);
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
        }

        connectedCallback() {
            adoptTheme(this);
            whenReady(() => this._bind());
            // AbortController so disconnectedCallback can clean these up
            // in one line — otherwise each reconnect stacks another pair
            // of listeners on the same `.switch` element.
            this._connectController = new AbortController();
            var sig = this._connectController.signal;
            this._sw.addEventListener('click', () => this._flip(), { signal: sig });
            this._sw.addEventListener('keydown', (e) => {
                if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); this._flip(); }
            }, { signal: sig });
        }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }
        disconnectedCallback() {
            if (this._offChange) this._offChange();
            if (this._connectController) { this._connectController.abort(); this._connectController = null; }
        }

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
            // Unconditional update — mirrors CdpSlider. Guarding on
            // `this._label.textContent.trim()` sticks at 'unknown' on
            // the second bind when metadata finally arrives.
            this._label.textContent = meta.name || ('Param ' + idx);
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
        }

        connectedCallback() {
            adoptTheme(this);
            whenReady(() => this._bind());
        }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }
        disconnectedCallback() { if (this._offChange) this._offChange(); }

        _bind() {
            if (this._offChange) { this._offChange(); this._offChange = null; }
            var idx = resolveParamAttr(this.getAttribute('param'));
            if (idx < 0) { this._label.textContent = 'unknown'; return; }
            this._ctrl = control(idx);
            var meta = this._ctrl.metadata || {};
            var opts = Array.isArray(meta.options) ? meta.options : [];
            // Unconditional update — mirrors CdpSlider. Guarding on
            // trim() meant a first bind at idx<0 stamped 'unknown' and
            // a later re-bind with real metadata couldn't overwrite it.
            this._label.textContent = meta.name || ('Param ' + idx);
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
                b.onclick = () => { this._ctrl.setValue(i); this._render(i); };
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
            sel.onchange = () => {
                var n = Number(sel.value);
                this._ctrl.setValue(n);
                this._render(n);
            };
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
        }

        connectedCallback() {
            adoptTheme(this);
            whenReady(() => this._bind());
            this._connectController = new AbortController();
            var sig = this._connectController.signal;
            this._pad.addEventListener('pointerdown', (e) => this._startDrag(e), { signal: sig });
            this._pad.addEventListener('keydown', (e) => this._onKey(e), { signal: sig });
        }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }
        disconnectedCallback() {
            if (this._offX) this._offX();
            if (this._offY) this._offY();
            if (this._connectController) { this._connectController.abort(); this._connectController = null; }
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
                // The bridge fires onChange synchronously on self-writes,
                // and `_render` is registered as the onChange handler on
                // both controls — so the puck position updates via that
                // path. The explicit call below is redundant but cheap;
                // kept as belt-and-suspenders against a future bridge
                // change that re-introduces the silent-self-write path.
                this._render();
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
            this._render();
        }
    }

    function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

    // ------------------------------------------------------------------
    // <cdp-knob param="…">
    //
    // Circular knob with vertical-drag interaction and full keyboard /
    // wheel / double-click-to-default support. Drop-in replacement for
    // the hand-rolled SVG knobs every audio plugin custom UI ends up
    // reimplementing — and the kind of widget that previously tripped
    // authors on the "set() doesn't fire onChange" bridge quirk before
    // it was lifted. With the bridge now firing onChange synchronously
    // on self-writes, the indicator redraws on the user's drag through
    // the same path it does on DAW automation.
    //
    // Default layout: knob face on top, label, value — the canonical
    // audio-plugin stack. Override via CSS for any other arrangement.
    //
    // Geometric customization. The default visual is a small SVG (rim
    // + face + indicator) themed via CSS custom properties and
    // `::part()` selectors. To ship a totally different visual
    // (vintage tube, hexagon, animated needle), slot in your own SVG
    // and react to the published `--cdp-knob-norm` variable (0..1)
    // entirely in CSS — no JS required:
    //
    //     <cdp-knob param="drive">
    //       <svg slot="visual" viewBox="0 0 100 100">
    //         <use href="#my-tube-body"/>
    //         <line x1="50" y1="50" x2="50" y2="10" stroke="white"
    //               style="transform-origin: 50px 50px;
    //                      transform: rotate(calc(var(--cdp-knob-norm)
    //                                              * 270deg - 135deg))"/>
    //       </svg>
    //     </cdp-knob>
    // ------------------------------------------------------------------

    var KNOB_CSS = [
        ':host {',
        '  --cdp-knob-size: 56px;',
        '  --cdp-knob-sweep: 270deg;',
        '  --cdp-knob-norm: 0;',
        '  --cdp-knob-face-bg: color-mix(in srgb, CanvasText 6%, var(--cdp-bg));',
        '  --cdp-knob-rim-bg: color-mix(in srgb, CanvasText 18%, var(--cdp-bg));',
        '  --cdp-knob-indicator-color: var(--cdp-accent);',
        '  --cdp-knob-indicator-width: 2.5px;',
        '}',
        '.cell {',
        '  display: flex; flex-direction: column;',
        '  align-items: center; gap: 4px;',
        '  user-select: none; -webkit-user-select: none;',
        '}',
        '.visual {',
        '  width: var(--cdp-knob-size);',
        '  height: var(--cdp-knob-size);',
        '  cursor: ns-resize;',
        '  touch-action: none;',
        '  outline: none;',
        '  border-radius: 50%;',
        '}',
        '.visual:focus-visible {',
        '  outline: 3px solid color-mix(in srgb, var(--cdp-accent) 30%, transparent);',
        '  outline-offset: 2px;',
        '}',
        '.visual svg { width: 100%; height: 100%; display: block; }',
        '.default-svg .rim  { fill: var(--cdp-knob-rim-bg); }',
        '.default-svg .face { fill: var(--cdp-knob-face-bg); }',
        '.default-svg .indicator {',
        '  stroke: var(--cdp-knob-indicator-color);',
        '  stroke-width: var(--cdp-knob-indicator-width);',
        '  stroke-linecap: round;',
        '  fill: none;',
        '}',
        '.label {',
        '  font-size: 0.85em; font-weight: 500;',
        '  color: var(--cdp-fg);',
        '  white-space: nowrap; text-align: center;',
        '}',
        '.value {',
        '  font-size: 0.8em; color: var(--cdp-muted);',
        '  font-variant-numeric: tabular-nums;',
        '  white-space: nowrap; text-align: center;',
        '  border-radius: 3px;',
        '  padding: 1px 4px;',
        '  margin: -1px -4px;',
        '}',
        // Hover/focus tint signals the value text is click-editable.
        '.value[tabindex] { cursor: text; }',
        '.value[tabindex]:hover,',
        '.value[tabindex]:focus {',
        '  background: color-mix(in srgb, var(--cdp-fg) 8%, transparent);',
        '  outline: none;',
        '}',
    ].join('\n');

    class CdpKnob extends HTMLElement {
        static get observedAttributes() { return ['param', 'label']; }
        constructor() {
            super();
            var root = this.attachShadow({ mode: 'open' });
            root.append(styleEl(THEME_CSS + '\n' + KNOB_CSS));
            var cell = document.createElement('div');
            cell.className = 'cell';
            cell.setAttribute('part', 'cell');
            // Default visual lives inside <slot name="visual">'s fallback
            // content, so an author providing <svg slot="visual">…</svg>
            // wholesale replaces it. The fallback's SVG is JS-driven via
            // the `transform` attribute on .indicator-group; slotted
            // visuals consume the host CSS variable `--cdp-knob-norm`.
            cell.innerHTML = [
                '<div class="visual" part="visual" tabindex="0" role="slider"',
                '     aria-valuemin="0" aria-valuemax="1" aria-valuenow="0">',
                '  <slot name="visual">',
                '    <svg class="default-svg" viewBox="0 0 64 64" aria-hidden="true">',
                '      <circle class="rim" part="rim" cx="32" cy="32" r="29"/>',
                '      <circle class="face" part="face" cx="32" cy="32" r="24"/>',
                '      <g class="indicator-group">',
                '        <line class="indicator" part="indicator"',
                '              x1="32" y1="14" x2="32" y2="22"/>',
                '      </g>',
                '    </svg>',
                '  </slot>',
                '</div>',
                '<span class="label" part="label"></span>',
                '<span class="value" part="value"></span>',
            ].join('\n');
            root.append(cell);
            this._visual = root.querySelector('.visual');
            this._label = root.querySelector('.label');
            this._value = root.querySelector('.value');
            this._indicatorGroup = root.querySelector('.indicator-group');
        }

        connectedCallback() {
            adoptTheme(this);
            whenReady(() => this._bind());
            this._connectController = new AbortController();
            var sig = this._connectController.signal;
            this._visual.addEventListener('pointerdown', (e) => this._startDrag(e), { signal: sig });
            this._visual.addEventListener('keydown', (e) => this._onKey(e), { signal: sig });
            // `passive: false` so we can preventDefault on wheel — the
            // page scrolling otherwise as the user spins the knob would
            // be incredibly annoying.
            this._visual.addEventListener('wheel', (e) => this._onWheel(e), { signal: sig, passive: false });
            this._visual.addEventListener('dblclick', (e) => this._onDoubleClick(e), { signal: sig });
        }
        attributeChangedCallback() { if (this.isConnected) this._bind(); }
        disconnectedCallback() {
            if (this._offChange) this._offChange();
            if (this._connectController) { this._connectController.abort(); this._connectController = null; }
        }

        _bind() {
            if (this._offChange) { this._offChange(); this._offChange = null; }
            var idx = resolveParamAttr(this.getAttribute('param'));
            if (idx < 0) {
                // Late-binding: the cdp-panel may insert us before the
                // AU parameter tree has been populated. Show a
                // placeholder; we'll re-bind on the next attribute
                // change or via cdp-panel's onAnyChange refresh.
                this._label.textContent = this.getAttribute('label') || 'unknown';
                return;
            }
            this._ctrl = control(idx);
            var meta = this._ctrl.metadata || {};
            // Always overwrite — a stale "unknown" from a prior bind
            // would otherwise stick after the real metadata arrives.
            this._label.textContent = this.getAttribute('label') || meta.name || ('Param ' + idx);
            this._render(this._ctrl.value);
            this._offChange = this._ctrl.onChange((v) => this._render(v));
            installValueEditor(this._value, () => this._ctrl);
        }

        _render(v) {
            if (!this._ctrl) return;
            var t = clamp(normalize(v, this._ctrl.metadata), 0, 1);
            // Publish normalized position as a CSS variable so a
            // slotted custom SVG can drive its own rotation/coloring
            // entirely in CSS via `var(--cdp-knob-norm)`.
            this.style.setProperty('--cdp-knob-norm', String(t));
            // Drive the default visual's rotation via SVG `transform`
            // attribute — most reliable cross-engine. (Slotted visuals
            // use the CSS var above; this only animates the fallback.)
            if (this._indicatorGroup) {
                var sweepDeg = 270;  // matches default --cdp-knob-sweep
                var angle = t * sweepDeg - sweepDeg / 2;
                this._indicatorGroup.setAttribute('transform', 'rotate(' + angle + ' 32 32)');
            }
            this._visual.setAttribute('aria-valuenow', t.toFixed(3));
            // Don't overwrite the type-in editor mid-edit. The commit/
            // cancel path refreshes the text from the latest value.
            if (!this._value.__cdpEditing) {
                this._value.textContent = formatValue(v, this._ctrl.metadata);
            }
        }

        _startDrag(e) {
            if (!this._ctrl) return;
            e.preventDefault();
            try { this._visual.setPointerCapture(e.pointerId); } catch (_) {}
            this._visual.focus();
            var startY = e.clientY;
            var startT = clamp(normalize(this._ctrl.value, this._ctrl.metadata), 0, 1);
            var meta = this._ctrl.metadata;
            // 200px to span 0..1 by default. Shift = fine (5x slower).
            // Read `shiftKey` on the move event, not pointerdown, so the
            // user can press/release Shift mid-drag and feel the change.
            var move = (ev) => {
                var pixelsPerUnit = ev.shiftKey ? 1000 : 200;
                var dy = startY - ev.clientY;  // up = positive value
                var t = clamp(startT + dy / pixelsPerUnit, 0, 1);
                var actual = denormalize(t, meta);
                this._ctrl.setValue(actual);
                // The bridge fires onChange synchronously on self-writes
                // (CustomUIBridgeOnChangeTests pins this), so _render
                // would already run via the onChange handler. The
                // explicit call below is redundant but cheap — kept as
                // belt-and-suspenders against a future bridge change
                // that re-introduces the silent-self-write path, and to
                // keep the integration-test harness's stub bridge
                // happy (it doesn't mirror the synchronous fire).
                this._render(actual);
            };
            var up = (ev) => {
                try { this._visual.releasePointerCapture(ev.pointerId); } catch (_) {}
                this._visual.removeEventListener('pointermove', move);
                this._visual.removeEventListener('pointerup', up);
                this._visual.removeEventListener('pointercancel', up);
            };
            this._visual.addEventListener('pointermove', move);
            this._visual.addEventListener('pointerup', up);
            this._visual.addEventListener('pointercancel', up);
        }

        _onKey(e) {
            if (!this._ctrl) return;
            var meta = this._ctrl.metadata;
            var t = clamp(normalize(this._ctrl.value, meta), 0, 1);
            var fine = e.shiftKey ? 0.01 : 0.05;
            var page = 0.2;
            var nt;
            switch (e.key) {
                case 'ArrowUp':   case 'ArrowRight': nt = clamp(t + fine, 0, 1); break;
                case 'ArrowDown': case 'ArrowLeft':  nt = clamp(t - fine, 0, 1); break;
                case 'PageUp':    nt = clamp(t + page, 0, 1); break;
                case 'PageDown':  nt = clamp(t - page, 0, 1); break;
                case 'Home':      nt = 0; break;
                case 'End':       nt = 1; break;
                default: return;
            }
            e.preventDefault();
            var actual = denormalize(nt, meta);
            this._ctrl.setValue(actual);
            this._render(actual);  // see note in _startDrag.move
        }

        _onWheel(e) {
            if (!this._ctrl) return;
            e.preventDefault();
            var meta = this._ctrl.metadata;
            var t = clamp(normalize(this._ctrl.value, meta), 0, 1);
            // Scroll up to turn up. macOS natural scroll inverts deltaY
            // already; this matches the "wheel up to increase" mental
            // model people have for knobs.
            var step = e.shiftKey ? 0.001 : 0.01;
            var nt = clamp(t - Math.sign(e.deltaY) * step, 0, 1);
            var actual = denormalize(nt, meta);
            this._ctrl.setValue(actual);
            this._render(actual);
        }

        _onDoubleClick(e) {
            if (!this._ctrl) return;
            e.preventDefault();
            var meta = this._ctrl.metadata;
            if (meta && typeof meta.default === 'number') {
                this._ctrl.setValue(meta.default);
                this._render(meta.default);
            }
        }
    }

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
        }
        connectedCallback() {
            adoptTheme(this);
            whenReady(() => this._render());
        }

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
    define('cdp-knob', CdpKnob);
    define('cdp-panel', CdpPanel);

    CDP.ui = {
        version: VERSION,
        requireVersion: requireVersion,
        control: control,
        formatValue: formatValue,
        /// Inverse of formatValue: parse a user-typed string back to a
        /// numeric value, honoring the param's unit prefixes (kHz/Hz,
        /// s/ms) and clamping to min/max. Returns null when the input
        /// has no leading number. Used internally by the click-to-edit
        /// value text on cdp-slider / cdp-knob; exposed for authored
        /// UIs that render their own value displays.
        parseUserValue: parseUserValue,
        denormalize: denormalize,
        normalize: normalize,
        /// Resolve a `param="…"` attribute value to an index. Accepts
        /// numeric strings (`"0"`), exact names (`"cutoff"`), and
        /// normalized names (underscores, spaces, and case all ignored,
        /// so `"Low Gain"`, `"LOW_GAIN"`, `"low_gain"`, and
        /// `"low gain"` all resolve to the same parameter). Returns
        /// -1 when no match is found. Exposed for authored UIs that
        /// want the same lookup rules the library uses internally.
        findParam: resolveParamAttr,
        /// The canonicalization used by `findParam`. Useful for tests
        /// and for authors doing their own name comparisons.
        normalizeParamName: normalizeParamName,
    };
})();
