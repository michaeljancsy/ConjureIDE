// Monaco Editor <-> Swift bridge for BearBone
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
        monaco.editor.setModelMarkers(model, 'bearbone', monacoMarkers);
    },

    clearMarkers() {
        if (!this.editor) return;
        const model = this.editor.getModel();
        if (model) {
            monaco.editor.setModelMarkers(model, 'bearbone', []);
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

        // ── Python: BearBone DSP snippets ──────────────────────────
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
                    // ── BearBone API ──
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
                        'BearBone DSP process function. Called each render callback.\n\n' +
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
                        'Import numpy (pre-installed in BearBone runtime)', false),

                    sug('import math', Kind.Module,
                        'import math',
                        'Import Python math module', false),

                    sug('from scipy import signal', Kind.Module,
                        'from scipy import signal',
                        'Import scipy.signal for DSP filters (pre-installed in BearBone runtime)', false),

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
                        sug('np.float32', Kind.Constant, 'float32', 'Single-precision float type. BearBone audio buffers are float32.', false),

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
                    sug('process', Kind.Function,
                        [
                            '#[unsafe(no_mangle)]',
                            'pub extern "C" fn process(',
                            '\tinputs: *const *const f32,',
                            '\toutputs: *mut *mut f32,',
                            '\tnum_channels: u32,',
                            '\tframe_count: u32,',
                            '\tsample_rate: f32,',
                            ') {',
                            '\tlet frame_count = frame_count as usize;',
                            '\tlet num_channels = num_channels as usize;',
                            '\tfor ch in 0..num_channels {',
                            '\t\tlet input = unsafe { std::slice::from_raw_parts(*inputs.add(ch), frame_count) };',
                            '\t\tlet output = unsafe { std::slice::from_raw_parts_mut(*outputs.add(ch), frame_count) };',
                            '\t\tfor i in 0..frame_count {',
                            '\t\t\toutput[i] = input[i];${0}',
                            '\t\t}',
                            '\t}',
                            '}',
                        ].join('\n'),
                        'BearBone WASM DSP process function with safe slice wrappers.',
                        true),

                    sug('METADATA', Kind.Variable,
                        [
                            'static METADATA: &str = r#"[',
                            '\t{"name":"${1:Cutoff}","min":${2:20},"max":${3:20000},"unit":"${4:Hz}","default":${5:1000},"curve":"${6:log}"},',
                            '\t{"name":"${7:Mix}","min":${8:0},"max":${9:1},"unit":"${10:}","default":${11:0.5}}',
                            ']"#;',
                            '',
                            '#[unsafe(no_mangle)]',
                            'pub extern "C" fn get_param_metadata_json() -> *const u8 { METADATA.as_ptr() }',
                            '#[unsafe(no_mangle)]',
                            'pub extern "C" fn get_param_metadata_len() -> usize { METADATA.len() }',
                        ].join('\n'),
                        'Parameter metadata JSON with export functions for BearBone WASM.\n' +
                        'Fields: name, min, max, unit, default, curve ("log" or omit for linear)',
                        true),

                    sug('PARAMS_BUF', Kind.Variable,
                        [
                            'const MAX_PARAMS: usize = 16;',
                            'static mut PARAMS_BUF: [f32; MAX_PARAMS] = [0.0; MAX_PARAMS];',
                            '',
                            '#[unsafe(no_mangle)]',
                            'pub extern "C" fn get_params_ptr() -> *mut f32 {',
                            '\tunsafe { PARAMS_BUF.as_mut_ptr() }',
                            '}',
                        ].join('\n'),
                        'Parameter buffer with pointer export. Host writes denormalized values here before each process() call.',
                        true),

                    sug('state', Kind.Snippet,
                        [
                            '// Persistent state across process() calls',
                            'static mut ${1:STATE}: [f32; ${2:2}] = [0.0; ${2:2}];',
                        ].join('\n'),
                        'Static mutable state that persists between render callbacks.',
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
