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
            });

            this._changeListener = this.editor.onDidChangeModelContent(() => {
                if (this._suppressChanges) return;
                webkit.messageHandlers.contentChanged.postMessage(
                    this.editor.getValue()
                );
            });

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

                    // ── Imports ──
                    sug('import numpy', Kind.Module,
                        'import numpy as np',
                        'Import numpy (pre-installed in ConjureDSP runtime)', false),

                    sug('import math', Kind.Module,
                        'import math',
                        'Import Python math module', false),

                    sug('from scipy import signal', Kind.Module,
                        'from scipy import signal',
                        'Import scipy.signal for DSP filters (pre-installed in ConjureDSP runtime)', false),

                    sug('from scipy.fft import rfft', Kind.Module,
                        'from scipy.fft import rfft, irfft, rfftfreq',
                        'Import scipy FFT functions', false),

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
                    // ── ConjureDSP WASM boilerplate ──
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

                ].map(s => ({ ...s, range })) };
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
