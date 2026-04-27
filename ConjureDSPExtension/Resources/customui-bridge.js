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
 *   ConjureDSP.audio.onFrame(cb, opts?) // fires at the bundle's manifest.fps
 *                                       // (default 30 Hz). Frame payload:
 *                                       //   {rmsIn, rmsOut, peakIn, peakOut, t}
 *                                       // With opts = { fft: true }, frame also
 *                                       // includes fftIn/fftOut (arrays of dB
 *                                       // bins, ~8 KB/tick; opt-in so basic VU
 *                                       // meters don't pay the encode cost).
 *                                       // Subscribing the first callback
 *                                       // activates audio capture; the last
 *                                       // offFrame() deactivates it.
 *   ConjureDSP.audio.offFrame(cb)       // remove a previously-registered cb
 *
 * Internal (Swift-facing; do not call from preset code):
 *   ConjureDSP._init(state)             // initial {metadata, values, theme}
 *   ConjureDSP._paramUpdate(i, v)       // DAW automation / MIDI / host change
 *   ConjureDSP._setTheme(theme)         // theme flip from OS/app
 *   ConjureDSP._audioFrame(frame)       // audio tick from capture manager
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
    var _audioHandlers = [];        // [{cb, wantsFft}]
    var _audioFftOn = false;        // last FFT flag sent to Swift
    var _audioSubscribed = false;   // true after a subscribeAudioFrames post, false after unsubscribe

    // `parameters.set(...)` fires onChange/onAnyChange handlers
    // synchronously, exactly like an external `_paramUpdate` callback
    // would. That makes the low-level `ConjureDSP.ui.control(i)` API
    // safe by default for hand-rolled custom widgets: a knob whose
    // visual update lives inside `ctrl.onChange(refresh)` redraws on
    // the user's own drag, not just on DAW automation.
    //
    // No double-fire risk: Swift's parameter observer is registered
    // with our own AU originator token, so AU's contract excludes
    // self-writes from `_paramUpdate` echoes (pinned by
    // ParameterStateEchoTests.swift). The synchronous fire from
    // `set()` is the ONLY notification path for self-writes; the
    // asynchronous `_paramUpdate` path is the ONLY notification for
    // external changes (DAW automation, MIDI, MCP, preset load).
    //
    // Recursion is broken at the source by a dedupe-on-equal guard
    // inside `set()` — a handler that re-sets the same value it was
    // called with terminates after one extra hop. Cross-parameter
    // writes pass through unchanged; that's the author's loop to
    // avoid.

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

    // Recompute the audio subscription state based on current handlers.
    // Posts subscribe/unsubscribe to Swift only when the effective state
    // changes (empty→non-empty, non-empty→empty, FFT flag flipped).
    function _syncAudioSubscription() {
        if (_audioHandlers.length === 0) {
            // Only post `unsubscribe` when we'd previously subscribed —
            // otherwise a UI that adds + removes a handler before ever
            // actually firing (tests, early cleanup) spams Swift with
            // unsubscribe messages that correspond to no subscription.
            if (_audioSubscribed) {
                postTo('unsubscribeAudioFrames', {});
                _audioFftOn = false;
                _audioSubscribed = false;
            }
            return;
        }
        var wantsFft = false;
        for (var i = 0; i < _audioHandlers.length; i++) {
            if (_audioHandlers[i].wantsFft) { wantsFft = true; break; }
        }
        // Always post subscribe on any transition — Swift treats it as
        // idempotent state sync. Cheap.
        postTo('subscribeAudioFrames', { fft: wantsFft });
        _audioFftOn = wantsFft;
        _audioSubscribed = true;
    }

    var ConjureDSP = {
        apiVersion: 1,

        parameters: {
            get count() { return _metadata.length; },
            get: function(i) { return _values[i]; },
            set: function(i, value) {
                var v = Number(value);
                if (!isFinite(v)) {
                    // postTo('log', '[2.js.bridge.set.SKIP] idx=' + i + ' v=' + value + ' (not finite)');
                    return;
                }
                // Dedupe-on-equal: cheapens drag-rate writes that don't
                // change the value (handlers like `if (n !== last) ...`
                // become unnecessary), and — critically — terminates
                // recursion when an onChange handler re-sets the same
                // value it was called with. Without this guard, a
                // quantize handler that does `set(i, Math.round(v))`
                // would loop forever once `v` is already an integer.
                if (_values[i] === v) return;
                // postTo('log', '[2.js.bridge.set] idx=' + i + ' v=' + v);
                _values[i] = v;
                postTo('paramSet', { index: i, value: v });
                // Fire onChange/onAnyChange synchronously, same payload
                // shape as the external `_paramUpdate` path. Custom
                // widgets that depend on `ctrl.onChange(...)` for
                // visual feedback see their handler run for the user's
                // own drag, not just for DAW automation. See header
                // comment for why this can't double-fire with Swift.
                var handlers = _paramHandlers[String(i)] || [];
                for (var k = 0; k < handlers.length; k++) safeInvoke(handlers[k], [v], 'onChange');
                for (var j = 0; j < _anyHandlers.length; j++) safeInvoke(_anyHandlers[j], [i, v], 'onAnyChange');
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

        audio: {
            // onFrame(cb[, options])
            //   options.fft = true  -> frames include fftIn/fftOut arrays
            //                          (halfN floats each, ~8 KB JSON/tick).
            //   Default RMS/peak-only frames are ~80 bytes.
            // First subscriber activates capture; last unsubscriber stops it.
            onFrame: function(cb, options) {
                if (typeof cb !== 'function') return;
                _audioHandlers.push({ cb: cb, wantsFft: !!(options && options.fft) });
                _syncAudioSubscription();
            },
            offFrame: function(cb) {
                for (var i = 0; i < _audioHandlers.length; i++) {
                    if (_audioHandlers[i].cb === cb) {
                        _audioHandlers.splice(i, 1);
                        _syncAudioSubscription();
                        return;
                    }
                }
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
        // Swift only calls this for EXTERNAL changes — DAW automation,
        // MIDI, MCP writes, preset load. UI-initiated writes via
        // `parameters.set()` are filtered out at the Swift side by AU's
        // originator exclusion, so we can unconditionally update state
        // and fire onChange here.
        // postTo('log', '[8.js.bridge.update] idx=' + i + ' v=' + v);
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

    ConjureDSP._audioFrame = function(frame) {
        if (!frame) return;
        for (var i = 0; i < _audioHandlers.length; i++) {
            safeInvoke(_audioHandlers[i].cb, [frame], 'onFrame');
        }
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
