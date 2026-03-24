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
        // Python DSP completions
        monaco.languages.registerCompletionItemProvider('python', {
            provideCompletionItems(model, position) {
                const word = model.getWordUntilPosition(position);
                const range = {
                    startLineNumber: position.lineNumber,
                    endLineNumber: position.lineNumber,
                    startColumn: word.startColumn,
                    endColumn: word.endColumn,
                };
                return {
                    suggestions: [
                        {
                            label: 'process',
                            kind: monaco.languages.CompletionItemKind.Function,
                            insertText: 'def process(inputs, outputs, frame_count, sample_rate, params):\n\t${0:pass}',
                            insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
                            documentation: 'BearBone DSP process function. Called each render callback.',
                            range,
                        },
                        {
                            label: 'PARAMS',
                            kind: monaco.languages.CompletionItemKind.Variable,
                            insertText: 'PARAMS = {\n\t"${1:name}": {"min": ${2:0}, "max": ${3:1}, "unit": "${4:}", "default": ${5:0.5}},\n}',
                            insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
                            documentation: 'Parameter metadata dict. Defines AU parameters with ranges and units.',
                            range,
                        },
                        {
                            label: 'numpy',
                            kind: monaco.languages.CompletionItemKind.Module,
                            insertText: 'import numpy as np',
                            documentation: 'Import numpy (pre-installed in BearBone runtime)',
                            range,
                        },
                        {
                            label: 'scipy.signal',
                            kind: monaco.languages.CompletionItemKind.Module,
                            insertText: 'from scipy import signal',
                            documentation: 'Import scipy.signal for DSP filters',
                            range,
                        },
                    ],
                };
            },
        });

        // Rust/WASM DSP completions
        monaco.languages.registerCompletionItemProvider('rust', {
            provideCompletionItems(model, position) {
                const word = model.getWordUntilPosition(position);
                const range = {
                    startLineNumber: position.lineNumber,
                    endLineNumber: position.lineNumber,
                    startColumn: word.startColumn,
                    endColumn: word.endColumn,
                };
                return {
                    suggestions: [
                        {
                            label: 'process',
                            kind: monaco.languages.CompletionItemKind.Function,
                            insertText: [
                                '#[unsafe(no_mangle)]',
                                'pub extern "C" fn process(',
                                '\tinputs: *const *const f32,',
                                '\toutputs: *mut *mut f32,',
                                '\tnum_channels: u32,',
                                '\tframe_count: u32,',
                                '\tsample_rate: f32,',
                                ') {',
                                '\t${0}',
                                '}',
                            ].join('\n'),
                            insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
                            documentation: 'BearBone WASM DSP process function.',
                            range,
                        },
                        {
                            label: 'METADATA',
                            kind: monaco.languages.CompletionItemKind.Variable,
                            insertText: [
                                'static METADATA: &str = r#"[',
                                '\t{"name":"${1:Param}","min":${2:0},"max":${3:1},"unit":"${4:}","default":${5:0.5}}',
                                ']"#;',
                                '',
                                '#[unsafe(no_mangle)]',
                                'pub extern "C" fn get_param_metadata_json() -> *const u8 { METADATA.as_ptr() }',
                                '#[unsafe(no_mangle)]',
                                'pub extern "C" fn get_param_metadata_len() -> usize { METADATA.len() }',
                            ].join('\n'),
                            insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
                            documentation: 'Parameter metadata JSON with export functions for BearBone WASM.',
                            range,
                        },
                        {
                            label: 'PARAMS_BUF',
                            kind: monaco.languages.CompletionItemKind.Variable,
                            insertText: [
                                'const MAX_PARAMS: usize = 16;',
                                'static mut PARAMS_BUF: [f32; MAX_PARAMS] = [0.0; MAX_PARAMS];',
                                '',
                                '#[unsafe(no_mangle)]',
                                'pub extern "C" fn get_params_ptr() -> *mut f32 {',
                                '\tunsafe { PARAMS_BUF.as_mut_ptr() }',
                                '}',
                            ].join('\n'),
                            insertTextRules: monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
                            documentation: 'Parameter buffer with pointer export for BearBone WASM.',
                            range,
                        },
                    ],
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
