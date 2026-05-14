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
 *                                       // Note: fftIn/fftOut are the RAW per-
 *                                       // tick FFT magnitudes in dB. The host
 *                                       // app's built-in spectrogram smooths
 *                                       // its column display to damp the
 *                                       // hop-to-hop cross-term wobble of
 *                                       // windowed-sine FFTs; custom UIs
 *                                       // building their own spectrum view
 *                                       // get raw bins here so they can
 *                                       // apply their own smoothing if they
 *                                       // want. Don't expect a custom <cdp-scope>
 *                                       // to look identical to the built-in
 *                                       // spectrogram on a stationary tone.
 *                                       // Subscribing the first callback
 *                                       // activates audio capture; the last
 *                                       // offFrame() deactivates it.
 *   ConjureDSP.audio.offFrame(cb)       // remove a previously-registered cb
 *
 *   ConjureDSP.transport.bpm                 // tempo in BPM (read-only snapshot)
 *   ConjureDSP.transport.isPlaying           // bool
 *   ConjureDSP.transport.beat                // current beat
 *   ConjureDSP.transport.samplePosition      // current sample frame
 *   ConjureDSP.transport.timeSigNumerator    // int (e.g. 4)
 *   ConjureDSP.transport.timeSigDenominator  // int (e.g. 4)
 *   ConjureDSP.transport.onChange(cb)        // cb({bpm, isPlaying, beat, ...})
 *                                            // fires only when something
 *                                            // changes; ~30 Hz max. First
 *                                            // subscriber activates the
 *                                            // push channel; last
 *                                            // offChange() deactivates it.
 *                                            // Independent of audio.onFrame.
 *   ConjureDSP.transport.offChange(cb)
 *
 *   ConjureDSP.state.get(key)                // current value for key
 *   ConjureDSP.state.set(key, value)         // write JSON-serializable value;
 *                                            // returns true on success, false
 *                                            // if the resulting mirror would
 *                                            // exceed MAX_STATE_BYTES (state
 *                                            // is then NOT mutated).
 *                                            // Sync-only; no async failure.
 *   ConjureDSP.state.onChange(key, cb)       // fires whenever state[key] changes
 *   ConjureDSP.state.onAnyChange(cb)         // fires with (key, value) on any change
 *   ConjureDSP.state.reset(key)              // restore one key to script default
 *   ConjureDSP.state.resetAll()              // restore all keys to script defaults
 *
 *   IMPORTANT: state values are captured at the moment of `set(key, value)`
 *   by JSON serialization. Mutating `value` (e.g. pushing to an array) AFTER
 *   the call does NOT propagate the mutation — the kernel only sees what was
 *   serialized. Re-call `set(key, value)` to push subsequent changes.
 *
 * Internal (Swift-facing; do not call from preset code):
 *   ConjureDSP._init(state)             // initial {metadata, values, theme,
 *                                       //          state, declaredStateKeys,
 *                                       //          maxStateBytes}
 *   ConjureDSP._paramUpdate(i, v)       // DAW automation / MIDI / host change
 *   ConjureDSP._setTheme(theme)         // theme flip from OS/app
 *   ConjureDSP._audioFrame(frame)       // audio tick from capture manager
 *   ConjureDSP._transportUpdate(snap)   // host transport change
 *   ConjureDSP._stateUpdate(key, value) // external state mutation (DAW load,
 *                                       // MCP, preset switch). key === null &&
 *                                       // value === null means "everything
 *                                       // reset" — re-fire onAnyChange.
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

    // Latest-wins slot for audio frames. Swift writes the freshest payload
    // here on every CADisplayLink tick; a requestAnimationFrame loop reads
    // the slot at vsync and dispatches to subscribers. Decoupling the
    // Swift-side write from the JS-side dispatch eliminates the variable
    // 0–16 ms phase mismatch that the older "Swift invokes handler ->
    // schedule RAF -> next vsync paints" path produced. Each frame carries
    // a `seq` counter; the RAF loop skips dispatch when seq hasn't moved
    // (avoids replaying the same payload across idle ticks, which would
    // scroll history at RAF rate even when audio hasn't advanced).
    var _audioLatestFrame = null;
    var _audioProcessedSeq = -1;
    var _audioRafHandle = 0;        // 0 = loop not running

    // Transport push channel — independent of audio frames. Swift fires
    // _transportUpdate only on actual changes (~30 Hz max), so no RAF
    // dispatch loop is needed; handlers run synchronously inside
    // _transportUpdate.
    var _transport = {
        bpm: 0,
        isPlaying: false,
        beat: 0,
        samplePosition: 0,
        timeSigNumerator: 4,
        timeSigDenominator: 4,
    };
    var _transportHandlers = [];
    var _transportSubscribed = false;

    // State channel — bundle-private, UI-writable, audio-readable JSON.
    // The kernel atomically swaps the JSON byte buffer; the audio thread
    // reads it once per render block; backends (Python/WASM) deserialize
    // lazily on generation bumps. Used for things like step-sequencer slot
    // positions that aren't host-automatable parameters but are per-instance
    // user data.
    var _state = {};
    var _declaredStateKeys = [];
    var MAX_STATE_BYTES = 65536;
    var _stateHandlers = {};       // key -> [callback]
    var _anyStateHandlers = [];    // [callback(key, value)]
    var _warnedKeys = new Set();   // Set of keys we've already warned about; initialized upfront so a state.set() that races _init doesn't crash

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

    // RAF loop: drains the latest-wins slot and dispatches to subscribers.
    // Self-rescheduling, paused when there are no subscribers (start/stop
    // tied to _syncAudioSubscription transitions). The seq dedupe means an
    // idle plugin (Swift still writing the same scalar) doesn't redeliver
    // payloads to subscribers — it just sits.
    function _audioRafTick() {
        _audioRafHandle = 0;
        if (_audioHandlers.length === 0) return;
        var frame = _audioLatestFrame;
        if (frame && frame.seq !== _audioProcessedSeq) {
            _audioProcessedSeq = frame.seq;
            for (var i = 0; i < _audioHandlers.length; i++) {
                safeInvoke(_audioHandlers[i].cb, [frame], 'onFrame');
            }
        }
        _audioRafHandle = window.requestAnimationFrame(_audioRafTick);
    }

    // Recompute the audio subscription state based on current handlers.
    // Posts subscribe/unsubscribe to Swift only when the effective state
    // changes (empty→non-empty, non-empty→empty, FFT flag flipped). Also
    // starts/stops the RAF dispatch loop in lockstep with the subscription.
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
            if (_audioRafHandle) {
                window.cancelAnimationFrame(_audioRafHandle);
                _audioRafHandle = 0;
            }
            _audioLatestFrame = null;
            _audioProcessedSeq = -1;
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
        if (!_audioRafHandle) {
            _audioRafHandle = window.requestAnimationFrame(_audioRafTick);
        }
    }

    // Sync the transport subscription on consumer count transitions.
    // Empty→non-empty posts subscribeTransport; non-empty→empty posts
    // unsubscribeTransport. Symmetric with _syncAudioSubscription but
    // simpler — no FFT flag, no RAF loop (Swift only pushes on changes).
    function _syncTransportSubscription() {
        if (_transportHandlers.length === 0) {
            if (_transportSubscribed) {
                postTo('unsubscribeTransport', {});
                _transportSubscribed = false;
            }
            return;
        }
        if (!_transportSubscribed) {
            postTo('subscribeTransport', {});
            _transportSubscribed = true;
        }
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

        transport: {
            get bpm()                { return _transport.bpm; },
            get isPlaying()          { return _transport.isPlaying; },
            get beat()               { return _transport.beat; },
            get samplePosition()     { return _transport.samplePosition; },
            get timeSigNumerator()   { return _transport.timeSigNumerator; },
            get timeSigDenominator() { return _transport.timeSigDenominator; },
            onChange: function(cb) {
                if (typeof cb !== 'function') return;
                _transportHandlers.push(cb);
                _syncTransportSubscription();
            },
            offChange: function(cb) {
                for (var i = 0; i < _transportHandlers.length; i++) {
                    if (_transportHandlers[i] === cb) {
                        _transportHandlers.splice(i, 1);
                        _syncTransportSubscription();
                        return;
                    }
                }
            },
        },

        // State: bundle-private, UI-writable, audio-readable JSON. See
        // header comment for the mutation footgun (values are captured
        // by serialization at the moment of `set`; later mutations to
        // the same object reference are NOT visible to the kernel).
        state: {
            get: function(key) { return _state[key]; },
            set: function(key, value) {
                // Build a hypothetical new mirror, serialize once, and
                // size-check before committing. If we'd blow MAX_STATE_BYTES,
                // bail BEFORE mutating _state, posting to Swift, or firing
                // listeners — the write is fully rejected.
                var hypothetical = {};
                for (var k in _state) {
                    if (Object.prototype.hasOwnProperty.call(_state, k)) {
                        hypothetical[k] = _state[k];
                    }
                }
                hypothetical[key] = value;
                var serialized;
                try { serialized = JSON.stringify(hypothetical); }
                catch (_) { return false; }
                if (!serialized || serialized.length > MAX_STATE_BYTES) return false;

                // One-time-per-session warning for undeclared keys. The
                // bridge stays permissive (the write succeeds), but the
                // author needs to know the script's ctx.state can't read
                // a key that isn't in the STATE dict.
                if (_declaredStateKeys.indexOf(key) === -1 && !_warnedKeys.has(key)) {
                    _warnedKeys.add(key);
                    postTo('log', "UI wrote state key '" + key + "' which is not declared in the preset's STATE dict. The kernel persists it, but the script's ctx.state cannot read it. Add it to STATE or remove the UI write.");
                }

                _state[key] = value;
                postTo('stateSet', { key: key, value: value });
                // Fire onChange/onAnyChange synchronously; no dedupe-on-equal
                // (deep-equal cost on arrays/objects would dominate). Author
                // is responsible for not re-setting identical values at high rate.
                var handlers = _stateHandlers[key] || [];
                for (var i = 0; i < handlers.length; i++) safeInvoke(handlers[i], [value], 'state.onChange');
                for (var j = 0; j < _anyStateHandlers.length; j++) safeInvoke(_anyStateHandlers[j], [key, value], 'state.onAnyChange');
                return true;
            },
            onChange: function(key, cb) {
                if (typeof cb !== 'function') return;
                (_stateHandlers[key] = _stateHandlers[key] || []).push(cb);
            },
            onAnyChange: function(cb) {
                if (typeof cb === 'function') _anyStateHandlers.push(cb);
            },
            reset: function(key) {
                postTo('stateReset', { key: key });
            },
            resetAll: function() {
                postTo('stateResetAll', {});
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
        _state = (state && state.state) ? state.state : {};
        _declaredStateKeys = (state && state.declaredStateKeys) ? state.declaredStateKeys.slice() : [];
        MAX_STATE_BYTES = (state && typeof state.maxStateBytes === 'number') ? state.maxStateBytes : 65536;
        // Reset undeclared-key warning tracker on every _init so re-load
        // sessions don't carry stale warnings from the previous bundle.
        _warnedKeys = new Set();
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

    // Swift's CADisplayLink stamps the freshest frame into the slot here.
    // Dispatch is deferred to the RAF loop above so paints stay phase-
    // locked with the display refresh rather than with the audio tick.
    ConjureDSP._audioFrame = function(frame) {
        if (!frame) return;
        _audioLatestFrame = frame;
    };

    // Swift's TransportPushManager fires this when the host transport
    // changed since the previous tick (~30 Hz max, no-change ticks
    // suppressed at the source). Update the live snapshot then dispatch
    // to subscribers synchronously — there's no display-rate decoupling
    // to do (the dam is on the Swift side).
    //
    // Backwards-compat: the canonical keys are `bpm` and `beat`, but
    // older Swift builds may still send `tempo` and `beatPosition`.
    // Accept either; canonicalize on the way in so getters always read
    // _transport.bpm / _transport.beat.
    ConjureDSP._transportUpdate = function(snapshot) {
        if (!snapshot) return;
        var snap = snapshot;
        _transport = {
            bpm: snap.bpm !== undefined ? snap.bpm : (snap.tempo !== undefined ? snap.tempo : 0),
            beat: snap.beat !== undefined ? snap.beat : (snap.beatPosition !== undefined ? snap.beatPosition : 0),
            isPlaying: !!snap.isPlaying,
            samplePosition: snap.samplePosition || 0,
            timeSigNumerator: snap.timeSigNumerator || 4,
            timeSigDenominator: snap.timeSigDenominator || 4,
        };
        var handlers = _transportHandlers.slice();
        for (var i = 0; i < handlers.length; i++) {
            safeInvoke(handlers[i], [_transport], 'transport.onChange');
        }
    };

    // External state mutation path — mirrors _paramUpdate. Swift fires
    // this for DAW load, MCP writes, preset switch, or kernel-side reset.
    //   key !== null:                update _state[key], fire listeners
    //   key === null && value === null:  full reset signal — defaults
    //                                    will arrive via the next _init
    //                                    payload, so just fire onAnyChange
    //                                    with (null, null) so consumers can
    //                                    re-read everything when ready.
    ConjureDSP._stateUpdate = function(key, value) {
        if (key === null && value === null) {
            for (var a = 0; a < _anyStateHandlers.length; a++) {
                safeInvoke(_anyStateHandlers[a], [null, null], 'state.onAnyChange');
            }
            return;
        }
        _state[key] = value;
        var handlers = _stateHandlers[key] || [];
        for (var i = 0; i < handlers.length; i++) safeInvoke(handlers[i], [value], 'state.onChange');
        for (var j = 0; j < _anyStateHandlers.length; j++) safeInvoke(_anyStateHandlers[j], [key, value], 'state.onAnyChange');
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
