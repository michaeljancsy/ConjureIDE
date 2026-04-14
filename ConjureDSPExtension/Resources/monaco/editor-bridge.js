// Monaco Editor <-> Swift bridge for ConjureDSP
// Communicates with MonacoEditorView.swift via WKScriptMessageHandler

const bridge = {
    editor: null,
    _changeListener: null,
    _suppressChanges: false,

    init(options) {
        require.config({ paths: { vs: './vs' } });
        require(['vs/editor/editor.main'], () => {
            this.editor = monaco.editor.create(document.getElementById('editor'), {
                value: options.content || '',
                language: options.language || 'python',
                theme: options.theme || 'vs-dark',
                readOnly: options.readOnly || false,
                minimap: { enabled: true },
                automaticLayout: true,
                scrollBeyondLastLine: false,
                fontSize: 13,
                fontFamily: 'SF Mono, Menlo, Monaco, monospace',
                tabSize: 4,
                insertSpaces: true,
                wordWrap: 'on',
                bracketPairColorization: { enabled: true },
                matchBrackets: 'always',
                folding: true,
                renderLineHighlight: 'line',
                smoothScrolling: true,
                cursorBlinking: 'smooth',
                cursorSmoothCaretAnimation: 'on',
                padding: { top: 8 },
                quickSuggestions: { other: 'on', comments: 'off', strings: 'off' },
                quickSuggestionsDelay: 5,
                suggestOnTriggerCharacters: true,
            });

            this._changeListener = this.editor.onDidChangeModelContent(() => {
                if (this._suppressChanges) return;
                webkit.messageHandlers.contentChanged.postMessage(
                    this.editor.getValue()
                );
            });

            // Register custom color themes
            if (typeof registerConjureDSPThemes === 'function') {
                registerConjureDSPThemes();
            }

            // Register DSP-specific completions
            this._registerCompletions();

            webkit.messageHandlers.editorReady.postMessage(true);
        }, (err) => {
            console.error('[ConjureDSP] Monaco require() failed:', err);
        });
    },

    setContent(text) {
        if (!this.editor) return;
        this._suppressChanges = true;
        this.editor.setValue(text);
        this._suppressChanges = false;
    },

    flashContent() {
        if (!this.editor) return;
        const model = this.editor.getModel();
        if (!model) return;
        const fullRange = model.getFullModelRange();
        // Cancel any pending cleanup from a prior flash so it doesn't truncate this one
        if (this._flashTimeout) {
            clearTimeout(this._flashTimeout);
            this._flashTimeout = null;
        }
        this._flashDecorations = this.editor.deltaDecorations(this._flashDecorations || [], [{
            range: fullRange,
            options: { isWholeLine: true, className: 'conjure-mcp-flash' }
        }]);
        this._flashTimeout = setTimeout(() => {
            this._flashTimeout = null;
            if (!this.editor) return;
            this._flashDecorations = this.editor.deltaDecorations(this._flashDecorations || [], []);
        }, 1900);
    },

    insertAtCursor(text) {
        if (!this.editor) return;
        const selection = this.editor.getSelection();
        const op = { range: selection, text: text, forceMoveMarkers: true };
        this._suppressChanges = true;
        this.editor.executeEdits('conjuredsp', [op]);
        this._suppressChanges = false;
        // Notify Swift of the change via the registered handler
        const fullText = this.editor.getValue();
        webkit.messageHandlers.contentChanged.postMessage(fullText);
    },

    setLanguage(lang) {
        if (!this.editor) return;
        const model = this.editor.getModel();
        if (model) {
            monaco.editor.setModelLanguage(model, lang);
        }
    },

    setTheme(theme) {
        monaco.editor.setTheme(theme);
    },

    setReadOnly(flag) {
        if (!this.editor) return;
        this.editor.updateOptions({ readOnly: flag });
    },

    scrollToBottom() {
        if (!this.editor) return;
        const lineCount = this.editor.getModel().getLineCount();
        this.editor.revealLine(lineCount);
    },

    setMarkers(markers) {
        if (!this.editor) return;
        const model = this.editor.getModel();
        if (!model) return;
        const monacoMarkers = markers.map(m => ({
            startLineNumber: m.startLine || 1,
            startColumn: m.startColumn || 1,
            endLineNumber: m.endLine || m.startLine || 1,
            endColumn: m.endColumn || 1000,
            message: m.message || '',
            severity: m.severity === 'warning'
                ? monaco.MarkerSeverity.Warning
                : monaco.MarkerSeverity.Error,
        }));
        monaco.editor.setModelMarkers(model, 'conjuredsp', monacoMarkers);
    },

    clearMarkers() {
        if (!this.editor) return;
        const model = this.editor.getModel();
        if (model) {
            monaco.editor.setModelMarkers(model, 'conjuredsp', []);
        }
    },

    focus() {
        if (this.editor) this.editor.focus();
    },

    _registerCompletions() {
        const Kind = monaco.languages.CompletionItemKind;
        const SnippetRule = monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet;

        // Helper to build a suggestion object
        function sug(label, kind, insertText, doc, isSnippet) {
            const s = { label, kind, insertText, documentation: doc };
            if (isSnippet) s.insertTextRules = SnippetRule;
            return s;
        }

        // ── Shared documentation data ──────────────────────────────────
        // Single source of truth for completions, signature help, and hover.

        const biquadCoeffsStatics = [
            { name: 'lowpass', sig: '(freq, q, sample_rate)', rustSig: '(freq: f64, q: f64, sample_rate: f64) -> BiquadCoeffs', doc: 'Low-pass filter. Passes frequencies below cutoff.', params: [{ label: 'freq', doc: 'Cutoff frequency in Hz' }, { label: 'q', doc: 'Q factor (0.707 = Butterworth)' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'highpass', sig: '(freq, q, sample_rate)', rustSig: '(freq: f64, q: f64, sample_rate: f64) -> BiquadCoeffs', doc: 'High-pass filter. Passes frequencies above cutoff.', params: [{ label: 'freq', doc: 'Cutoff frequency in Hz' }, { label: 'q', doc: 'Q factor (0.707 = Butterworth)' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'bandpass', sig: '(freq, q, sample_rate)', rustSig: '(freq: f64, q: f64, sample_rate: f64) -> BiquadCoeffs', doc: 'Band-pass filter. Passes a frequency band.', params: [{ label: 'freq', doc: 'Center frequency in Hz' }, { label: 'q', doc: 'Q factor (bandwidth)' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'notch', sig: '(freq, q, sample_rate)', rustSig: '(freq: f64, q: f64, sample_rate: f64) -> BiquadCoeffs', doc: 'Notch (band-reject) filter.', params: [{ label: 'freq', doc: 'Center frequency in Hz' }, { label: 'q', doc: 'Q factor (notch width)' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'peak', sig: '(freq, q, gain_db, sample_rate)', rustSig: '(freq: f64, q: f64, gain_db: f64, sample_rate: f64) -> BiquadCoeffs', doc: 'Peaking EQ. Boost or cut at center frequency.', params: [{ label: 'freq', doc: 'Center frequency in Hz' }, { label: 'q', doc: 'Q factor (bandwidth)' }, { label: 'gain_db', doc: 'Gain in dB (positive = boost, negative = cut)' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'lowshelf', sig: '(freq, q, gain_db, sample_rate)', rustSig: '(freq: f64, q: f64, gain_db: f64, sample_rate: f64) -> BiquadCoeffs', doc: 'Low shelf. Boost or cut frequencies below cutoff.', params: [{ label: 'freq', doc: 'Shelf frequency in Hz' }, { label: 'q', doc: 'Q factor (shelf slope)' }, { label: 'gain_db', doc: 'Gain in dB' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'highshelf', sig: '(freq, q, gain_db, sample_rate)', rustSig: '(freq: f64, q: f64, gain_db: f64, sample_rate: f64) -> BiquadCoeffs', doc: 'High shelf. Boost or cut frequencies above cutoff.', params: [{ label: 'freq', doc: 'Shelf frequency in Hz' }, { label: 'q', doc: 'Q factor (shelf slope)' }, { label: 'gain_db', doc: 'Gain in dB' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'allpass', sig: '(freq, q, sample_rate)', rustSig: '(freq: f64, q: f64, sample_rate: f64) -> BiquadCoeffs', doc: 'All-pass filter. Shifts phase without changing amplitude.', params: [{ label: 'freq', doc: 'Frequency in Hz' }, { label: 'q', doc: 'Q factor' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
        ];

        const biquadMethods = [
            { name: 'set_coeffs', sig: '(coeffs)', rustSig: '(&mut self, coeffs: BiquadCoeffs)', doc: 'Update filter coefficients without resetting state.', params: [{ label: 'coeffs', doc: 'BiquadCoeffs instance' }] },
            { name: 'process_sample', sig: '(x)', rustSig: '(&mut self, x: f64) -> f64', doc: 'Process a single sample through the filter. Returns filtered output.', params: [{ label: 'x', doc: 'Input sample' }] },
            { name: 'reset', sig: '()', rustSig: '(&mut self)', doc: 'Reset filter state to zero (clear internal memory).', params: [] },
        ];

        const delayLineMethods = [
            { name: 'write', sig: '(sample)', rustSig: '(&mut self, sample: f32)', doc: 'Write a sample and advance the write head.', params: [{ label: 'sample', doc: 'Input sample value' }] },
            { name: 'read', sig: '(delay_samples)', rustSig: '(&self, delay_samples: f64) -> f32', doc: 'Read with linear interpolation. delay_samples can be fractional.', params: [{ label: 'delay_samples', doc: 'Delay in samples (fractional OK)' }] },
            { name: 'read_cubic', sig: '(delay_samples)', rustSig: '(&self, delay_samples: f64) -> f32', doc: 'Read with cubic (Hermite) interpolation. Better quality for pitch/modulation.', params: [{ label: 'delay_samples', doc: 'Delay in samples (fractional OK)' }] },
            { name: 'tap', sig: '(delay_samples)', rustSig: '(&self, delay_samples: usize) -> f32', doc: 'Read at integer delay (no interpolation).', params: [{ label: 'delay_samples', doc: 'Delay in samples (integer)' }] },
            { name: 'clear', sig: '()', rustSig: '(&mut self)', doc: 'Zero entire buffer and reset write position.', params: [] },
        ];
        const delayLineProperties = [
            { name: 'max_samples', doc: 'Maximum delay length in samples (read-only property).' },
        ];

        const lfoMethods = [
            { name: 'set_freq', sig: '(freq)', rustSig: '(&mut self, freq: f64)', doc: 'Update oscillation frequency in Hz.', params: [{ label: 'freq', doc: 'Frequency in Hz' }] },
            { name: 'set_waveform', sig: '(waveform)', rustSig: '(&mut self, waveform: Waveform)', doc: 'Change waveform type. Python: "sine", "triangle", "saw", "square". Rust: Waveform::Sine etc.', params: [{ label: 'waveform', doc: 'Waveform name or variant' }] },
            { name: 'tick', sig: '()', rustSig: '(&mut self) -> f64', doc: 'Advance by one sample. Returns value in [-1, 1].', params: [] },
            { name: 'reset', sig: '()', rustSig: '(&mut self)', doc: 'Reset phase to zero.', params: [] },
        ];
        const lfoMethodsPython = [
            ...lfoMethods,
            { name: 'tick_n', sig: '(n)', rustSig: null, doc: 'Advance by n samples. Returns numpy float32 array. More efficient than tick() in a loop.', params: [{ label: 'n', doc: 'Number of samples to generate' }] },
        ];
        const lfoProperties = [
            { name: 'value', doc: 'Current oscillator value (last tick result).' },
        ];

        const ctxMethods = [
            { name: 'channels', sig: '() -> usize', doc: 'Get the number of audio channels.' },
            { name: 'frames', sig: '() -> usize', doc: 'Get the number of frames in this render block.' },
            { name: 'sample_rate', sig: '() -> f32', doc: 'Get the audio sample rate in Hz.' },
            { name: 'input', sig: '(channel: usize, frame: usize) -> f32', doc: 'Read input sample at [channel, frame].', params: [{ label: 'channel', doc: 'Channel index' }, { label: 'frame', doc: 'Frame index' }] },
            { name: 'set_output', sig: '(channel: usize, frame: usize, value: f32)', doc: 'Write output sample at [channel, frame].', params: [{ label: 'channel', doc: 'Channel index' }, { label: 'frame', doc: 'Frame index' }, { label: 'value', doc: 'Sample value' }] },
            { name: 'param', sig: '(index: usize) -> f32', doc: 'Read parameter at index. Returns denormalized value if metadata exists.', params: [{ label: 'index', doc: 'Parameter index constant' }] },
        ];

        const waveformVariants = [
            { name: 'Sine', doc: 'Sine wave oscillator.' },
            { name: 'Triangle', doc: 'Triangle wave oscillator.' },
            { name: 'Saw', doc: 'Sawtooth wave oscillator.' },
            { name: 'Square', doc: 'Square wave oscillator.' },
        ];

        const dspFunctions = [
            { name: 'db_to_gain', pySig: '(db)', rustSig: '(db: f64) -> f64', doc: 'Convert dB to linear gain. 0 dB = 1.0, -6 dB ≈ 0.5', insert: 'db_to_gain(${1:db})', params: [{ label: 'db', doc: 'Value in decibels' }] },
            { name: 'gain_to_db', pySig: '(gain)', rustSig: '(gain: f64) -> f64', doc: 'Convert linear gain to dB. Clamps to avoid log(0).', insert: 'gain_to_db(${1:gain})', params: [{ label: 'gain', doc: 'Linear gain value' }] },
            { name: 'ms_to_samples', pySig: '(ms, sample_rate)', rustSig: '(ms: f64, sample_rate: f64) -> usize', doc: 'Convert milliseconds to sample count (rounded).', insert: 'ms_to_samples(${1:ms}, ${2:sample_rate})', params: [{ label: 'ms', doc: 'Time in milliseconds' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'samples_to_ms', pySig: '(samples, sample_rate)', rustSig: '(samples: usize, sample_rate: f64) -> f64', doc: 'Convert sample count to milliseconds.', insert: 'samples_to_ms(${1:samples}, ${2:sample_rate})', params: [{ label: 'samples', doc: 'Number of samples' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'freq_to_period', pySig: '(freq, sample_rate)', rustSig: '(freq: f64, sample_rate: f64) -> f64', doc: 'Convert frequency (Hz) to period in samples.', insert: 'freq_to_period(${1:freq}, ${2:sample_rate})', params: [{ label: 'freq', doc: 'Frequency in Hz' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'smooth_coeff', pySig: '(time_ms, sample_rate)', rustSig: '(time_ms: f64, sample_rate: f64) -> f64', doc: 'One-pole smoothing coefficient. Use: state = α*state + (1-α)*target', insert: 'smooth_coeff(${1:time_ms}, ${2:sample_rate})', params: [{ label: 'time_ms', doc: 'Smoothing time in ms' }, { label: 'sample_rate', doc: 'Sample rate in Hz' }] },
            { name: 'soft_clip', pySig: '(x, drive=1.0)', rustSig: '(x: f64, drive: f64) -> f64', doc: 'Soft clipping via tanh saturation.', insert: 'soft_clip(${1:x}, ${2:1.0})', params: [{ label: 'x', doc: 'Input value' }, { label: 'drive', doc: 'Drive amount (default 1.0)' }] },
            { name: 'lerp', pySig: '(a, b, t)', rustSig: '(a: f64, b: f64, t: f64) -> f64', doc: 'Linear interpolation. t=0 → a, t=1 → b.', insert: 'lerp(${1:a}, ${2:b}, ${3:t})', params: [{ label: 'a', doc: 'Start value' }, { label: 'b', doc: 'End value' }, { label: 't', doc: 'Interpolation factor (0–1)' }] },
            { name: 'crossfade', pySig: '(dry, wet, mix, out, n)', rustSig: '(dry: f32, wet: f32, mix: f32) -> f32', doc: 'Linear crossfade. mix=0 → dry, mix=1 → wet.', insert: 'crossfade(${1:dry}, ${2:wet}, ${3:mix})', params: [{ label: 'dry', doc: 'Dry signal' }, { label: 'wet', doc: 'Wet signal' }, { label: 'mix', doc: 'Mix amount (0–1)' }] },
            { name: 'equal_power_crossfade', pySig: '(dry, wet, mix, out, n)', rustSig: null, doc: 'Equal-power crossfade using sine/cosine curves. Preserves energy at 50% mix.', insert: 'equal_power_crossfade(${1:dry}, ${2:wet}, ${3:mix}, ${4:out}, ${5:n})', params: [{ label: 'dry', doc: 'Dry buffer' }, { label: 'wet', doc: 'Wet buffer' }, { label: 'mix', doc: 'Mix (0–1)' }, { label: 'out', doc: 'Output buffer' }, { label: 'n', doc: 'Frame count' }] },
        ];

        const paramBuilders = [
            { name: 'freq', pySig: '(min=20.0, max=20000.0, default=1000.0)', rustSig: '() -> ParamSpec', doc: 'Frequency parameter (Hz, log curve). Customize with .min()/.max()/.default()', insert: 'freq()', params: [{ label: 'min', doc: 'Min frequency (default 20)' }, { label: 'max', doc: 'Max frequency (default 20000)' }, { label: 'default', doc: 'Default value (default 1000)' }] },
            { name: 'db', pySig: '(min=-60.0, max=12.0, default=0.0)', rustSig: '() -> ParamSpec', doc: 'Decibel parameter (dB, linear curve).', insert: 'db()', params: [{ label: 'min', doc: 'Min dB (default -60)' }, { label: 'max', doc: 'Max dB (default 12)' }, { label: 'default', doc: 'Default value (default 0)' }] },
            { name: 'time_ms', pySig: '(min=0.1, max=1000.0, default=100.0)', rustSig: '() -> ParamSpec', doc: 'Time parameter (ms, log curve).', insert: 'time_ms()', params: [{ label: 'min', doc: 'Min ms (default 0.1)' }, { label: 'max', doc: 'Max ms (default 1000)' }, { label: 'default', doc: 'Default value (default 100)' }] },
            { name: 'pct', pySig: '(default=50.0)', rustSig: '() -> ParamSpec', doc: 'Percentage parameter (0–100%).', insert: 'pct()', params: [{ label: 'default', doc: 'Default value (default 50)' }] },
            { name: 'mix', pySig: '(default=0.5)', rustSig: '() -> ParamSpec', doc: 'Wet/dry mix parameter (0.0–1.0).', insert: 'mix()', params: [{ label: 'default', doc: 'Default value (default 0.5)' }] },
            { name: 'toggle', pySig: '(default=0.0)', rustSig: '() -> ParamSpec', doc: 'On/off toggle (renders as switch in UI).', insert: 'toggle()', params: [{ label: 'default', doc: 'Default value (default 0)' }] },
            { name: 'choice', pySig: '(*labels, default=None)', rustSig: null, doc: 'Enum dropdown. Script receives selected index as float.', insert: 'choice(${1:"Low"}, ${2:"High"})', params: [{ label: '*labels', doc: 'Option strings' }, { label: 'default', doc: 'Default label (optional)' }] },
            { name: 'ratio', pySig: '(min=1.0, max=20.0, default=4.0)', rustSig: '() -> ParamSpec', doc: 'Compression/expansion ratio (:1 unit).', insert: 'ratio()', params: [{ label: 'min', doc: 'Min ratio (default 1)' }, { label: 'max', doc: 'Max ratio (default 20)' }, { label: 'default', doc: 'Default value (default 4)' }] },
            { name: 'param', pySig: '(min, max, *, unit="", default=None, curve="linear")', rustSig: '(min: f64, max: f64) -> ParamSpec', doc: 'Generic parameter with custom range.', insert: 'param(${1:min}, ${2:max})', params: [{ label: 'min', doc: 'Minimum value' }, { label: 'max', doc: 'Maximum value' }] },
        ];

        const paramSpecChainMethods = [
            { name: 'min', sig: '(value)', doc: 'Set minimum value.', insert: 'min(${1:value})' },
            { name: 'max', sig: '(value)', doc: 'Set maximum value.', insert: 'max(${1:value})' },
            { name: 'default', sig: '(value)', doc: 'Set default value.', insert: 'default(${1:value})' },
            { name: 'unit', sig: '(str)', doc: 'Set display unit (e.g., "Hz", "dB", "ms").', insert: 'unit("${1:Hz}")' },
            { name: 'curve', sig: '(str)', doc: 'Set curve type: "linear" or "log".', insert: 'curve("${1:log}")' },
        ];

        // Build signature maps for signature help providers
        const pySignatures = {};
        const rustSignatures = {};

        biquadCoeffsStatics.forEach(m => {
            pySignatures['BiquadCoeffs.' + m.name] = { label: 'BiquadCoeffs.' + m.name + m.sig, doc: m.doc, params: m.params };
            rustSignatures['BiquadCoeffs::' + m.name] = { label: 'BiquadCoeffs::' + m.name + m.rustSig, doc: m.doc, params: m.params };
        });
        biquadMethods.forEach(m => {
            pySignatures[m.name] = { label: m.name + m.sig, doc: m.doc, params: m.params };
            rustSignatures[m.name] = { label: m.name + m.rustSig, doc: m.doc, params: m.params };
        });
        delayLineMethods.forEach(m => {
            pySignatures[m.name] = { label: m.name + m.sig, doc: m.doc, params: m.params };
            rustSignatures[m.name] = { label: m.name + m.rustSig, doc: m.doc, params: m.params };
        });
        lfoMethodsPython.forEach(m => {
            pySignatures[m.name] = { label: m.name + m.sig, doc: m.doc, params: m.params };
        });
        lfoMethods.forEach(m => {
            rustSignatures[m.name] = { label: m.name + m.rustSig, doc: m.doc, params: m.params };
        });
        pySignatures['Biquad'] = { label: 'Biquad(coeffs=None)', doc: 'Create a biquad filter. Passthrough if no coeffs.', params: [{ label: 'coeffs', doc: 'BiquadCoeffs instance (optional)' }] };
        pySignatures['DelayLine'] = { label: 'DelayLine(max_samples)', doc: 'Create a delay line with given maximum length.', params: [{ label: 'max_samples', doc: 'Maximum delay in samples' }] };
        pySignatures['LFO'] = { label: 'LFO(sample_rate, freq=1.0, waveform="sine")', doc: 'Create a low-frequency oscillator.', params: [{ label: 'sample_rate', doc: 'Audio sample rate in Hz' }, { label: 'freq', doc: 'Frequency in Hz (default 1.0)' }, { label: 'waveform', doc: '"sine", "triangle", "saw", or "square"' }] };
        rustSignatures['Biquad::new'] = { label: 'Biquad::new() -> Biquad', doc: 'Create a passthrough biquad filter.', params: [] };
        rustSignatures['DelayLine::new'] = { label: 'DelayLine::<SIZE>::new() -> DelayLine', doc: 'Create a zeroed delay line.', params: [] };
        rustSignatures['Lfo::new'] = { label: 'Lfo::new() -> Lfo', doc: 'Create LFO (1 Hz sine, 44100 Hz sample rate).', params: [] };
        rustSignatures['Lfo::init'] = { label: 'Lfo::init(&mut self, sample_rate: f64, freq: f64)', doc: 'Initialize LFO with sample rate and frequency.', params: [{ label: 'sample_rate', doc: 'Sample rate in Hz' }, { label: 'freq', doc: 'Frequency in Hz' }] };
        rustSignatures['init'] = rustSignatures['Lfo::init'];

        dspFunctions.forEach(f => {
            pySignatures[f.name] = { label: f.name + f.pySig, doc: f.doc, params: f.params };
            if (f.rustSig) rustSignatures[f.name] = { label: f.name + f.rustSig, doc: f.doc, params: f.params };
        });
        paramBuilders.forEach(f => {
            pySignatures[f.name] = { label: f.name + f.pySig, doc: f.doc, params: f.params };
            if (f.rustSig) rustSignatures[f.name] = { label: f.name + f.rustSig, doc: f.doc, params: f.params };
        });
        ctxMethods.forEach(m => {
            if (m.params) rustSignatures['ctx.' + m.name] = { label: 'ctx.' + m.name + m.sig, doc: m.doc, params: m.params };
        });

        // Build hover documentation maps
        const pyHoverDocs = {};
        const rustHoverDocs = {};

        pyHoverDocs['Biquad'] = '```python\nclass Biquad(coeffs=None)\n```\nStateful biquad filter (direct form II transposed). One instance per channel.\n\nMethods: `set_coeffs(coeffs)`, `process_sample(x)`, `reset()`';
        pyHoverDocs['BiquadCoeffs'] = '```python\nclass BiquadCoeffs\n```\nImmutable biquad coefficient container.\n\nStatic methods: `lowpass`, `highpass`, `bandpass`, `notch`, `peak`, `lowshelf`, `highshelf`, `allpass`';
        pyHoverDocs['DelayLine'] = '```python\nclass DelayLine(max_samples)\n```\nPre-allocated circular buffer backed by numpy float32 array.\n\nMethods: `write(sample)`, `read(delay)`, `read_cubic(delay)`, `tap(delay)`, `clear()`\nProperty: `max_samples`';
        pyHoverDocs['LFO'] = '```python\nclass LFO(sample_rate, freq=1.0, waveform="sine")\n```\nLow-frequency oscillator with sine/triangle/saw/square waveforms.\n\nMethods: `set_freq(freq)`, `set_waveform(wf)`, `tick()`, `tick_n(n)`, `reset()`\nProperty: `value`';

        rustHoverDocs['Biquad'] = '```rust\nstruct Biquad\n```\nStateful biquad filter (direct form II transposed). `#[derive(Clone, Copy)]`\n\nMethods: `new()`, `set_coeffs(coeffs)`, `process_sample(x) -> f64`, `reset()`';
        rustHoverDocs['BiquadCoeffs'] = '```rust\nstruct BiquadCoeffs\n```\nBiquad coefficient container. `#[derive(Clone, Copy)]`\n\nAssociated fns: `lowpass`, `highpass`, `bandpass`, `notch`, `peak`, `lowshelf`, `highshelf`, `allpass`';
        rustHoverDocs['DelayLine'] = '```rust\nstruct DelayLine<const SIZE: usize>\n```\nCircular delay buffer. `#[derive(Clone, Copy)]`\n\nMethods: `new()`, `write(sample)`, `read(delay) -> f32`, `read_cubic(delay) -> f32`, `tap(n) -> f32`, `clear()`';
        rustHoverDocs['Lfo'] = '```rust\nstruct Lfo\n```\nLow-frequency oscillator. `#[derive(Clone, Copy)]`\n\nMethods: `new()`, `init(sr, freq)`, `set_freq(f)`, `set_waveform(wf)`, `tick() -> f64`, `reset()`\nField: `value: f64`';
        rustHoverDocs['Waveform'] = '```rust\nenum Waveform { Sine, Triangle, Saw, Square }\n```\nWaveform type for `Lfo::set_waveform()`.';
        rustHoverDocs['Context'] = '```rust\nstruct Context\n```\nSafe wrapper for audio buffer access. Created by `ctx()` (from `setup!()`).\n\nMethods: `channels()`, `frames()`, `sample_rate()`, `input(ch, fr)`, `set_output(ch, fr, val)`, `param(idx)`';
        rustHoverDocs['ParamSpec'] = '```rust\nstruct ParamSpec\n```\nParameter specification. Builder pattern with `.min()`, `.max()`, `.default()`, `.unit()`, `.curve()`.';

        dspFunctions.forEach(f => {
            pyHoverDocs[f.name] = '```python\n' + f.name + f.pySig + '\n```\n' + f.doc;
            if (f.rustSig) rustHoverDocs[f.name] = '```rust\nfn ' + f.name + f.rustSig + '\n```\n' + f.doc;
        });
        paramBuilders.forEach(f => {
            pyHoverDocs[f.name] = '```python\n' + f.name + f.pySig + '\n```\n' + f.doc;
            if (f.rustSig) rustHoverDocs[f.name] = '```rust\nconst fn ' + f.name + f.rustSig + '\n```\n' + f.doc;
        });

        // numpy / scipy / math hover docs
        pyHoverDocs['numpy'] = '`numpy` — N-dimensional array library for numerical computing. Pre-installed in ConjureDSP runtime.\n\nCommon: `np.zeros()`, `np.clip()`, `np.sin()`, `np.fft.rfft()`';
        pyHoverDocs['np'] = pyHoverDocs['numpy'];
        pyHoverDocs['scipy'] = '`scipy` — Scientific computing library. Pre-installed in ConjureDSP runtime.\n\nUseful submodules: `scipy.signal` (filters, windows), `scipy.fft` (FFT)';
        pyHoverDocs['signal'] = '`scipy.signal` — Signal processing module.\n\nFilter design: `butter()`, `cheby1()`, `iirfilter()`, `firwin()`\nFilter application: `sosfilt()`, `lfilter()`, `fftconvolve()`\nAnalysis: `stft()`, `hilbert()`\nWindows: `windows.hann()`, `windows.hamming()`';
        pyHoverDocs['math'] = '`math` — Python standard math module.\n\nConstants: `pi`, `e`\nFunctions: `sin()`, `cos()`, `exp()`, `log()`, `log10()`, `sqrt()`, `pow()`';

        // Common numpy functions
        pyHoverDocs['zeros'] = '```python\nnp.zeros(shape, dtype=np.float32)\n```\nCreate array of zeros.';
        pyHoverDocs['ones'] = '```python\nnp.ones(shape, dtype=np.float32)\n```\nCreate array of ones.';
        pyHoverDocs['clip'] = '```python\nnp.clip(array, min, max)\n```\nClip values to range. Essential for preventing overflow.';
        pyHoverDocs['linspace'] = '```python\nnp.linspace(start, stop, num)\n```\nEvenly spaced values over interval. Useful for frequency axes, LFO phases.';
        pyHoverDocs['convolve'] = '```python\nnp.convolve(signal, kernel, mode="full")\n```\nConvolution of two arrays. mode: "full", "same", or "valid".';
        pyHoverDocs['tanh'] = '```python\nnp.tanh(array)\n```\nElement-wise hyperbolic tangent. Useful for soft clipping/saturation.';
        pyHoverDocs['roll'] = '```python\nnp.roll(array, shift)\n```\nRoll array elements. Useful for circular buffer operations.';
        pyHoverDocs['rfft'] = '```python\nnp.fft.rfft(signal)\n```\nReal FFT. Returns complex spectrum (positive frequencies only).';
        pyHoverDocs['irfft'] = '```python\nnp.fft.irfft(spectrum)\n```\nInverse real FFT. Converts spectrum back to time domain.';
        pyHoverDocs['rfftfreq'] = '```python\nnp.fft.rfftfreq(n, d=1.0/sample_rate)\n```\nFrequency bins for rfft output.';

        // Common scipy.signal functions
        pyHoverDocs['butter'] = '```python\nsignal.butter(order, cutoff_hz, btype="low", fs=sample_rate, output="sos")\n```\nButterworth filter design. Use output="sos" for numerical stability.\nbtype: "low", "high", "band", "bandstop"';
        pyHoverDocs['sosfilt'] = '```python\nsignal.sosfilt(sos, signal)\n```\nApply SOS filter to signal. For real-time, use sosfilt_zi for initial conditions.';
        pyHoverDocs['sosfilt_zi'] = '```python\nsignal.sosfilt_zi(sos)\n```\nInitial conditions for sosfilt to avoid transient at start.\n`zi = signal.sosfilt_zi(sos); out, zi = signal.sosfilt(sos, x, zi=zi)`';
        pyHoverDocs['firwin'] = '```python\nsignal.firwin(num_taps, cutoff_hz, fs=sample_rate, pass_zero="lowpass")\n```\nFIR filter design using window method.';
        pyHoverDocs['stft'] = '```python\nsignal.stft(signal, fs=sample_rate, nperseg=1024)\n```\nShort-time Fourier transform. Returns (frequencies, times, Zxx).';
        pyHoverDocs['hilbert'] = '```python\nsignal.hilbert(signal)\n```\nAnalytic signal via Hilbert transform. `np.abs(result)` gives envelope.';
        pyHoverDocs['fftconvolve'] = '```python\nsignal.fftconvolve(signal, kernel, mode="same")\n```\nFFT-based convolution. Faster than convolve for long kernels.';

        rustHoverDocs['setup'] = '```rust\nsetup!()\n```\nDeclares INPUT_BUF, OUTPUT_BUF, PARAMS_BUF, TRANSPORT_BUF, MAX_CH, MAX_FR, get_*_ptr() exports, and `ctx()` helper.';
        rustHoverDocs['params'] = '```rust\nparams! { NAME = builder(), ... }\n```\nDeclares parameter index constants, METADATA JSON, and get_param_metadata_ptr/len exports.';
        rustHoverDocs['latency'] = '```rust\nlatency!(samples)\n```\nDeclares algorithmic latency for DAW delay compensation. Generates `get_latency_samples()` export.';

        // Helper: extract function name before cursor's opening paren
        function extractFuncBeforeParen(lineText, col) {
            let depth = 0;
            let i = col - 2; // col is 1-based, lineText is 0-based
            // Walk backwards to find the unmatched (
            for (; i >= 0; i--) {
                if (lineText[i] === ')') depth++;
                else if (lineText[i] === '(') {
                    if (depth === 0) break;
                    depth--;
                }
            }
            if (i < 0) return null;
            // Extract the function/method name before the (
            const before = lineText.substring(0, i).trimEnd();
            const match = before.match(/([\w.:"]+)\s*$/);
            return match ? match[1] : null;
        }

        // Helper: count commas at current nesting level
        function countCommas(lineText, col) {
            let depth = 0;
            let commas = 0;
            let i = col - 2;
            for (; i >= 0; i--) {
                if (lineText[i] === ')') depth++;
                else if (lineText[i] === '(') {
                    if (depth === 0) break;
                    depth--;
                } else if (lineText[i] === ',' && depth === 0) {
                    commas++;
                }
            }
            return commas;
        }

        // ── Python: ConjureDSP DSP snippets ──────────────────────────
        monaco.languages.registerCompletionItemProvider('python', {
            provideCompletionItems(model, position) {
                const word = model.getWordUntilPosition(position);
                const range = {
                    startLineNumber: position.lineNumber,
                    endLineNumber: position.lineNumber,
                    startColumn: word.startColumn,
                    endColumn: word.endColumn,
                };
                const lineContent = model.getLineContent(position.lineNumber);
                const isImportLine = /^\s*(from|import)\s/.test(lineContent);

                // On import lines, only show import completions with full-line replacement
                if (isImportLine) {
                    const lineRange = {
                        startLineNumber: position.lineNumber,
                        endLineNumber: position.lineNumber,
                        startColumn: 1,
                        endColumn: lineContent.length + 1,
                    };
                    return { suggestions: [
                        sug('import numpy as np', Kind.Module,
                            'import numpy as np',
                            'Import numpy (pre-installed in ConjureDSP runtime)', false),
                        sug('import math', Kind.Module,
                            'import math',
                            'Import Python math module', false),
                        sug('from scipy import signal', Kind.Module,
                            'from scipy import signal',
                            'Import scipy.signal for DSP filters (pre-installed in ConjureDSP runtime)', false),
                        sug('from scipy.fft import rfft, irfft, rfftfreq', Kind.Module,
                            'from scipy.fft import rfft, irfft, rfftfreq',
                            'Import scipy FFT functions', false),
                        sug('from conjuredsp import ...', Kind.Module,
                            'from conjuredsp import ${1|freq,db,time_ms,mix,pct,param,toggle,ratio|}',
                            'Import conjuredsp parameter helpers (pre-installed in ConjureDSP runtime)', true),
                        sug('from conjuredsp import freq, db, time_ms, mix, pct, param', Kind.Module,
                            'from conjuredsp import freq, db, time_ms, mix, pct, param',
                            'Import all parameter shorthand builders from conjuredsp', false),
                        sug('from conjuredsp.dsp import db_to_gain, gain_to_db, ms_to_samples, smooth_coeff', Kind.Module,
                            'from conjuredsp.dsp import db_to_gain, gain_to_db, ms_to_samples, smooth_coeff',
                            'Import DSP utility functions', false),
                        sug('from conjuredsp.buffers import DelayLine', Kind.Module,
                            'from conjuredsp.buffers import DelayLine',
                            'Import DelayLine — pre-allocated circular buffer for delay effects', false),
                        sug('from conjuredsp.filters import Biquad, BiquadCoeffs', Kind.Module,
                            'from conjuredsp.filters import Biquad, BiquadCoeffs',
                            'Import biquad filter — coefficient calculation + stateful filtering', false),
                        sug('from conjuredsp.osc import LFO', Kind.Module,
                            'from conjuredsp.osc import LFO',
                            'Import LFO — low-frequency oscillator with sine/triangle/saw/square waveforms', false),
                    ].map(s => ({ ...s, range: lineRange })) };
                }

                return { suggestions: [
                    // ── ConjureDSP API ──
                    sug('process', Kind.Function,
                        [
                            'def process(inputs, outputs, frame_count, sample_rate, params):',
                            '\t"""',
                            '\t${1:Description}',
                            '\t"""',
                            '\tfor ch in range(len(inputs)):',
                            '\t\tfor i in range(frame_count):',
                            '\t\t\toutputs[ch][i] = inputs[ch][i]${0}',
                        ].join('\n'),
                        'ConjureDSP DSP process function. Called each render callback.\n\n' +
                        'Args:\n  inputs: list of numpy float32 arrays (one per channel)\n' +
                        '  outputs: list of numpy float32 arrays (one per channel)\n' +
                        '  frame_count: number of samples to process\n' +
                        '  sample_rate: audio sample rate in Hz\n' +
                        '  params: dict of parameter values (if PARAMS defined) or list of 0-1 floats',
                        true),

                    sug('PARAMS', Kind.Variable,
                        [
                            'PARAMS = {',
                            '\t"${1:cutoff}": {"min": ${2:20.0}, "max": ${3:20000.0}, "unit": "${4:Hz}", "default": ${5:1000.0}, "curve": "${6:log}"},',
                            '\t"${7:mix}": {"min": ${8:0.0}, "max": ${9:1.0}, "unit": "${10:}", "default": ${11:0.5}},',
                            '}',
                        ].join('\n'),
                        'Parameter metadata dict. Defines AU parameters with ranges and units.\n\n' +
                        'Fields per parameter:\n' +
                        '  min, max: value range\n' +
                        '  unit: display unit (Hz, dB, ms, %, :1, etc.)\n' +
                        '  default: initial value\n' +
                        '  curve: "log" for frequency/time params, omit for linear',
                        true),

                    // ── Persistent state pattern ──
                    sug('global state', Kind.Snippet,
                        [
                            '# Persistent state (survives between render callbacks)',
                            '_${1:state} = ${2:0.0}',
                            '',
                            '',
                            'def process(inputs, outputs, frame_count, sample_rate, params):',
                            '\tglobal _${1:state}',
                            '\t${0}',
                        ].join('\n'),
                        'Global variable pattern for persistent state between render callbacks.\n' +
                        'Use for filter state, delay buffers, envelope followers, etc.',
                        true),

                    // ── DSP pattern: delay line ──
                    sug('delay line', Kind.Snippet,
                        [
                            '# Persistent delay buffer',
                            'MAX_DELAY = 48000  # supports 500 ms at 96 kHz',
                            '_delay_buf = None',
                            '_write_pos = 0',
                            '',
                            '# Inside process():',
                            'global _delay_buf, _write_pos',
                            'if _delay_buf is None or len(_delay_buf) != len(inputs):',
                            '\t_delay_buf = [np.zeros(MAX_DELAY, dtype=np.float32) for _ in range(len(inputs))]',
                            '',
                            'delay_samples = int(${1:delay_ms} * 0.001 * sample_rate)',
                            'wp = _write_pos',
                            'for i in range(frame_count):',
                            '\trp = (wp - delay_samples + MAX_DELAY) % MAX_DELAY',
                            '\tfor ch in range(len(inputs)):',
                            '\t\tdelayed = _delay_buf[ch][rp]',
                            '\t\t_delay_buf[ch][wp] = inputs[ch][i] + delayed * ${2:feedback}',
                            '\t\toutputs[ch][i] = inputs[ch][i] * (1.0 - ${3:mix}) + delayed * ${3:mix}',
                            '\twp = (wp + 1) % MAX_DELAY',
                            '_write_pos = wp',
                        ].join('\n'),
                        'Delay line with feedback. Common pattern for echo, chorus, flanger.',
                        true),

                    // ── DSP pattern: biquad filter ──
                    sug('biquad', Kind.Snippet,
                        [
                            '# Biquad filter state (2 samples of history per channel)',
                            '_x1 = [0.0, 0.0]  # x[n-1]',
                            '_x2 = [0.0, 0.0]  # x[n-2]',
                            '_y1 = [0.0, 0.0]  # y[n-1]',
                            '_y2 = [0.0, 0.0]  # y[n-2]',
                            '',
                            '# Inside process():',
                            'global _x1, _x2, _y1, _y2',
                            '# Compute biquad coefficients (low-pass example)',
                            'w0 = 2.0 * math.pi * ${1:cutoff_hz} / sample_rate',
                            'alpha = math.sin(w0) / (2.0 * ${2:q})',
                            'b0 = (1.0 - math.cos(w0)) / 2.0',
                            'b1 = 1.0 - math.cos(w0)',
                            'b2 = b0',
                            'a0 = 1.0 + alpha',
                            'a1 = -2.0 * math.cos(w0)',
                            'a2 = 1.0 - alpha',
                            '# Normalize',
                            'b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0',
                            '',
                            'for ch in range(len(inputs)):',
                            '\tx1, x2, y1, y2 = _x1[ch], _x2[ch], _y1[ch], _y2[ch]',
                            '\tfor i in range(frame_count):',
                            '\t\tx0 = inputs[ch][i]',
                            '\t\ty0 = b0*x0 + b1*x1 + b2*x2 - a1*y1 - a2*y2',
                            '\t\toutputs[ch][i] = y0',
                            '\t\tx2 = x1; x1 = x0; y2 = y1; y1 = y0',
                            '\t_x1[ch] = x1; _x2[ch] = x2; _y1[ch] = y1; _y2[ch] = y2',
                        ].join('\n'),
                        'Biquad filter (2nd-order IIR). Configurable as low-pass, high-pass, bandpass, etc.',
                        true),

                    // ── DSP pattern: envelope follower ──
                    sug('envelope follower', Kind.Snippet,
                        [
                            '_envelope = 0.0',
                            '',
                            '# Inside process():',
                            'global _envelope',
                            'attack_coeff = np.exp(-1.0 / (${1:attack_ms} * 0.001 * sample_rate))',
                            'release_coeff = np.exp(-1.0 / (${2:release_ms} * 0.001 * sample_rate))',
                            'env = _envelope',
                            'for i in range(frame_count):',
                            '\tpeak = max(abs(inputs[ch][i]) for ch in range(len(inputs)))',
                            '\tif peak > env:',
                            '\t\tenv = attack_coeff * env + (1.0 - attack_coeff) * peak',
                            '\telse:',
                            '\t\tenv = release_coeff * env + (1.0 - release_coeff) * peak',
                            '\t${0:# Use env for gain control, sidechain, etc.}',
                            '_envelope = env',
                        ].join('\n'),
                        'Peak-detecting envelope follower with attack/release. Useful for compressors, gates, ducking.',
                        true),

                    // ── Common DSP math ──
                    sug('dB to linear', Kind.Snippet,
                        '${1:linear} = 10.0 ** (${2:db} / 20.0)',
                        'Convert decibels to linear amplitude. 0 dB = 1.0, -6 dB ≈ 0.5, -20 dB = 0.1',
                        true),

                    sug('linear to dB', Kind.Snippet,
                        '${1:db} = 20.0 * np.log10(${2:linear} + 1e-30)',
                        'Convert linear amplitude to decibels. 1e-30 prevents log(0).',
                        true),

                    sug('smoothing coefficient', Kind.Snippet,
                        '${1:coeff} = math.exp(-2.0 * math.pi * ${2:cutoff_hz} / sample_rate)',
                        'One-pole smoothing coefficient from cutoff frequency.\nUse as: y = coeff * y + (1 - coeff) * x',
                        true),

                    // ── conjuredsp function completions ──
                    ...dspFunctions.map(f =>
                        sug(f.name, Kind.Function, f.insert, f.doc, true)),
                    ...paramBuilders.map(f =>
                        sug(f.name, Kind.Function, f.insert, f.doc, true)),

                    // ── Constructor completions ──
                    sug('Biquad', Kind.Function,
                        'Biquad(${1:coeffs})',
                        'Create a stateful biquad filter. Pass BiquadCoeffs or omit for passthrough.\nMethods: set_coeffs(), process_sample(), reset()',
                        true),
                    sug('DelayLine', Kind.Function,
                        'DelayLine(${1:max_samples})',
                        'Create a circular delay buffer.\nMethods: write(), read(), read_cubic(), tap(), clear()\nProperty: max_samples',
                        true),
                    sug('LFO', Kind.Function,
                        'LFO(${1:sample_rate}, freq=${2:1.0}, waveform="${3:sine}")',
                        'Create a low-frequency oscillator.\nWaveforms: "sine", "triangle", "saw", "square"\nMethods: set_freq(), set_waveform(), tick(), tick_n(), reset()\nProperty: value',
                        true),

                    // ── Stateless oscillator functions ──
                    sug('sine', Kind.Function, 'sine(${1:phase})',
                        'Sine wave from phase [0, 1). Returns [-1, 1].', true),
                    sug('triangle', Kind.Function, 'triangle(${1:phase})',
                        'Triangle wave from phase [0, 1). Returns [-1, 1].', true),
                    sug('saw', Kind.Function, 'saw(${1:phase})',
                        'Sawtooth wave from phase [0, 1). Returns [-1, 1].', true),
                    sug('advance_phase', Kind.Function, 'advance_phase(${1:phase}, ${2:freq}, ${3:sample_rate})',
                        'Advance phase by one sample with wrapping. Returns new phase.', true),

                ].map(s => ({ ...s, range })) };
            },
        });

        // ── Python: numpy completions (triggered on ".") ───────────
        monaco.languages.registerCompletionItemProvider('python', {
            triggerCharacters: ['.'],
            provideCompletionItems(model, position) {
                const lineContent = model.getLineContent(position.lineNumber);
                const textBefore = lineContent.substring(0, position.column - 1);

                const word = model.getWordUntilPosition(position);
                const range = {
                    startLineNumber: position.lineNumber,
                    endLineNumber: position.lineNumber,
                    startColumn: word.startColumn,
                    endColumn: word.endColumn,
                };

                // np.fft. completions (must be checked before np.)
                if (textBefore.match(/\bnp\.fft\.\w*$/)) {
                    return { suggestions: [
                        sug('np.fft.rfft', Kind.Function, 'rfft(${1:signal})', 'Real FFT. Returns complex spectrum (positive frequencies only).', true),
                        sug('np.fft.irfft', Kind.Function, 'irfft(${1:spectrum})', 'Inverse real FFT. Converts spectrum back to time domain.', true),
                        sug('np.fft.rfftfreq', Kind.Function, 'rfftfreq(${1:n}, d=1.0/sample_rate)', 'Frequency bins for rfft output.', true),
                        sug('np.fft.fft', Kind.Function, 'fft(${1:signal})', 'Complex FFT. Use rfft for real signals (more efficient).', true),
                        sug('np.fft.ifft', Kind.Function, 'ifft(${1:spectrum})', 'Inverse complex FFT.', true),
                        sug('np.fft.fftfreq', Kind.Function, 'fftfreq(${1:n}, d=1.0/sample_rate)', 'Frequency bins for fft output.', true),
                    ].map(s => ({ ...s, range })) };
                }

                // np.random. completions (must be checked before np.)
                if (textBefore.match(/\bnp\.random\.\w*$/)) {
                    return { suggestions: [
                        sug('np.random.uniform', Kind.Function, 'uniform(${1:-1.0}, ${2:1.0}, ${3:frame_count})', 'Uniform random samples. Useful for noise generation.', true),
                        sug('np.random.normal', Kind.Function, 'normal(${1:0.0}, ${2:1.0}, ${3:frame_count})', 'Gaussian random samples.', true),
                    ].map(s => ({ ...s, range })) };
                }

                // np. completions (general — checked after submodules)
                if (textBefore.match(/\bnp\.\w*$/)) {
                    return { suggestions: [
                        // Array creation
                        sug('np.zeros', Kind.Function, 'zeros(${1:shape}, dtype=np.float32)', 'Create array of zeros. np.zeros(1024) or np.zeros((2, 1024))', true),
                        sug('np.ones', Kind.Function, 'ones(${1:shape}, dtype=np.float32)', 'Create array of ones.', true),
                        sug('np.empty', Kind.Function, 'empty(${1:shape}, dtype=np.float32)', 'Create uninitialized array (fast, contents undefined).', true),
                        sug('np.full', Kind.Function, 'full(${1:shape}, ${2:fill_value}, dtype=np.float32)', 'Create array filled with a value.', true),
                        sug('np.linspace', Kind.Function, 'linspace(${1:start}, ${2:stop}, ${3:num})', 'Evenly spaced values over interval. Useful for frequency axes, LFO phases.', true),
                        sug('np.arange', Kind.Function, 'arange(${1:start}, ${2:stop}, ${3:step})', 'Evenly spaced values with step size.', true),
                        sug('np.copy', Kind.Function, 'copy(${1:array})', 'Copy an array.', true),

                        // Math ops
                        sug('np.clip', Kind.Function, 'clip(${1:array}, ${2:min}, ${3:max})', 'Clip values to range. Essential for preventing clipping/overflow.', true),
                        sug('np.abs', Kind.Function, 'abs(${1:array})', 'Element-wise absolute value.', true),
                        sug('np.sqrt', Kind.Function, 'sqrt(${1:array})', 'Element-wise square root.', true),
                        sug('np.exp', Kind.Function, 'exp(${1:array})', 'Element-wise exponential (e^x).', true),
                        sug('np.log', Kind.Function, 'log(${1:array})', 'Element-wise natural logarithm.', true),
                        sug('np.log10', Kind.Function, 'log10(${1:array})', 'Element-wise base-10 logarithm. Used for dB conversions.', true),
                        sug('np.power', Kind.Function, 'power(${1:base}, ${2:exponent})', 'Element-wise power.', true),
                        sug('np.maximum', Kind.Function, 'maximum(${1:a}, ${2:b})', 'Element-wise maximum of two arrays.', true),
                        sug('np.minimum', Kind.Function, 'minimum(${1:a}, ${2:b})', 'Element-wise minimum of two arrays.', true),
                        sug('np.where', Kind.Function, 'where(${1:condition}, ${2:x}, ${3:y})', 'Element-wise conditional: x where condition is true, y otherwise.', true),

                        // Trig (for oscillators, LFOs, modulation)
                        sug('np.sin', Kind.Function, 'sin(${1:array})', 'Element-wise sine. For oscillators: np.sin(2 * np.pi * freq * t)', true),
                        sug('np.cos', Kind.Function, 'cos(${1:array})', 'Element-wise cosine.', true),
                        sug('np.tanh', Kind.Function, 'tanh(${1:array})', 'Element-wise hyperbolic tangent. Useful for soft clipping/saturation.', true),

                        // Reductions
                        sug('np.sum', Kind.Function, 'sum(${1:array})', 'Sum of array elements.', true),
                        sug('np.mean', Kind.Function, 'mean(${1:array})', 'Mean of array elements.', true),
                        sug('np.max', Kind.Function, 'max(${1:array})', 'Maximum value in array.', true),
                        sug('np.min', Kind.Function, 'min(${1:array})', 'Minimum value in array.', true),

                        // Array manipulation
                        sug('np.roll', Kind.Function, 'roll(${1:array}, ${2:shift})', 'Roll array elements. Useful for circular buffer operations.', true),
                        sug('np.concatenate', Kind.Function, 'concatenate([${1:a}, ${2:b}])', 'Concatenate arrays along an axis.', true),
                        sug('np.multiply', Kind.Function, 'multiply(${1:a}, ${2:b})', 'Element-wise multiplication. Same as a * b.', true),
                        sug('np.convolve', Kind.Function, 'convolve(${1:signal}, ${2:kernel}, mode="${3:full}")', 'Convolution of two arrays. mode: "full", "same", or "valid".', true),

                        // Constants
                        sug('np.pi', Kind.Constant, 'pi', '3.14159... Used in angular frequency: w = 2 * np.pi * freq', false),
                        sug('np.float32', Kind.Constant, 'float32', 'Single-precision float type. ConjureDSP audio buffers are float32.', false),

                    ].map(s => ({ ...s, range })) };
                }

                // signal. completions (scipy.signal)
                if (textBefore.match(/\bsignal\.\w*$/)) {
                    return { suggestions: [
                        // Filter design
                        sug('signal.butter', Kind.Function,
                            'butter(${1:order}, ${2:cutoff_hz}, btype="${3:low}", fs=sample_rate, output="sos")',
                            'Butterworth filter design. Returns second-order sections (sos).\nbtype: "low", "high", "band", "bandstop"\nUse output="sos" for numerical stability.', true),
                        sug('signal.cheby1', Kind.Function,
                            'cheby1(${1:order}, ${2:ripple_db}, ${3:cutoff_hz}, btype="${4:low}", fs=sample_rate, output="sos")',
                            'Chebyshev type I filter. Sharper rolloff than Butterworth but has passband ripple.', true),
                        sug('signal.iirfilter', Kind.Function,
                            'iirfilter(${1:order}, ${2:cutoff_hz}, btype="${3:low}", ftype="${4:butter}", fs=sample_rate, output="sos")',
                            'General IIR filter design. ftype: "butter", "cheby1", "cheby2", "ellip", "bessel"', true),
                        sug('signal.firwin', Kind.Function,
                            'firwin(${1:num_taps}, ${2:cutoff_hz}, fs=sample_rate, pass_zero="${3:lowpass}")',
                            'FIR filter design using window method.\npass_zero: "lowpass", "highpass", "bandpass", "bandstop"', true),

                        // Filter application
                        sug('signal.sosfilt', Kind.Function,
                            'sosfilt(${1:sos}, ${2:signal})',
                            'Apply SOS filter to signal. Use with butter(..., output="sos").\nFor real-time: use sosfilt_zi for initial conditions.', true),
                        sug('signal.sosfilt_zi', Kind.Function,
                            'sosfilt_zi(${1:sos})',
                            'Initial conditions for sosfilt to avoid transient at start.\nzi = signal.sosfilt_zi(sos)\nout, zi = signal.sosfilt(sos, x, zi=zi)', true),
                        sug('signal.lfilter', Kind.Function,
                            'lfilter(${1:b}, ${2:a}, ${3:signal})',
                            'Apply IIR/FIR filter given b (numerator) and a (denominator) coefficients.', true),
                        sug('signal.convolve', Kind.Function,
                            'convolve(${1:signal}, ${2:kernel}, mode="${3:same}")',
                            'Convolve signal with kernel. mode: "full", "same", "valid"', true),
                        sug('signal.fftconvolve', Kind.Function,
                            'fftconvolve(${1:signal}, ${2:kernel}, mode="${3:same}")',
                            'FFT-based convolution. Faster than convolve for long kernels.', true),

                        // Analysis
                        sug('signal.stft', Kind.Function,
                            'stft(${1:signal}, fs=sample_rate, nperseg=${2:1024})',
                            'Short-time Fourier transform. Returns (frequencies, times, Zxx).', true),
                        sug('signal.hilbert', Kind.Function,
                            'hilbert(${1:signal})',
                            'Analytic signal via Hilbert transform. np.abs(result) gives envelope.', true),

                        // Windows
                        sug('signal.windows.hann', Kind.Function,
                            'windows.hann(${1:size})',
                            'Hann (Hanning) window. Common for FFT analysis.', true),
                        sug('signal.windows.hamming', Kind.Function,
                            'windows.hamming(${1:size})',
                            'Hamming window.', true),
                        sug('signal.windows.blackman', Kind.Function,
                            'windows.blackman(${1:size})',
                            'Blackman window. Better sidelobe rejection than Hann.', true),

                        // Resampling
                        sug('signal.resample', Kind.Function,
                            'resample(${1:signal}, ${2:num_samples})',
                            'Resample signal to a different number of samples using FFT method.', true),

                    ].map(s => ({ ...s, range })) };
                }

                // math. completions
                if (textBefore.match(/\bmath\.\w*$/)) {
                    return { suggestions: [
                        sug('math.exp', Kind.Function, 'exp(${1:x})', 'Exponential. Used for smoothing coefficients: exp(-2*pi*f/sr)', true),
                        sug('math.log', Kind.Function, 'log(${1:x})', 'Natural logarithm.', true),
                        sug('math.log10', Kind.Function, 'log10(${1:x})', 'Base-10 logarithm. For dB: 20*math.log10(amplitude)', true),
                        sug('math.sin', Kind.Function, 'sin(${1:x})', 'Sine (scalar). For arrays use np.sin.', true),
                        sug('math.cos', Kind.Function, 'cos(${1:x})', 'Cosine (scalar). For arrays use np.cos.', true),
                        sug('math.pi', Kind.Constant, 'pi', '3.14159... Angular frequency: w0 = 2*math.pi*freq/sr', false),
                        sug('math.sqrt', Kind.Function, 'sqrt(${1:x})', 'Square root (scalar).', true),
                        sug('math.pow', Kind.Function, 'pow(${1:base}, ${2:exp})', 'Power (scalar).', true),
                    ].map(s => ({ ...s, range })) };
                }

                // BiquadCoeffs. completions
                if (textBefore.match(/\bBiquadCoeffs\.\w*$/)) {
                    return { suggestions: biquadCoeffsStatics.map(m =>
                        sug('BiquadCoeffs.' + m.name, Kind.Function,
                            m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')',
                            m.doc, true)
                    ).map(s => ({ ...s, range })) };
                }

                // Biquad. instance methods (must be after BiquadCoeffs check)
                if (textBefore.match(/\bBiquad\.\w*$/) || textBefore.match(/(?:_filter|filter|filt|bq)\w*\.\w*$/)) {
                    return { suggestions: biquadMethods.map(m =>
                        sug(m.name, Kind.Method,
                            m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')',
                            m.doc, true)
                    ).map(s => ({ ...s, range })) };
                }

                // DelayLine. instance methods
                if (textBefore.match(/(?:\bDelayLine|_delay|delay_line|delay|dl)\w*\.\w*$/)) {
                    return { suggestions: [
                        ...delayLineMethods.map(m =>
                            sug(m.name, Kind.Method,
                                m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')',
                                m.doc, true)),
                        ...delayLineProperties.map(p =>
                            sug(p.name, Kind.Property, p.name, p.doc, false)),
                    ].map(s => ({ ...s, range })) };
                }

                // LFO. instance methods
                if (textBefore.match(/(?:\bLFO|_lfo|lfo)\w*\.\w*$/)) {
                    return { suggestions: [
                        ...lfoMethodsPython.map(m =>
                            sug(m.name, Kind.Method,
                                m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')',
                                m.doc, true)),
                        ...lfoProperties.map(p =>
                            sug(p.name, Kind.Property, p.name, p.doc, false)),
                    ].map(s => ({ ...s, range })) };
                }

                return { suggestions: [] };
            },
        });

        // ── Rust/WASM DSP completions ──────────────────────────────
        monaco.languages.registerCompletionItemProvider('rust', {
            provideCompletionItems(model, position) {
                const word = model.getWordUntilPosition(position);
                const range = {
                    startLineNumber: position.lineNumber,
                    endLineNumber: position.lineNumber,
                    startColumn: word.startColumn,
                    endColumn: word.endColumn,
                };
                return { suggestions: [
                    // ── conjuredsp library ──
                    sug('setup', Kind.Snippet,
                        'use conjuredsp::*;\nsetup!();\n',
                        'ConjureDSP boilerplate — declares buffers, exports, transport, and ctx() helper.\nReplaces manual INPUT_BUF/OUTPUT_BUF/PARAMS_BUF declarations and get_*_ptr() exports.',
                        true),

                    sug('params', Kind.Snippet,
                        [
                            'params! {',
                            '\t${1:CUTOFF} = freq(),',
                            '\t${2:MIX} = mix(),',
                            '}',
                        ].join('\n'),
                        'Declare parameter metadata. Generates index constants, METADATA JSON, and exports.\n' +
                        'Builders: freq(), db(), time_ms(), mix(), pct(), toggle(), ratio(), param(min, max)\n' +
                        'Customize with .min(), .max(), .default(), .unit(), .curve()',
                        true),

                    sug('process (conjuredsp)', Kind.Function,
                        [
                            '#[no_mangle]',
                            'pub extern "C" fn process(',
                            '\tinput: *const f32,',
                            '\toutput: *mut f32,',
                            '\tchannels: i32,',
                            '\tframe_count: i32,',
                            '\tsample_rate: f32,',
                            ') {',
                            '\tlet ctx = ctx(input, output, channels, frame_count, sample_rate);',
                            '',
                            '\tfor c in 0..ctx.channels() {',
                            '\t\tfor i in 0..ctx.frames() {',
                            '\t\t\tctx.set_output(c, i, ctx.input(c, i));${0}',
                            '\t\t}',
                            '\t}',
                            '}',
                        ].join('\n'),
                        'Process function using ctx() for safe buffer access.\n' +
                        'Requires setup!() to be called first.',
                        true),

                    sug('freq', Kind.Function, 'freq()', 'Frequency param: 20–20000 Hz, log curve. Customize with .min()/.max()/.default()', true),
                    sug('db', Kind.Function, 'db()', 'Decibel param: -60 to +12 dB. Customize with .min()/.max()/.default()', true),
                    sug('time_ms', Kind.Function, 'time_ms()', 'Time param: 0.1–1000 ms, log curve. Customize with .min()/.max()/.default()', true),
                    sug('mix', Kind.Function, 'mix()', 'Wet/dry mix param: 0.0–1.0, default 0.5', true),
                    sug('pct', Kind.Function, 'pct()', 'Percentage param: 0–100%', true),
                    sug('toggle', Kind.Function, 'toggle()', 'On/off toggle param: 0 or 1', true),
                    sug('ratio', Kind.Function, 'ratio()', 'Compression ratio: 1–20 :1', true),

                    sug('db_to_gain', Kind.Function, 'db_to_gain(${1:db_val} as f64)', 'Convert dB to linear gain. 0 dB = 1.0', true),
                    sug('gain_to_db', Kind.Function, 'gain_to_db(${1:gain_val})', 'Convert linear gain to dB.', true),
                    sug('ms_to_samples', Kind.Function, 'ms_to_samples(${1:ms} as f64, ${2:sample_rate} as f64)', 'Convert ms to sample count.', true),
                    sug('smooth_coeff', Kind.Function, 'smooth_coeff(${1:time_ms} as f64, ${2:sample_rate} as f64)', 'One-pole smoothing coefficient from ms time constant.', true),
                    sug('soft_clip', Kind.Function, 'soft_clip(${1:x}, ${2:1.0})', 'Soft clip via tanh saturation.', true),
                    sug('crossfade', Kind.Function, 'crossfade(${1:dry}, ${2:wet}, ${3:mix_val})', 'Linear crossfade. mix=0 dry, mix=1 wet.', true),

                    sug('Biquad', Kind.Snippet,
                        [
                            'static mut FILTERS: [Biquad; MAX_CH] = [Biquad::new(); MAX_CH];',
                            '',
                            '// In process():',
                            'let coeffs = BiquadCoeffs::lowpass(${1:cutoff_hz} as f64, ${2:0.707}, ctx.sample_rate() as f64);',
                            'unsafe {',
                            '\tfor c in 0..ctx.channels() {',
                            '\t\tFILTERS[c].set_coeffs(coeffs);',
                            '\t\tfor i in 0..ctx.frames() {',
                            '\t\t\tlet x = ctx.input(c, i) as f64;',
                            '\t\t\tlet y = FILTERS[c].process_sample(x);',
                            '\t\t\tctx.set_output(c, i, y as f32);',
                            '\t\t}',
                            '\t}',
                            '}',
                        ].join('\n'),
                        'Biquad filter with per-channel state.\n' +
                        'Types: lowpass, highpass, bandpass, notch, peak, lowshelf, highshelf, allpass.',
                        true),

                    sug('DelayLine', Kind.Snippet,
                        [
                            'static mut DELAYS: [DelayLine<${1:48000}>; MAX_CH] = [DelayLine::new(); MAX_CH];',
                            'static mut WRITE_POS: usize = 0;',
                        ].join('\n'),
                        'Circular delay buffer.\n' +
                        'Methods: write(sample), read(delay_samples), read_cubic(delay_samples), tap(n), clear().',
                        true),

                    sug('Lfo', Kind.Snippet,
                        [
                            'static mut LFO: Lfo = Lfo::new();',
                            '',
                            '// In process():',
                            'unsafe {',
                            '\tLFO.init(ctx.sample_rate() as f64, ${1:rate_hz} as f64);',
                            '\tfor i in 0..ctx.frames() {',
                            '\t\tlet mod_val = LFO.tick();',
                            '\t\t${0:// use mod_val}',
                            '\t}',
                            '}',
                        ].join('\n'),
                        'Low-frequency oscillator. Waveforms: Sine, Triangle, Saw, Square.\n' +
                        'set_waveform(Waveform::Triangle) to change.',
                        true),

                    // ── Legacy manual boilerplate (still works without conjuredsp) ──
                    sug('process', Kind.Function,
                        [
                            '#[no_mangle]',
                            'pub extern "C" fn process(',
                            '\tinput: *const f32,',
                            '\toutput: *mut f32,',
                            '\tchannels: i32,',
                            '\tframe_count: i32,',
                            '\tsample_rate: f32,',
                            ') {',
                            '\tlet ch = channels as usize;',
                            '\tlet frames = frame_count as usize;',
                            '',
                            '\tunsafe {',
                            '\t\tlet inp = std::slice::from_raw_parts(input, ch * frames);',
                            '\t\tlet out = std::slice::from_raw_parts_mut(output, ch * frames);',
                            '',
                            '\t\tfor c in 0..ch {',
                            '\t\t\tfor i in 0..frames {',
                            '\t\t\t\tlet idx = c * frames + i;',
                            '\t\t\t\tout[idx] = inp[idx];${0}',
                            '\t\t\t}',
                            '\t\t}',
                            '\t}',
                            '}',
                        ].join('\n'),
                        'ConjureDSP WASM process function.\n\n' +
                        'Buffer layout: interleaved per-channel, idx = channel * frames + sample.\n' +
                        'PARAMS_BUF contains denormalized values (if METADATA defined).',
                        true),

                    sug('WASM boilerplate', Kind.Snippet,
                        [
                            'const MAX_CH: usize = 2;',
                            'const MAX_FR: usize = 4096;',
                            '',
                            'static mut INPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];',
                            'static mut OUTPUT_BUF: [f32; MAX_CH * MAX_FR] = [0.0; MAX_CH * MAX_FR];',
                            'static mut PARAMS_BUF: [f32; 16] = [0.0; 16];',
                            '',
                            '#[no_mangle]',
                            'pub extern "C" fn get_input_ptr() -> i32 {',
                            '\tunsafe { INPUT_BUF.as_ptr() as i32 }',
                            '}',
                            '',
                            '#[no_mangle]',
                            'pub extern "C" fn get_output_ptr() -> i32 {',
                            '\tunsafe { OUTPUT_BUF.as_ptr() as i32 }',
                            '}',
                            '',
                            '#[no_mangle]',
                            'pub extern "C" fn get_params_ptr() -> i32 {',
                            '\tunsafe { PARAMS_BUF.as_ptr() as i32 }',
                            '}',
                        ].join('\n'),
                        'Standard WASM buffer exports. Required for ConjureDSP to pass audio data to your process() function.',
                        true),

                    sug('METADATA', Kind.Variable,
                        [
                            'static METADATA: &str = r#"[',
                            '\t{"name":"${1:Cutoff}","min":${2:20.0},"max":${3:20000.0},"unit":"${4:Hz}","default":${5:1000.0},"curve":"${6:log}"},',
                            '\t{"name":"${7:Mix}","min":${8:0.0},"max":${9:1.0},"unit":"${10:}","default":${11:0.5}}',
                            ']"#;',
                            '',
                            '#[no_mangle]',
                            'pub extern "C" fn get_param_metadata_ptr() -> i32 {',
                            '\tMETADATA.as_ptr() as i32',
                            '}',
                            '',
                            '#[no_mangle]',
                            'pub extern "C" fn get_param_metadata_len() -> i32 {',
                            '\tMETADATA.len() as i32',
                            '}',
                        ].join('\n'),
                        'Parameter metadata JSON with WASM export functions.\n' +
                        'Fields: name, min, max, unit, default, curve ("log" or omit for linear)',
                        true),

                    sug('PARAMS_BUF', Kind.Variable,
                        [
                            'static mut PARAMS_BUF: [f32; 16] = [0.0; 16];',
                            '',
                            '#[no_mangle]',
                            'pub extern "C" fn get_params_ptr() -> i32 {',
                            '\tunsafe { PARAMS_BUF.as_ptr() as i32 }',
                            '}',
                        ].join('\n'),
                        'Parameter buffer with WASM pointer export. Host writes denormalized values here before each process() call.',
                        true),

                    sug('param const', Kind.Snippet,
                        'const ${1:CUTOFF}: usize = ${2:0};',
                        'Named parameter index constant. Use with PARAMS_BUF[CUTOFF].',
                        true),

                    // ── Persistent state ──
                    sug('state (per-channel)', Kind.Snippet,
                        [
                            '// Persistent state across process() calls (one value per channel)',
                            'static mut ${1:PREV_OUT}: [f64; MAX_CH] = [0.0; MAX_CH];',
                        ].join('\n'),
                        'Per-channel state array. Use f64 for precision in feedback loops.',
                        true),

                    sug('state (scalar)', Kind.Snippet,
                        [
                            '// Persistent state across process() calls',
                            'static mut ${1:ENVELOPE}: f64 = 0.0;',
                        ].join('\n'),
                        'Scalar persistent state. Use f64 for precision in feedback loops.',
                        true),

                    // ── DSP patterns ──
                    sug('delay line', Kind.Snippet,
                        [
                            'const MAX_DELAY: usize = 48000; // supports 500 ms at 96 kHz',
                            'static mut DELAY_BUF: [[f32; MAX_DELAY]; MAX_CH] = [[0.0; MAX_DELAY]; MAX_CH];',
                            'static mut WRITE_POS: usize = 0;',
                            '',
                            '// Inside process() unsafe block:',
                            'let delay_ms = PARAMS_BUF[${1:TIME}];',
                            'let feedback = PARAMS_BUF[${2:FEEDBACK}];',
                            'let mix = PARAMS_BUF[${3:MIX}];',
                            'let mut delay_samples = (delay_ms * 0.001 * sample_rate) as usize;',
                            'if delay_samples >= MAX_DELAY { delay_samples = MAX_DELAY - 1; }',
                            '',
                            'let mut wp = WRITE_POS;',
                            'for i in 0..frames {',
                            '\tlet rp = (wp + MAX_DELAY - delay_samples) % MAX_DELAY;',
                            '\tfor c in 0..ch {',
                            '\t\tlet idx = c * frames + i;',
                            '\t\tlet delayed = DELAY_BUF[c][rp];',
                            '\t\tDELAY_BUF[c][wp] = inp[idx] + delayed * feedback;',
                            '\t\tout[idx] = inp[idx] * (1.0 - mix) + delayed * mix;',
                            '\t}',
                            '\twp = (wp + 1) % MAX_DELAY;',
                            '}',
                            'WRITE_POS = wp;',
                        ].join('\n'),
                        'Delay line with feedback. Common pattern for echo, chorus, flanger.\n' +
                        'Requires MAX_CH, DELAY_BUF, and WRITE_POS statics.',
                        true),

                    sug('biquad', Kind.Snippet,
                        [
                            '// Biquad filter state (2 samples of history per channel)',
                            'static mut X1: [f64; MAX_CH] = [0.0; MAX_CH];',
                            'static mut X2: [f64; MAX_CH] = [0.0; MAX_CH];',
                            'static mut Y1: [f64; MAX_CH] = [0.0; MAX_CH];',
                            'static mut Y2: [f64; MAX_CH] = [0.0; MAX_CH];',
                            '',
                            '// Inside process() unsafe block:',
                            'let sr = sample_rate as f64;',
                            'let cutoff_hz = PARAMS_BUF[${1:CUTOFF}] as f64;',
                            'let q = ${2:0.707_f64}; // Q factor (0.707 = Butterworth)',
                            'let two_pi = 2.0 * core::f64::consts::PI;',
                            '',
                            '// Low-pass biquad coefficients',
                            'let w0 = two_pi * cutoff_hz / sr;',
                            'let alpha = w0.sin() / (2.0 * q);',
                            'let cos_w0 = w0.cos();',
                            'let b0 = (1.0 - cos_w0) / 2.0;',
                            'let b1 = 1.0 - cos_w0;',
                            'let b2 = b0;',
                            'let a0 = 1.0 + alpha;',
                            'let a1 = -2.0 * cos_w0;',
                            'let a2 = 1.0 - alpha;',
                            '// Normalize',
                            'let (b0, b1, b2) = (b0/a0, b1/a0, b2/a0);',
                            'let (a1, a2) = (a1/a0, a2/a0);',
                            '',
                            'for c in 0..ch {',
                            '\tlet (mut x1, mut x2) = (X1[c], X2[c]);',
                            '\tlet (mut y1, mut y2) = (Y1[c], Y2[c]);',
                            '\tfor i in 0..frames {',
                            '\t\tlet idx = c * frames + i;',
                            '\t\tlet x0 = inp[idx] as f64;',
                            '\t\tlet y0 = b0*x0 + b1*x1 + b2*x2 - a1*y1 - a2*y2;',
                            '\t\tout[idx] = y0 as f32;',
                            '\t\tx2 = x1; x1 = x0; y2 = y1; y1 = y0;',
                            '\t}',
                            '\tX1[c] = x1; X2[c] = x2; Y1[c] = y1; Y2[c] = y2;',
                            '}',
                        ].join('\n'),
                        'Biquad filter (2nd-order IIR). Low-pass shown; change coefficients for HP/BP/notch.\n' +
                        'Uses f64 for precision in the feedback loop.',
                        true),

                    sug('envelope follower', Kind.Snippet,
                        [
                            'static mut ENVELOPE: f64 = 0.0;',
                            '',
                            '// Inside process() unsafe block:',
                            'let sr = sample_rate as f64;',
                            'let attack_ms = PARAMS_BUF[${1:ATTACK}] as f64;',
                            'let release_ms = PARAMS_BUF[${2:RELEASE}] as f64;',
                            'let attack_coeff = (-1.0 / (attack_ms * 0.001 * sr)).exp();',
                            'let release_coeff = (-1.0 / (release_ms * 0.001 * sr)).exp();',
                            'let mut env = ENVELOPE;',
                            '',
                            'for i in 0..frames {',
                            '\tlet mut peak: f64 = 0.0;',
                            '\tfor c in 0..ch {',
                            '\t\tlet abs_val = (inp[c * frames + i] as f64).abs();',
                            '\t\tif abs_val > peak { peak = abs_val; }',
                            '\t}',
                            '\tif peak > env {',
                            '\t\tenv = attack_coeff * env + (1.0 - attack_coeff) * peak;',
                            '\t} else {',
                            '\t\tenv = release_coeff * env + (1.0 - release_coeff) * peak;',
                            '\t}',
                            '\t${0:// Use env for gain control}',
                            '}',
                            'ENVELOPE = env;',
                        ].join('\n'),
                        'Peak-detecting envelope follower with attack/release.\n' +
                        'Useful for compressors, gates, ducking. Linked across channels.',
                        true),

                    sug('one-pole lowpass', Kind.Snippet,
                        [
                            '// Simple 1-pole IIR low-pass: y[n] = b*x[n] + a*y[n-1]',
                            'static mut PREV_OUT: [f64; MAX_CH] = [0.0; MAX_CH];',
                            '',
                            '// Inside process() unsafe block:',
                            'let sr = sample_rate as f64;',
                            'let cutoff_hz = PARAMS_BUF[${1:CUTOFF}] as f64;',
                            'let two_pi = 2.0 * core::f64::consts::PI;',
                            'let a = (-two_pi * cutoff_hz / sr).exp();',
                            'let b = 1.0 - a;',
                            '',
                            'for c in 0..ch {',
                            '\tlet mut y = PREV_OUT[c];',
                            '\tfor i in 0..frames {',
                            '\t\tlet idx = c * frames + i;',
                            '\t\ty = b * inp[idx] as f64 + a * y;',
                            '\t\tout[idx] = y as f32;',
                            '\t}',
                            '\tPREV_OUT[c] = y;',
                            '}',
                        ].join('\n'),
                        'Simple 1-pole low-pass filter. 6 dB/octave rolloff.\n' +
                        'Good for parameter smoothing or gentle filtering.',
                        true),

                    // ── Common DSP math ──
                    sug('db_to_lin', Kind.Function,
                        [
                            'fn db_to_lin(db: f64) -> f64 {',
                            '\t(10.0_f64).powf(db / 20.0)',
                            '}',
                        ].join('\n'),
                        'Convert decibels to linear amplitude. 0 dB = 1.0, -6 dB ≈ 0.5',
                        true),

                    sug('lin_to_db', Kind.Function,
                        [
                            'fn lin_to_db(lin: f64) -> f64 {',
                            '\t20.0 * (lin + 1e-30).log10()',
                            '}',
                        ].join('\n'),
                        'Convert linear amplitude to decibels. 1e-30 prevents log(0).',
                        true),

                    sug('smoothing coeff', Kind.Snippet,
                        'let ${1:coeff} = (-2.0 * core::f64::consts::PI * ${2:cutoff_hz} as f64 / sample_rate as f64).exp();',
                        'One-pole smoothing coefficient from cutoff frequency.\nUse as: y = coeff * y + (1.0 - coeff) * x',
                        true),

                    sug('soft clip (tanh)', Kind.Snippet,
                        [
                            '// Soft clipping via tanh saturation',
                            'let drive = PARAMS_BUF[${1:DRIVE}];',
                            'for c in 0..ch {',
                            '\tfor i in 0..frames {',
                            '\t\tlet idx = c * frames + i;',
                            '\t\tout[idx] = (inp[idx] * drive).tanh();',
                            '\t}',
                            '}',
                        ].join('\n'),
                        'Soft clipping using hyperbolic tangent. Drive controls saturation amount.',
                        true),

                    // ── Missing DSP function completions ──
                    sug('samples_to_ms', Kind.Function,
                        'samples_to_ms(${1:samples} as usize, ${2:sample_rate} as f64)',
                        'Convert sample count to milliseconds.', true),
                    sug('freq_to_period', Kind.Function,
                        'freq_to_period(${1:freq} as f64, ${2:sample_rate} as f64)',
                        'Convert frequency (Hz) to period in samples.', true),
                    sug('lerp', Kind.Function,
                        'lerp(${1:a}, ${2:b}, ${3:t})',
                        'Linear interpolation. t=0 → a, t=1 → b.', true),

                    // ── latency! macro ──
                    sug('latency', Kind.Snippet,
                        'latency!(${1:256});',
                        'Declare algorithmic latency in samples for DAW delay compensation.\nGenerates get_latency_samples() WASM export.\nUse for lookahead, FFT windowing, oversampling. NOT for creative delays.',
                        true),

                    // ── Waveform enum ──
                    sug('Waveform', Kind.Snippet,
                        'Waveform::${1|Sine,Triangle,Saw,Square|}',
                        'Waveform variant for Lfo::set_waveform().',
                        true),

                    // ── Stateless oscillator functions ──
                    sug('sine', Kind.Function, 'sine(${1:phase})',
                        'Sine wave from phase [0, 1). Returns [-1, 1].', true),
                    sug('triangle', Kind.Function, 'triangle(${1:phase})',
                        'Triangle wave from phase [0, 1). Returns [-1, 1].', true),
                    sug('saw', Kind.Function, 'saw(${1:phase})',
                        'Sawtooth wave from phase [0, 1). Returns [-1, 1].', true),
                    sug('advance_phase', Kind.Function, 'advance_phase(${1:phase}, ${2:freq}, ${3:sample_rate})',
                        'Advance phase by one sample with wrapping.', true),

                ].map(s => ({ ...s, range })) };
            },
        });

        // ── Rust: dot and :: completions ──────────────────────────────
        monaco.languages.registerCompletionItemProvider('rust', {
            triggerCharacters: ['.', ':'],
            provideCompletionItems(model, position) {
                const lineContent = model.getLineContent(position.lineNumber);
                const textBefore = lineContent.substring(0, position.column - 1);

                const word = model.getWordUntilPosition(position);
                const range = {
                    startLineNumber: position.lineNumber,
                    endLineNumber: position.lineNumber,
                    startColumn: word.startColumn,
                    endColumn: word.endColumn,
                };

                // BiquadCoeffs:: associated functions
                if (textBefore.match(/\bBiquadCoeffs::\w*$/)) {
                    return { suggestions: biquadCoeffsStatics.map(m =>
                        sug('BiquadCoeffs::' + m.name, Kind.Function,
                            m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')',
                            m.doc, true)
                    ).map(s => ({ ...s, range })) };
                }

                // Biquad:: associated functions
                if (textBefore.match(/\bBiquad::\w*$/)) {
                    return { suggestions: [
                        sug('Biquad::new', Kind.Function, 'new()', 'Create a passthrough biquad filter.', true),
                    ].map(s => ({ ...s, range })) };
                }

                // DelayLine:: associated functions
                if (textBefore.match(/\bDelayLine::\w*$/)) {
                    return { suggestions: [
                        sug('DelayLine::new', Kind.Function, 'new()', 'Create a zeroed delay line.', true),
                    ].map(s => ({ ...s, range })) };
                }

                // Lfo:: associated functions
                if (textBefore.match(/\bLfo::\w*$/)) {
                    return { suggestions: [
                        sug('Lfo::new', Kind.Function, 'new()', 'Create LFO (1 Hz sine, 44100 Hz sample rate).', true),
                    ].map(s => ({ ...s, range })) };
                }

                // Waveform:: enum variants
                if (textBefore.match(/\bWaveform::\w*$/)) {
                    return { suggestions: waveformVariants.map(v =>
                        sug('Waveform::' + v.name, Kind.Enum, v.name, v.doc, false)
                    ).map(s => ({ ...s, range })) };
                }

                // ctx. methods (Context)
                if (textBefore.match(/\bctx\.\w*$/)) {
                    return { suggestions: ctxMethods.map(m =>
                        sug('ctx.' + m.name, Kind.Method,
                            m.params ? m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')' : m.name + '()',
                            m.doc, true)
                    ).map(s => ({ ...s, range })) };
                }

                // Biquad instance methods (filter., filt., bq., FILTER.)
                if (textBefore.match(/(?:filter|filt|biquad|FILTER)\w*\.\w*$/) && !textBefore.match(/BiquadCoeffs/)) {
                    return { suggestions: biquadMethods.map(m =>
                        sug(m.name, Kind.Method,
                            m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')',
                            m.doc, true)
                    ).map(s => ({ ...s, range })) };
                }

                // DelayLine instance methods (delay., dl., DELAY.)
                if (textBefore.match(/(?:delay|dl|DELAY)\w*\.\w*$/) && !textBefore.match(/DelayLine::/)) {
                    return { suggestions: [
                        ...delayLineMethods.map(m =>
                            sug(m.name, Kind.Method,
                                m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')',
                                m.doc, true)),
                    ].map(s => ({ ...s, range })) };
                }

                // Lfo instance methods (lfo., LFO.)
                if (textBefore.match(/(?:lfo|LFO)\w*\.\w*$/) && !textBefore.match(/Lfo::/)) {
                    return { suggestions: [
                        ...lfoMethods.map(m =>
                            sug(m.name, Kind.Method,
                                m.name + '(' + m.params.map((p, i) => '${' + (i+1) + ':' + p.label + '}').join(', ') + ')',
                                m.doc, true)),
                        ...lfoProperties.map(p =>
                            sug(p.name, Kind.Property, p.name, p.doc, false)),
                    ].map(s => ({ ...s, range })) };
                }

                // ParamSpec chain methods (after param builder calls like freq()., db()., param(0,1).)
                if (textBefore.match(/\)\.\w*$/)) {
                    return { suggestions: paramSpecChainMethods.map(m =>
                        sug('.' + m.name, Kind.Method, m.insert, m.doc, true)
                    ).map(s => ({ ...s, range })) };
                }

                return { suggestions: [] };
            },
        });

        // ── Python: Signature help ──────────────────────────────────
        monaco.languages.registerSignatureHelpProvider('python', {
            signatureHelpTriggerCharacters: ['(', ','],
            provideSignatureHelp(model, position) {
                const lineContent = model.getLineContent(position.lineNumber);
                const funcName = extractFuncBeforeParen(lineContent, position.column);
                if (!funcName) return null;

                // Try exact match, then last segment (for method calls like obj.method)
                const sig = pySignatures[funcName] || pySignatures[funcName.split('.').pop()];
                if (!sig) return null;

                const activeParameter = countCommas(lineContent, position.column);
                return {
                    value: {
                        signatures: [{
                            label: sig.label,
                            documentation: sig.doc,
                            parameters: sig.params.map(p => ({
                                label: p.label,
                                documentation: p.doc,
                            })),
                        }],
                        activeSignature: 0,
                        activeParameter: Math.min(activeParameter, sig.params.length - 1),
                    },
                    dispose() {},
                };
            },
        });

        // ── Rust: Signature help ────────────────────────────────────
        monaco.languages.registerSignatureHelpProvider('rust', {
            signatureHelpTriggerCharacters: ['(', ','],
            provideSignatureHelp(model, position) {
                const lineContent = model.getLineContent(position.lineNumber);
                const funcName = extractFuncBeforeParen(lineContent, position.column);
                if (!funcName) return null;

                // Try exact match, then normalize :: to . for lookup, then last segment
                const sig = rustSignatures[funcName]
                    || rustSignatures[funcName.replace(/::/g, '.')]
                    || rustSignatures[funcName.split(/[.:]+/).pop()];
                if (!sig) return null;

                const activeParameter = countCommas(lineContent, position.column);
                return {
                    value: {
                        signatures: [{
                            label: sig.label,
                            documentation: sig.doc,
                            parameters: sig.params.map(p => ({
                                label: p.label,
                                documentation: p.doc,
                            })),
                        }],
                        activeSignature: 0,
                        activeParameter: Math.min(activeParameter, sig.params.length - 1),
                    },
                    dispose() {},
                };
            },
        });

        // ── Python: Hover provider ──────────────────────────────────
        monaco.languages.registerHoverProvider('python', {
            provideHover(model, position) {
                const wordInfo = model.getWordAtPosition(position);
                if (!wordInfo) return null;
                const doc = pyHoverDocs[wordInfo.word];
                if (!doc) return null;
                return {
                    range: new monaco.Range(position.lineNumber, wordInfo.startColumn, position.lineNumber, wordInfo.endColumn),
                    contents: [{ value: doc }],
                };
            },
        });

        // ── Rust: Hover provider ────────────────────────────────────
        monaco.languages.registerHoverProvider('rust', {
            provideHover(model, position) {
                const wordInfo = model.getWordAtPosition(position);
                if (!wordInfo) return null;
                const doc = rustHoverDocs[wordInfo.word];
                if (!doc) return null;
                return {
                    range: new monaco.Range(position.lineNumber, wordInfo.startColumn, position.lineNumber, wordInfo.endColumn),
                    contents: [{ value: doc }],
                };
            },
        });
    },
};

// Auto-initialize when the page loads
window.addEventListener('DOMContentLoaded', () => {
    // Swift will call bridge.init() via evaluateJavaScript after setting options
    // But we expose bridge globally so Swift can call it
    window.bridge = bridge;
});
