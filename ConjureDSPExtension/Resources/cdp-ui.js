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
 *   ConjureDSP.ui.control(indexOrName)    // primitive: { value, setValue(v),
 *                                         //             metadata, onChange(cb),
 *                                         //             normalize(v), denormalize(t) }
 *                                         // Accepts a numeric index or a
 *                                         // param name (case/underscore/space
 *                                         // insensitive — same loose match
 *                                         // as `<cdp-slider param="...">`).
 *                                         // Returns null if the name doesn't
 *                                         // resolve, with a warning logged
 *                                         // via `ConjureDSP.log` so authors
 *                                         // can see the typo in Console.app.
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
     * Wrap a parameter in an observable control object. Reads actual
     * (denormalized) values from the bridge; writes pass through to
     * `CDP.parameters.set`, which routes to the AU parameter tree.
     *
     * Accepts either a numeric index (`control(0)`) or a param name
     * string (`control('Drive')`). Name lookup is case/underscore/
     * space insensitive — the same loose match `<cdp-slider
     * param="...">` uses. Returns `null` when a name doesn't resolve,
     * with a warning logged via the bridge so the typo shows up in
     * Console.app instead of appearing as a silently-frozen widget.
     */
    function control(indexOrName) {
        var index = (typeof indexOrName === 'string')
            ? resolveParamAttr(indexOrName)
            : indexOrName;
        if (typeof index !== 'number' || index < 0) {
            try {
                if (window.ConjureDSP && typeof window.ConjureDSP.log === 'function') {
                    window.ConjureDSP.log('[cdp-ui.control] unknown param: ' + JSON.stringify(indexOrName));
                }
            } catch (_) {}
            return null;
        }
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

    /// Resolve a telemetry slot name (as written in an HTML attribute)
    /// to whatever key the live frame actually uses, applying the same
    /// case/underscore/space-insensitive rules `resolveParamAttr` uses
    /// for params. Returns the key string from `frame.telemetry`, or
    /// `null` if no slot matches. Lets `<cdp-scope telemetry="env_curve">`
    /// bind to a Rust preset publishing `ENV_CURVE` and a Python preset
    /// publishing `env_curve` from the same UI source.
    function resolveTelemetryKey(frame, attr) {
        if (!frame || !frame.telemetry || attr == null || attr === '') return null;
        if (Object.prototype.hasOwnProperty.call(frame.telemetry, attr)) return attr;
        var target = normalizeParamName(attr);
        var keys = Object.keys(frame.telemetry);
        for (var i = 0; i < keys.length; i++) {
            if (normalizeParamName(keys[i]) === target) return keys[i];
        }
        return null;
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
    // <cdp-meter> — read-only audio level meter.
    //
    // Subscribes to `ConjureDSP.audio.onFrame` and renders a bar with
    // PPM ballistics, peak-hold marker, and three-zone coloring. Click
    // anywhere on the meter to reset the peak-hold marker.
    //
    // Source modes:
    //   peak-in | peak-out | rms-in | rms-out — linear scalars from the
    //   default frame payload; converted to dB unless `unit="db"`.
    //   telemetry:<key> — reads `frame.telemetry?.[key]`; defaults to
    //   `unit="db"` (telemetry channels typically publish dB already,
    //   per the Rust/Python author surface in the docs).
    // ------------------------------------------------------------------

    var METER_CSS = [
        ':host {',
        '  --cdp-meter-green: oklch(0.65 0.15 145);',
        '  --cdp-meter-yellow: oklch(0.78 0.15 90);',
        '  --cdp-meter-red: oklch(0.55 0.20 25);',
        '  --cdp-meter-track-bg: var(--cdp-track-bg);',
        '  --cdp-meter-peak-color: var(--cdp-fg);',
        '  --cdp-meter-thickness: 12px;',
        '  --cdp-meter-length: 120px;',
        '  display: inline-flex;',
        '}',
        '.container {',
        '  display: flex;',
        '  flex-direction: column;',
        '  align-items: center;',
        '  gap: 4px;',
        '  cursor: pointer;',
        '}',
        ':host([orientation="horizontal"]) .container {',
        '  flex-direction: row;',
        '}',
        '[part="label"] {',
        '  font-weight: 500;',
        '  color: var(--cdp-muted);',
        '  font-size: calc(var(--cdp-font-size) - 1px);',
        '  white-space: nowrap;',
        '}',
        '.track {',
        '  position: relative;',
        '  background: var(--cdp-meter-track-bg);',
        '  border-radius: var(--cdp-radius);',
        '  overflow: hidden;',
        '  width: var(--cdp-meter-thickness);',
        '  height: var(--cdp-meter-length);',
        '}',
        ':host([orientation="horizontal"]) .track {',
        '  width: var(--cdp-meter-length);',
        '  height: var(--cdp-meter-thickness);',
        '}',
        '.bar {',
        '  position: absolute;',
        '  inset: 0;',
        '  /* `--cdp-meter-gradient` is the public escape hatch — set it',
        '     externally to supply an arbitrary linear-gradient(...). The',
        '     internal `--_cdp-meter-bar-bg` is what JS computes from the',
        '     attribute set (warn/clip/invert/gradient="smooth"). */',
        '  background: var(--cdp-meter-gradient, var(--_cdp-meter-bar-bg));',
        '  /* clip-path is set inline by the frame tick. */',
        '  clip-path: inset(100% 0 0 0);',
        '}',
        '.peak-hold {',
        '  position: absolute;',
        '  background: var(--cdp-meter-peak-color);',
        '  pointer-events: none;',
        '}',
        ':host(:not([orientation="horizontal"])) .peak-hold {',
        '  left: 0; right: 0;',
        '  height: 2px;',
        '}',
        ':host([orientation="horizontal"]) .peak-hold {',
        '  top: 0; bottom: 0;',
        '  width: 2px;',
        '}',
    ].join('\n');

    /// Linear → dB with a noise floor (avoid log10(0) = -Infinity).
    function linToDb(v) {
        var a = Math.abs(Number(v) || 0);
        if (a < 1e-9) a = 1e-9;
        return 20 * Math.log10(a);
    }

    class CdpMeter extends HTMLElement {
        static get observedAttributes() {
            return ['source', 'unit', 'orientation',
                    'min', 'max', 'warn', 'clip',
                    'hold', 'decay', 'integration',
                    'invert', 'gradient'];
        }

        constructor() {
            super();
            var root = this.attachShadow({ mode: 'open' });
            root.append(styleEl(THEME_CSS + '\n' + METER_CSS));
            root.innerHTML += [
                '<div class="container" part="container">',
                '  <span part="label"><slot name="label"></slot></span>',
                '  <div class="track" part="track">',
                '    <div class="bar" part="bar"></div>',
                '    <div class="peak-hold" part="peak-hold"></div>',
                '  </div>',
                '</div>',
            ].join('\n');
            this._container = root.querySelector('.container');
            this._track = root.querySelector('.track');
            this._bar = root.querySelector('.bar');
            this._peak = root.querySelector('.peak-hold');

            // Ballistic state. Initialized from `min` on first connect.
            this._latestRaw = 0;
            this._haveFrame = false;
            this._smoothed = null;
            this._displayDb = -Infinity;
            this._peakDb = -Infinity;
            this._peakAt = 0;

            // Bound callback so add/remove pair use the same reference.
            this._onFrame = this._onFrame.bind(this);
        }

        connectedCallback() {
            adoptTheme(this);
            this._displayDb = this._readMin();
            this._peakDb = this._displayDb;
            this._peakAt = (typeof performance !== 'undefined' ? performance.now() : Date.now());
            this._lastTick = this._peakAt;
            this._applyGradient();
            this._renderBars();

            this._connectController = new AbortController();
            var sig = this._connectController.signal;
            this._container.addEventListener('click', () => this._resetPeak(), { signal: sig });

            // Ticks are driven by audio-frame arrival, not rAF.
            // Rationale:
            //  1. Frames arrive at the manifest's `fps` (~30 Hz default)
            //     which is plenty for visual smoothness.
            //  2. Ballistics tied to DSP time (frame arrival) are
            //     semantically correct — when the host pauses the audio
            //     engine, the meter should freeze in place rather than
            //     keep decaying against wall-clock time.
            //  3. rAF doesn't fire when the page is in a hidden tab /
            //     headless preview, but `onFrame` keeps flowing as long
            //     as the audio engine is running.
            if (CDP.audio && typeof CDP.audio.onFrame === 'function') {
                CDP.audio.onFrame(this._onFrame);
            }
        }

        disconnectedCallback() {
            if (CDP.audio && typeof CDP.audio.offFrame === 'function') {
                CDP.audio.offFrame(this._onFrame);
            }
            if (this._connectController) {
                this._connectController.abort();
                this._connectController = null;
            }
        }

        attributeChangedCallback(name) {
            if (!this.isConnected) return;
            if (name === 'min' || name === 'max' ||
                name === 'warn' || name === 'clip' ||
                name === 'orientation' ||
                name === 'invert' || name === 'gradient') {
                this._applyGradient();
                this._renderBars();
            }
        }

        // --- attribute readers (with defaults) ---
        _readMin()    { var n = parseFloat(this.getAttribute('min'));    return isNaN(n) ? -60   : n; }
        _readMax()    { var n = parseFloat(this.getAttribute('max'));    return isNaN(n) ?   0   : n; }
        _readWarn()   { var n = parseFloat(this.getAttribute('warn'));   return isNaN(n) ? -18   : n; }
        _readClip()   { var n = parseFloat(this.getAttribute('clip'));   return isNaN(n) ?  -6   : n; }
        _readDecay()  { var n = parseFloat(this.getAttribute('decay'));  return isNaN(n) ? 11.76 : n; }
        _readIntegration() { var n = parseFloat(this.getAttribute('integration')); return isNaN(n) ? 0 : n; }
        _readHold() {
            var s = this.getAttribute('hold');
            if (s === 'infinite') return Infinity;
            var n = parseFloat(s);
            if (isNaN(n)) return 2000;
            return n;
        }
        _readUnit() {
            var u = this.getAttribute('unit');
            if (u === 'db' || u === 'linear') return u;
            // Default: telemetry → db (slot values are typically dB
            // already, e.g. gain reduction); peak/rms → linear.
            var src = this.getAttribute('source') || 'peak-out';
            return (src.indexOf('telemetry:') === 0) ? 'db' : 'linear';
        }
        _readOrientation() {
            return this.getAttribute('orientation') === 'horizontal' ? 'horizontal' : 'vertical';
        }
        _isInverted() { return this.hasAttribute('invert'); }
        _readGradientStyle() {
            return this.getAttribute('gradient') === 'smooth' ? 'smooth' : 'zones';
        }

        _applyGradient() {
            var min = this._readMin();
            var max = this._readMax();
            var warn = this._readWarn();
            var clip = this._readClip();
            var span = max - min;
            if (span <= 0) span = 1;
            var inverted = this._isInverted();
            var horizontal = this._readOrientation() === 'horizontal';
            // The gradient runs from the "safe" end (0%) toward the
            // "danger" end (100%). For default meters, safe = min (low
            // values are safe, e.g. -60 dBFS); for inverted meters,
            // safe = max (e.g. 0 dB GR = no reduction = safe).
            var safeVal = inverted ? max : min;
            var dangerVal = inverted ? min : max;
            // (warn - safeVal) / (dangerVal - safeVal). The denominator
            // flips sign when inverted, which cancels out the flipped
            // numerator, so warnPct lands in [0, 1] for sensible inputs.
            var safeSpan = dangerVal - safeVal;
            var warnPct = Math.max(0, Math.min(1, (warn - safeVal) / safeSpan)) * 100;
            var clipPct = Math.max(0, Math.min(1, (clip - safeVal) / safeSpan)) * 100;
            // CSS gradient direction always points from safe → danger:
            //   default vertical: bottom (safe=min) → top (danger=max)
            //   inverted vertical: top (safe=max) → bottom (danger=min)
            var dir;
            if (horizontal) dir = inverted ? 'to left' : 'to right';
            else dir = inverted ? 'to bottom' : 'to top';
            var stops;
            if (this._readGradientStyle() === 'smooth') {
                // Smooth: blends green → yellow → red continuously, with
                // anchors at 0%/warn/clip/100%.
                stops = [
                    'var(--cdp-meter-green) 0%',
                    'var(--cdp-meter-yellow) ' + warnPct + '%',
                    'var(--cdp-meter-red) ' + clipPct + '%',
                    'var(--cdp-meter-red) 100%',
                ];
            } else {
                // Zones: hard edges at warn/clip — the pro-meter default.
                stops = [
                    'var(--cdp-meter-green) 0%',
                    'var(--cdp-meter-green) ' + warnPct + '%',
                    'var(--cdp-meter-yellow) ' + warnPct + '%',
                    'var(--cdp-meter-yellow) ' + clipPct + '%',
                    'var(--cdp-meter-red) ' + clipPct + '%',
                    'var(--cdp-meter-red) 100%',
                ];
            }
            // Write to the internal CSS var so external `--cdp-meter-gradient`
            // can override via the cascade defined in METER_CSS.
            this._bar.style.setProperty('--_cdp-meter-bar-bg',
                'linear-gradient(' + dir + ', ' + stops.join(', ') + ')');
        }

        _onFrame(frame) {
            if (!frame) return;
            var src = this.getAttribute('source') || 'peak-out';
            var raw;
            if (src.indexOf('telemetry:') === 0) {
                var key = src.substring('telemetry:'.length);
                raw = frame.telemetry ? frame.telemetry[key] : undefined;
            } else {
                switch (src) {
                    case 'peak-in':  raw = frame.peakIn;  break;
                    case 'rms-in':   raw = frame.rmsIn;   break;
                    case 'rms-out':  raw = frame.rmsOut;  break;
                    case 'peak-out': /* fallthrough */
                    default:         raw = frame.peakOut; break;
                }
            }
            if (typeof raw !== 'number' || !isFinite(raw)) raw = 0;
            this._latestRaw = raw;
            this._haveFrame = true;
            // Ballistics + render advance on each frame. See
            // connectedCallback for why we don't use rAF.
            this._tick(typeof performance !== 'undefined' ? performance.now() : Date.now());
        }

        _tick(now) {
            var dt = (now - this._lastTick) / 1000;
            if (dt < 0) dt = 0;
            if (dt > 0.5) dt = 0.5; // tab unfocus / first tick
            this._lastTick = now;

            var unit = this._readUnit();
            var raw = this._latestRaw;

            // Optional integration smoothing on the raw scalar (in its
            // native unit). One-pole IIR keyed off integration ms.
            var integrationMs = this._readIntegration();
            if (integrationMs > 0) {
                var coeff = 1 - Math.exp(-dt * 1000 / integrationMs);
                if (this._smoothed === null) this._smoothed = raw;
                this._smoothed += coeff * (raw - this._smoothed);
                raw = this._smoothed;
            } else {
                this._smoothed = null;
            }

            var dB = (unit === 'db') ? Number(raw) : linToDb(raw);
            if (!isFinite(dB)) dB = -Infinity;

            var min = this._readMin();
            var max = this._readMax();
            var clamped = Math.max(min, Math.min(max, dB));

            // PPM-style fall: rise instantaneously, fall at `decay` dB/s.
            var decay = this._readDecay();
            var fallen = this._displayDb - dt * decay;
            if (fallen < min) fallen = min;
            this._displayDb = Math.max(clamped, fallen);

            // Peak hold: latch to display peak; release after `hold` ms.
            var holdMs = this._readHold();
            if (this._displayDb >= this._peakDb || (now - this._peakAt) >= holdMs) {
                this._peakDb = this._displayDb;
                this._peakAt = now;
            }

            this._renderBars();
        }

        _renderBars() {
            var min = this._readMin();
            var max = this._readMax();
            var span = max - min;
            if (span <= 0) span = 1;
            var inverted = this._isInverted();
            // pct = "fill amount" along the gradient (0 = safe end empty,
            // 1 = danger end full). For invert this flips so heavy
            // reduction (low value) yields a full bar.
            var pct, peakPct;
            if (inverted) {
                pct     = Math.max(0, Math.min(1, (max - this._displayDb) / span));
                peakPct = Math.max(0, Math.min(1, (max - this._peakDb)    / span));
            } else {
                pct     = Math.max(0, Math.min(1, (this._displayDb - min) / span));
                peakPct = Math.max(0, Math.min(1, (this._peakDb    - min) / span));
            }
            var horizontal = this._readOrientation() === 'horizontal';
            // Reset all four edges so a previous orientation/invert state
            // doesn't leak across an attribute change.
            this._peak.style.top = '';
            this._peak.style.bottom = '';
            this._peak.style.left = '';
            this._peak.style.right = '';
            // clipPath reveals the filled portion; the bar grows from the
            // "safe" edge toward the "danger" edge:
            //   default vertical:   grows up   → reveal bottom (clip top)
            //   inverted vertical:  grows down → reveal top    (clip bottom)
            //   default horizontal: grows right → reveal left  (clip right)
            //   inverted horizontal: grows left → reveal right (clip left)
            // Peak marker sits at the leading edge of the fill.
            var emptyPct = (1 - pct) * 100;
            var peakPos = (peakPct * 100) + '%';
            if (horizontal) {
                if (inverted) {
                    this._bar.style.clipPath = 'inset(0 0 0 ' + emptyPct + '%)';
                    this._peak.style.right = peakPos;
                } else {
                    this._bar.style.clipPath = 'inset(0 ' + emptyPct + '% 0 0)';
                    this._peak.style.left = peakPos;
                }
            } else {
                if (inverted) {
                    this._bar.style.clipPath = 'inset(0 0 ' + emptyPct + '% 0)';
                    this._peak.style.top = peakPos;
                } else {
                    this._bar.style.clipPath = 'inset(' + emptyPct + '% 0 0 0)';
                    this._peak.style.bottom = peakPos;
                }
            }
        }

        _resetPeak() {
            this._peakDb = isFinite(this._displayDb) ? this._displayDb : this._readMin();
            this._peakAt = (typeof performance !== 'undefined' ? performance.now() : Date.now());
            this._renderBars();
        }
    }

    // ------------------------------------------------------------------
    // <cdp-scope telemetry="…"> — draws a vector telemetry slot as a
    // waveform. Subscribes to audio.onFrame, slices `length` elements
    // (or the full vector), auto-ranges Y unless `min`/`max` pin it,
    // decimates to one min+max pair per pixel column when oversampled,
    // and draws as line / filled / dots per `draw=`.
    //
    // Out of scope (v1): scrolling history, dual-channel overlay,
    // frequency-domain mode, trigger modes. Add when real preset usage
    // points at the gap.
    // ------------------------------------------------------------------
    var SCOPE_CSS = [
        ':host {',
        '  display: block;',
        '  position: relative;',
        '  width: 100%;',
        '  min-height: 60px;',
        '  --cdp-scope-line-color: var(--cdp-accent);',
        '  --cdp-scope-fill-color: color-mix(in srgb, var(--cdp-accent) 20%, transparent);',
        '  --cdp-scope-grid-color: color-mix(in srgb, var(--cdp-fg) 12%, transparent);',
        '  --cdp-scope-bg: transparent;',
        '}',
        'canvas {',
        '  display: block;',
        '  width: 100%;',
        '  height: 100%;',
        '  background: var(--cdp-scope-bg);',
        '}',
    ].join('\n');

    class CdpScope extends HTMLElement {
        static get observedAttributes() {
            return ['telemetry', 'length', 'min', 'max', 'draw', 'grid'];
        }

        constructor() {
            super();
            var root = this.attachShadow({ mode: 'open' });
            root.append(styleEl(THEME_CSS + '\n' + SCOPE_CSS));
            this._canvas = document.createElement('canvas');
            this._canvas.setAttribute('part', 'canvas');
            root.append(this._canvas);
            this._ctx = this._canvas.getContext('2d');

            this._onFrame = this._onFrame.bind(this);

            // Resolved key cache. Cleared on attr change or when a frame
            // arrives where the cached key no longer exists.
            this._resolvedKey = null;

            // Latest vector slice received (Array<number> | Float32Array
            // | null). Stored so a resize redraws the last data without
            // waiting for the next audio frame.
            this._lastSlice = null;

            // Auto-range trackers. null until first frame.
            this._rangeMin = null;
            this._rangeMax = null;
            this._lastRangeTick = 0;
        }

        connectedCallback() {
            adoptTheme(this);
            this._resize();
            this._render();

            this._resizeObserver = new ResizeObserver(() => {
                this._resize();
                this._render();
            });
            this._resizeObserver.observe(this);

            if (CDP.audio && typeof CDP.audio.onFrame === 'function') {
                CDP.audio.onFrame(this._onFrame);
            }
        }

        disconnectedCallback() {
            if (CDP.audio && typeof CDP.audio.offFrame === 'function') {
                CDP.audio.offFrame(this._onFrame);
            }
            if (this._resizeObserver) {
                this._resizeObserver.disconnect();
                this._resizeObserver = null;
            }
        }

        attributeChangedCallback(name) {
            if (!this.isConnected) return;
            if (name === 'telemetry') {
                this._resolvedKey = null;
                this._lastSlice = null;
            }
            // Reset auto-range so a min/max attribute flip doesn't leave
            // stale tracker state from the prior mode.
            if (name === 'min' || name === 'max') {
                this._rangeMin = null;
                this._rangeMax = null;
            }
            this._render();
        }

        _resize() {
            var dpr = window.devicePixelRatio || 1;
            var w = Math.max(1, Math.floor(this.clientWidth));
            var h = Math.max(1, Math.floor(this.clientHeight));
            // Avoid the silent-clear that comes from re-assigning width/
            // height to the same value.
            var pw = Math.max(1, Math.floor(w * dpr));
            var ph = Math.max(1, Math.floor(h * dpr));
            if (this._canvas.width !== pw) this._canvas.width = pw;
            if (this._canvas.height !== ph) this._canvas.height = ph;
        }

        _onFrame(frame) {
            if (!frame) return;
            var attr = this.getAttribute('telemetry');
            if (!attr) return;
            // Re-resolve when cache miss or when the cached key has
            // disappeared (preset swap mid-session).
            var key = this._resolvedKey;
            if (key == null ||
                !frame.telemetry ||
                !Object.prototype.hasOwnProperty.call(frame.telemetry, key)) {
                key = resolveTelemetryKey(frame, attr);
                this._resolvedKey = key;
            }
            if (key == null) return;
            var v = frame.telemetry[key];
            // Bail on scalars (slot is declared scalar shape) or anything
            // else that's not array-like. The component only draws vectors.
            if (v == null || typeof v === 'number' ||
                typeof v.length !== 'number' || v.length === 0) {
                return;
            }
            this._lastSlice = v;
            // Only audio-driven render ticks should advance the
            // 1-second decay clock. ResizeObserver and attribute
            // changes also call _render, but advancing the clock
            // there would shrink the next audio tick's dt and
            // visibly stall the auto-range decay for a frame.
            this._advanceRangeDecay = true;
            this._render();
            this._advanceRangeDecay = false;
        }

        // --- attribute readers ---
        _readLength() {
            var n = parseInt(this.getAttribute('length'), 10);
            return (isFinite(n) && n > 0) ? n : null;
        }
        _readAttrFloat(name) {
            var raw = this.getAttribute(name);
            if (raw == null || raw === '') return null;
            var n = parseFloat(raw);
            return isFinite(n) ? n : null;
        }
        _readDraw() {
            var d = this.getAttribute('draw');
            return (d === 'filled' || d === 'dots') ? d : 'line';
        }
        _readGrid() { return this.hasAttribute('grid'); }

        _computeRange(slice, sliceLen) {
            var attrMin = this._readAttrFloat('min');
            var attrMax = this._readAttrFloat('max');

            // Both fixed: hard pin, no tracker.
            if (attrMin != null && attrMax != null) {
                return { min: attrMin, max: attrMax };
            }

            // Compute slice min/max once.
            var sMin = Infinity, sMax = -Infinity;
            for (var i = 0; i < sliceLen; i++) {
                var x = slice[i];
                if (x < sMin) sMin = x;
                if (x > sMax) sMax = x;
            }
            if (!isFinite(sMin) || !isFinite(sMax)) {
                return { min: attrMin != null ? attrMin : -1,
                         max: attrMax != null ? attrMax :  1 };
            }

            var advance = !!this._advanceRangeDecay;
            var alpha = 0;
            if (advance) {
                var now = (typeof performance !== 'undefined' ? performance.now() : Date.now());
                var dt = this._lastRangeTick > 0 ? (now - this._lastRangeTick) / 1000 : 0;
                this._lastRangeTick = now;
                // 1-second time constant. Larger = slower decay =
                // peaks hold longer; chosen so a single transient
                // stays visible ~1 s before the tracker walks back in.
                alpha = 1 - Math.exp(-Math.min(0.5, Math.max(0, dt)) / 1.0);
            }

            // Initialize trackers on first frame in this mode.
            if (this._rangeMin == null) this._rangeMin = sMin;
            if (this._rangeMax == null) this._rangeMax = sMax;

            // Snap outward immediately, decay inward over ~1 s on
            // audio ticks only (alpha=0 on resize/attr renders).
            var span = Math.max(1e-9, this._rangeMax - this._rangeMin);
            this._rangeMin = Math.min(sMin, this._rangeMin + span * alpha);
            this._rangeMax = Math.max(sMax, this._rangeMax - span * alpha);

            // Guarantee a non-zero span so the y-mapper doesn't divide
            // by zero on a flat-line vector.
            if (this._rangeMax - this._rangeMin < 1e-9) {
                var mid = (this._rangeMax + this._rangeMin) * 0.5;
                this._rangeMin = mid - 0.5;
                this._rangeMax = mid + 0.5;
            }

            return {
                min: attrMin != null ? attrMin : this._rangeMin,
                max: attrMax != null ? attrMax : this._rangeMax,
            };
        }

        _render() {
            var ctx = this._ctx;
            if (!ctx) return;
            var W = this._canvas.width;
            var H = this._canvas.height;
            ctx.clearRect(0, 0, W, H);

            // Read computed CSS to pick up theme + author overrides.
            // Canvas 2D parses `currentColor` (and `color-mix(... currentColor ...)`
            // expressions containing it) as opaque black, since the canvas
            // context has no host element to resolve `currentColor` against.
            // On a dark theme that makes the trace invisible. Substitute
            // the literal token with the host element's resolved `color`
            // (a real rgb(...) string) before feeding the value to canvas.
            var cs = window.getComputedStyle(this);
            var hostColor = cs.color;
            function resolveCanvasColor(varName, fallback) {
                var v = cs.getPropertyValue(varName).trim();
                if (!v) return fallback;
                if (v.indexOf('currentColor') >= 0) {
                    v = v.replace(/currentColor/g, hostColor);
                }
                return v;
            }
            var lineColor = resolveCanvasColor('--cdp-scope-line-color', hostColor);
            var fillColor = resolveCanvasColor('--cdp-scope-fill-color', lineColor);
            var gridColor = resolveCanvasColor('--cdp-scope-grid-color', 'transparent');

            if (this._readGrid()) this._drawGrid(ctx, W, H, gridColor);

            var slice = this._lastSlice;
            if (!slice || slice.length === 0) return;

            var lenAttr = this._readLength();
            var sliceLen = lenAttr != null ? Math.min(lenAttr, slice.length) : slice.length;

            var range = this._computeRange(slice, sliceLen);
            var rmin = range.min, rmax = range.max;
            var span = rmax - rmin;
            if (span <= 0) span = 1;

            // y-mapper: data value -> canvas pixel (top is 0, bottom is H).
            function mapY(v) {
                var t = (v - rmin) / span;
                if (t < 0) t = 0;
                if (t > 1) t = 1;
                return (1 - t) * H;
            }

            var draw = this._readDraw();
            var dpr = window.devicePixelRatio || 1;
            ctx.lineWidth = Math.max(1, Math.round(1.5 * dpr));
            ctx.strokeStyle = lineColor;
            ctx.fillStyle = fillColor;

            if (sliceLen > W * 2) {
                this._drawDecimated(ctx, slice, sliceLen, W, H, mapY, draw);
            } else {
                this._drawDirect(ctx, slice, sliceLen, W, mapY, draw, rmin);
            }
        }

        _drawGrid(ctx, W, H, color) {
            ctx.save();
            ctx.strokeStyle = color;
            ctx.lineWidth = 1;
            ctx.beginPath();
            // 4 horizontal + 4 vertical interior lines (5x5 grid cells).
            for (var i = 1; i < 5; i++) {
                var y = Math.round((i / 5) * H) + 0.5;
                ctx.moveTo(0, y); ctx.lineTo(W, y);
                var x = Math.round((i / 5) * W) + 0.5;
                ctx.moveTo(x, 0); ctx.lineTo(x, H);
            }
            ctx.stroke();
            ctx.restore();
        }

        // Direct polyline path — one vertex per slice element.
        _drawDirect(ctx, slice, sliceLen, W, mapY, draw, rmin) {
            if (sliceLen < 1) return;
            // Single-element vectors get centered (stepX would be 0
            // and the lone point would otherwise pin to x=0).
            var single = sliceLen === 1;
            var stepX = single ? 0 : W / (sliceLen - 1);
            var x0 = single ? W / 2 : 0;

            if (draw === 'dots') {
                ctx.beginPath();
                var r = Math.max(1, ctx.lineWidth);
                for (var i = 0; i < sliceLen; i++) {
                    var x = x0 + i * stepX;
                    var y = mapY(slice[i]);
                    ctx.moveTo(x + r, y);
                    ctx.arc(x, y, r, 0, Math.PI * 2);
                }
                ctx.fill();
                return;
            }

            ctx.beginPath();
            for (var j = 0; j < sliceLen; j++) {
                var px = x0 + j * stepX;
                var py = mapY(slice[j]);
                if (j === 0) ctx.moveTo(px, py);
                else ctx.lineTo(px, py);
            }
            if (draw === 'filled') {
                // Close to the baseline (rmin) at the right then left edge.
                ctx.lineTo(x0 + (sliceLen - 1) * stepX, mapY(rmin));
                ctx.lineTo(x0, mapY(rmin));
                ctx.closePath();
                ctx.fill();
                ctx.beginPath();
                for (var k = 0; k < sliceLen; k++) {
                    var qx = x0 + k * stepX;
                    var qy = mapY(slice[k]);
                    if (k === 0) ctx.moveTo(qx, qy);
                    else ctx.lineTo(qx, qy);
                }
                ctx.stroke();
            } else {
                ctx.stroke();
            }
        }

        // Decimated min+max-per-column path — for sliceLen >> W.
        _drawDecimated(ctx, slice, sliceLen, W, H, mapY, draw) {
            // For each pixel column, find min and max of the slice region
            // mapped to that column. Draw a vertical segment between them.
            // This is the standard waveform-thumbnail technique — cheap
            // and visually correct (no aliasing-induced gaps that simple
            // stride decimation would produce).
            var samplesPerPx = sliceLen / W;
            ctx.beginPath();
            for (var col = 0; col < W; col++) {
                var i0 = Math.floor(col * samplesPerPx);
                var i1 = Math.min(sliceLen, Math.floor((col + 1) * samplesPerPx));
                if (i1 <= i0) i1 = i0 + 1;
                var lo = Infinity, hi = -Infinity;
                for (var i = i0; i < i1; i++) {
                    var v = slice[i];
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                }
                if (!isFinite(lo) || !isFinite(hi)) continue;
                var yLo = mapY(lo);
                var yHi = mapY(hi);
                // Ensure a 1px tall stroke when min === max in this column.
                if (Math.abs(yLo - yHi) < 1) yLo = yHi + 1;
                ctx.moveTo(col + 0.5, yHi);
                ctx.lineTo(col + 0.5, yLo);
            }
            if (draw === 'dots') {
                // Dots over a heavily decimated buffer aren't meaningful;
                // fall back to the line rendering.
                ctx.stroke();
                return;
            }
            ctx.stroke();
            // 'filled' under decimation: fill from each column's max
            // down to the baseline. Baseline = bottom of canvas (auto-
            // ranged) — fill is mostly visual texture here, not a
            // semantic area.
            if (draw === 'filled') {
                ctx.beginPath();
                ctx.moveTo(0, H);
                var samplesPerPx2 = sliceLen / W;
                for (var c2 = 0; c2 < W; c2++) {
                    var j0 = Math.floor(c2 * samplesPerPx2);
                    var j1 = Math.min(sliceLen, Math.floor((c2 + 1) * samplesPerPx2));
                    if (j1 <= j0) j1 = j0 + 1;
                    var hi2 = -Infinity;
                    for (var jj = j0; jj < j1; jj++) {
                        var vv = slice[jj];
                        if (vv > hi2) hi2 = vv;
                    }
                    // Drop to baseline for non-finite columns so the
                    // fill doesn't bridge across the gap from the
                    // previous valid column to the next.
                    var py2 = isFinite(hi2) ? mapY(hi2) : H;
                    ctx.lineTo(c2 + 0.5, py2);
                }
                ctx.lineTo(W, H);
                ctx.closePath();
                ctx.fill();
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
    define('cdp-meter', CdpMeter);
    define('cdp-scope', CdpScope);
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
