// Custom Monaco themes for ConjureDSP
// Registered before editor-bridge.js init so they're available via bridge.setTheme()

function registerConjureDSPThemes() {
    if (typeof monaco === 'undefined') return;

    // ── Monokai ──────────────────────────────────────────────────────
    monaco.editor.defineTheme('monokai', {
        base: 'vs-dark',
        inherit: true,
        rules: [
            { token: 'comment', foreground: '88846f', fontStyle: 'italic' },
            { token: 'keyword', foreground: 'f92672' },
            { token: 'string', foreground: 'e6db74' },
            { token: 'number', foreground: 'ae81ff' },
            { token: 'type', foreground: '66d9ef', fontStyle: 'italic' },
            { token: 'function', foreground: 'a6e22e' },
            { token: 'variable', foreground: 'f8f8f2' },
            { token: 'operator', foreground: 'f92672' },
            { token: 'delimiter', foreground: 'f8f8f2' },
            { token: 'identifier', foreground: 'f8f8f2' },
            { token: 'tag', foreground: 'f92672' },
            { token: 'attribute.name', foreground: 'a6e22e' },
            { token: 'attribute.value', foreground: 'e6db74' },
            { token: 'string.escape', foreground: 'ae81ff' },
        ],
        colors: {
            'editor.background': '#272822',
            'editor.foreground': '#f8f8f2',
            'editor.selectionBackground': '#49483e',
            'editor.lineHighlightBackground': '#3e3d32',
            'editorCursor.foreground': '#f8f8f0',
            'editorWhitespace.foreground': '#464741',
            'editorLineNumber.foreground': '#90908a',
            'editorLineNumber.activeForeground': '#c2c2bf',
            'editor.selectionHighlightBackground': '#49483e88',
            'editorBracketMatch.background': '#49483e',
            'editorBracketMatch.border': '#888888',
        },
    });

    // ── Dracula ──────────────────────────────────────────────────────
    monaco.editor.defineTheme('dracula', {
        base: 'vs-dark',
        inherit: true,
        rules: [
            { token: 'comment', foreground: '6272a4', fontStyle: 'italic' },
            { token: 'keyword', foreground: 'ff79c6' },
            { token: 'string', foreground: 'f1fa8c' },
            { token: 'number', foreground: 'bd93f9' },
            { token: 'type', foreground: '8be9fd', fontStyle: 'italic' },
            { token: 'function', foreground: '50fa7b' },
            { token: 'variable', foreground: 'f8f8f2' },
            { token: 'operator', foreground: 'ff79c6' },
            { token: 'delimiter', foreground: 'f8f8f2' },
            { token: 'identifier', foreground: 'f8f8f2' },
            { token: 'tag', foreground: 'ff79c6' },
            { token: 'attribute.name', foreground: '50fa7b' },
            { token: 'attribute.value', foreground: 'f1fa8c' },
            { token: 'string.escape', foreground: 'ffb86c' },
        ],
        colors: {
            'editor.background': '#282a36',
            'editor.foreground': '#f8f8f2',
            'editor.selectionBackground': '#44475a',
            'editor.lineHighlightBackground': '#44475a75',
            'editorCursor.foreground': '#f8f8f0',
            'editorWhitespace.foreground': '#424450',
            'editorLineNumber.foreground': '#6272a4',
            'editorLineNumber.activeForeground': '#f8f8f2',
            'editor.selectionHighlightBackground': '#44475a88',
            'editorBracketMatch.background': '#44475a',
            'editorBracketMatch.border': '#bd93f9',
        },
    });

    // ── Solarized Dark ───────────────────────────────────────────────
    monaco.editor.defineTheme('solarized-dark', {
        base: 'vs-dark',
        inherit: true,
        rules: [
            { token: 'comment', foreground: '586e75', fontStyle: 'italic' },
            { token: 'keyword', foreground: '859900' },
            { token: 'string', foreground: '2aa198' },
            { token: 'number', foreground: 'd33682' },
            { token: 'type', foreground: 'b58900' },
            { token: 'function', foreground: '268bd2' },
            { token: 'variable', foreground: '839496' },
            { token: 'operator', foreground: '859900' },
            { token: 'delimiter', foreground: '839496' },
            { token: 'identifier', foreground: '839496' },
            { token: 'tag', foreground: '268bd2' },
            { token: 'attribute.name', foreground: '93a1a1' },
            { token: 'attribute.value', foreground: '2aa198' },
            { token: 'string.escape', foreground: 'dc322f' },
        ],
        colors: {
            'editor.background': '#002b36',
            'editor.foreground': '#839496',
            'editor.selectionBackground': '#073642',
            'editor.lineHighlightBackground': '#073642',
            'editorCursor.foreground': '#839496',
            'editorWhitespace.foreground': '#073642',
            'editorLineNumber.foreground': '#586e75',
            'editorLineNumber.activeForeground': '#839496',
            'editor.selectionHighlightBackground': '#07364288',
            'editorBracketMatch.background': '#073642',
            'editorBracketMatch.border': '#586e75',
        },
    });

    // ── Solarized Light ──────────────────────────────────────────────
    monaco.editor.defineTheme('solarized-light', {
        base: 'vs',
        inherit: true,
        rules: [
            { token: 'comment', foreground: '93a1a1', fontStyle: 'italic' },
            { token: 'keyword', foreground: '859900' },
            { token: 'string', foreground: '2aa198' },
            { token: 'number', foreground: 'd33682' },
            { token: 'type', foreground: 'b58900' },
            { token: 'function', foreground: '268bd2' },
            { token: 'variable', foreground: '657b83' },
            { token: 'operator', foreground: '859900' },
            { token: 'delimiter', foreground: '657b83' },
            { token: 'identifier', foreground: '657b83' },
            { token: 'tag', foreground: '268bd2' },
            { token: 'attribute.name', foreground: '586e75' },
            { token: 'attribute.value', foreground: '2aa198' },
            { token: 'string.escape', foreground: 'dc322f' },
        ],
        colors: {
            'editor.background': '#fdf6e3',
            'editor.foreground': '#657b83',
            'editor.selectionBackground': '#eee8d5',
            'editor.lineHighlightBackground': '#eee8d5',
            'editorCursor.foreground': '#657b83',
            'editorWhitespace.foreground': '#eee8d5',
            'editorLineNumber.foreground': '#93a1a1',
            'editorLineNumber.activeForeground': '#657b83',
            'editor.selectionHighlightBackground': '#eee8d588',
            'editorBracketMatch.background': '#eee8d5',
            'editorBracketMatch.border': '#93a1a1',
        },
    });

    // ── One Dark ─────────────────────────────────────────────────────
    monaco.editor.defineTheme('one-dark', {
        base: 'vs-dark',
        inherit: true,
        rules: [
            { token: 'comment', foreground: '5c6370', fontStyle: 'italic' },
            { token: 'keyword', foreground: 'c678dd' },
            { token: 'string', foreground: '98c379' },
            { token: 'number', foreground: 'd19a66' },
            { token: 'type', foreground: 'e5c07b' },
            { token: 'function', foreground: '61afef' },
            { token: 'variable', foreground: 'e06c75' },
            { token: 'operator', foreground: '56b6c2' },
            { token: 'delimiter', foreground: 'abb2bf' },
            { token: 'identifier', foreground: 'abb2bf' },
            { token: 'tag', foreground: 'e06c75' },
            { token: 'attribute.name', foreground: 'd19a66' },
            { token: 'attribute.value', foreground: '98c379' },
            { token: 'string.escape', foreground: '56b6c2' },
        ],
        colors: {
            'editor.background': '#282c34',
            'editor.foreground': '#abb2bf',
            'editor.selectionBackground': '#3e4451',
            'editor.lineHighlightBackground': '#2c313c',
            'editorCursor.foreground': '#528bff',
            'editorWhitespace.foreground': '#3b4048',
            'editorLineNumber.foreground': '#495162',
            'editorLineNumber.activeForeground': '#abb2bf',
            'editor.selectionHighlightBackground': '#3e445188',
            'editorBracketMatch.background': '#3e4451',
            'editorBracketMatch.border': '#528bff',
        },
    });

    // ── GitHub Dark ──────────────────────────────────────────────────
    monaco.editor.defineTheme('github-dark', {
        base: 'vs-dark',
        inherit: true,
        rules: [
            { token: 'comment', foreground: '8b949e', fontStyle: 'italic' },
            { token: 'keyword', foreground: 'ff7b72' },
            { token: 'string', foreground: 'a5d6ff' },
            { token: 'number', foreground: '79c0ff' },
            { token: 'type', foreground: 'ffa657' },
            { token: 'function', foreground: 'd2a8ff' },
            { token: 'variable', foreground: 'ffa657' },
            { token: 'operator', foreground: 'ff7b72' },
            { token: 'delimiter', foreground: 'c9d1d9' },
            { token: 'identifier', foreground: 'c9d1d9' },
            { token: 'tag', foreground: '7ee787' },
            { token: 'attribute.name', foreground: '79c0ff' },
            { token: 'attribute.value', foreground: 'a5d6ff' },
            { token: 'string.escape', foreground: '79c0ff' },
        ],
        colors: {
            'editor.background': '#0d1117',
            'editor.foreground': '#c9d1d9',
            'editor.selectionBackground': '#264f78',
            'editor.lineHighlightBackground': '#161b22',
            'editorCursor.foreground': '#c9d1d9',
            'editorWhitespace.foreground': '#21262d',
            'editorLineNumber.foreground': '#484f58',
            'editorLineNumber.activeForeground': '#c9d1d9',
            'editor.selectionHighlightBackground': '#264f7888',
            'editorBracketMatch.background': '#264f78',
            'editorBracketMatch.border': '#79c0ff',
        },
    });

    // ── ConjureDSP ───────────────────────────────────────────────────
    monaco.editor.defineTheme('conjuredsp', {
        base: 'vs-dark',
        inherit: true,
        rules: [
            { token: 'comment',         foreground: '6b7394', fontStyle: 'italic' },
            { token: 'keyword',         foreground: '7b9fff' }, // ice blue
            { token: 'string',          foreground: 'ffd166' }, // warm gold
            { token: 'number',          foreground: '4fc3f7' }, // sky blue
            { token: 'type',            foreground: '00e5ff', fontStyle: 'italic' }, // electric cyan
            { token: 'function',        foreground: 'b06eff' }, // soft purple
            { token: 'variable',        foreground: 'c5d4ff' }, // pale ice blue
            { token: 'operator',        foreground: '4fc3f7' }, // sky blue
            { token: 'delimiter',       foreground: 'c5d4ff' },
            { token: 'identifier',      foreground: 'c5d4ff' },
            { token: 'tag',             foreground: '7b9fff' }, // ice blue
            { token: 'attribute.name',  foreground: 'b06eff' }, // soft purple
            { token: 'attribute.value', foreground: 'ffd166' },
            { token: 'string.escape',   foreground: '00e5ff' }, // electric cyan
        ],
        colors: {
            'editor.background':                   '#0D0F1A',
            'editor.foreground':                   '#C5D4FF', // pale ice blue
            'editor.selectionBackground':          '#1C2235',
            'editor.lineHighlightBackground':      '#141826',
            'editorCursor.foreground':             '#00E5FF',
            'editorWhitespace.foreground':         '#1C2235',
            'editorLineNumber.foreground':         '#3a4060',
            'editorLineNumber.activeForeground':   '#B06EFF', // purple accent
            'editor.selectionHighlightBackground': '#1C223588',
            'editorBracketMatch.background':       '#1C2235',
            'editorBracketMatch.border':           '#7B9FFF', // ice blue
        },
    });
}
