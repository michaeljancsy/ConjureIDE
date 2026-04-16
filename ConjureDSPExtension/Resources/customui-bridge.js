/*
 * ConjureDSP custom-UI bridge.
 *
 * Injected by CustomUIWebView as a WKUserScript at document start, before any
 * preset-authored JS runs. Exposes `window.ConjureDSP` with a stable API that
 * custom preset UIs use to read/write parameters and react to DAW automation.
 *
 * API surface (v1):
 *   ConjureDSP.apiVersion               // integer; bump on breaking changes
 *   ConjureDSP.parameters.count         // number of exposed parameters
 *   ConjureDSP.parameters.get(i)        // current denormalized value for index i
 *   ConjureDSP.parameters.set(i, v)     // write a new value (triggers DAW automation)
 *   ConjureDSP.parameters.metadata(i)   // {name, min, max, unit, curve, style, options, default}
 *   ConjureDSP.parameters.onChange(i, cb)     // fires whenever value[i] changes
 *   ConjureDSP.parameters.onAnyChange(cb)     // fires with (index, value) on any change
 *   ConjureDSP.theme                    // 'light' | 'dark'
 *   // Listen for 'themechange' on window: e.detail.theme === 'light' | 'dark'
 *   ConjureDSP.ready(cb)                // fires once when initial state has arrived
 *   ConjureDSP.log(...args)             // forwards to the plugin's os_log
 *
 * Internal (Swift-facing; do not call from preset code):
 *   ConjureDSP._init(state)             // initial {metadata, values, theme}
 *   ConjureDSP._paramUpdate(i, v)       // DAW automation / MIDI / host change
 *   ConjureDSP._setTheme(theme)         // theme flip from OS/app
 */

(function() {
    'use strict';

    var _metadata = [];
    var _values = [];
    var _theme = 'light';
    var _ready = false;

    var _paramHandlers = {};       // index (string) -> [callback]
    var _anyHandlers = [];          // [callback(index, value)]
    var _readyHandlers = [];        // [callback] (queued until _init)

    function postTo(name, payload) {
        try {
            if (window.webkit &&
                window.webkit.messageHandlers &&
                window.webkit.messageHandlers[name]) {
                window.webkit.messageHandlers[name].postMessage(payload);
            }
        } catch (e) { /* bridge not available */ }
    }

    function safeInvoke(fn, args, label) {
        try { fn.apply(null, args); }
        catch (e) {
            try { postTo('log', '[' + label + '] ' + (e && e.message ? e.message : String(e))); } catch (_) {}
        }
    }

    var ConjureDSP = {
        apiVersion: 1,

        parameters: {
            get count() { return _metadata.length; },
            get: function(i) { return _values[i]; },
            set: function(i, value) {
                var v = Number(value);
                if (!isFinite(v)) return;
                _values[i] = v;
                postTo('paramSet', { index: i, value: v });
            },
            metadata: function(i) {
                // Return a shallow copy so preset code can't mutate the shared record.
                var m = _metadata[i];
                return m ? Object.assign({}, m) : null;
            },
            onChange: function(i, cb) {
                if (typeof cb !== 'function') return;
                var key = String(i);
                (_paramHandlers[key] = _paramHandlers[key] || []).push(cb);
            },
            onAnyChange: function(cb) {
                if (typeof cb === 'function') _anyHandlers.push(cb);
            },
        },

        get theme() { return _theme; },

        ready: function(cb) {
            if (typeof cb !== 'function') return;
            if (_ready) { safeInvoke(cb, [], 'ready'); }
            else { _readyHandlers.push(cb); }
        },

        log: function() {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
                var a = arguments[i];
                parts.push(typeof a === 'string' ? a : (function () {
                    try { return JSON.stringify(a); } catch (_) { return String(a); }
                })());
            }
            postTo('log', parts.join(' '));
        },
    };

    // --- Internal Swift-facing hooks ---

    ConjureDSP._init = function(state) {
        _metadata = (state && state.metadata) ? state.metadata.slice() : [];
        _values = (state && state.values) ? state.values.slice() : [];
        _theme = (state && state.theme) || 'light';
        _ready = true;

        var handlers = _readyHandlers.slice();
        _readyHandlers.length = 0;
        for (var i = 0; i < handlers.length; i++) safeInvoke(handlers[i], [], 'ready');

        try { window.dispatchEvent(new CustomEvent('ConjureDSPReady')); } catch (_) {}
    };

    ConjureDSP._paramUpdate = function(i, v) {
        _values[i] = v;
        var handlers = _paramHandlers[String(i)] || [];
        for (var k = 0; k < handlers.length; k++) safeInvoke(handlers[k], [v], 'onChange');
        for (var j = 0; j < _anyHandlers.length; j++) safeInvoke(_anyHandlers[j], [i, v], 'onAnyChange');
    };

    ConjureDSP._setTheme = function(theme) {
        _theme = theme;
        try {
            window.dispatchEvent(new CustomEvent('themechange', { detail: { theme: theme } }));
        } catch (_) {}
    };

    // Forward uncaught JS errors to the plugin log so author-side bugs are
    // visible in Console.app without the author having to open Web Inspector.
    window.addEventListener('error', function(ev) {
        try {
            postTo('log', '[js-error] ' + ev.message + ' (' + (ev.filename || '?') + ':' + (ev.lineno || 0) + ')');
        } catch (_) {}
    });

    window.ConjureDSP = ConjureDSP;

    // Tell Swift we've installed the API and are ready for _init.
    postTo('ready', {});
})();
