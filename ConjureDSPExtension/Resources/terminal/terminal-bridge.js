// terminal-bridge.js
// Bridges xterm.js terminal with WebSocket relay and Swift WKWebView host.

(function() {
    'use strict';

    // --- Theme definitions ---
    const themes = {
        dark: {
            // ConjureDSP branded theme — mirrors the Monaco editor theme.
            // ANSI palette keeps semantic meaning (red = error, green = success,
            // yellow = warning) while pulling blue/magenta/cyan/yellow from the
            // brand palette in `assets/palette.md`.
            background: '#0D0F1A',          // deep navy
            foreground: '#C5D4FF',          // pale ice blue
            cursor: '#00E5FF',              // electric cyan
            cursorAccent: '#0D0F1A',
            selectionBackground: '#1C2235', // brushed metal
            black: '#0D0F1A',
            red: '#FF5570',                 // true red (reserved for errors)
            green: '#5EE0A1',               // success green
            yellow: '#FFD166',              // warm gold (palette)
            blue: '#7B9FFF',                // ice blue (palette)
            magenta: '#B06EFF',             // soft purple (palette)
            cyan: '#00E5FF',                // electric cyan (palette)
            white: '#C5D4FF',               // pale ice blue
            brightBlack: '#3A4060',
            brightRed: '#FF7A8E',
            brightGreen: '#7EEBB4',
            brightYellow: '#FFDE8A',
            brightBlue: '#4FC3F7',          // sky blue (palette)
            brightMagenta: '#E0B4FF',       // pale lilac (palette)
            brightCyan: '#7BF0FF',
            brightWhite: '#FFFFFF'
        },
        light: {
            background: '#ffffff',
            foreground: '#333333',
            cursor: '#333333',
            cursorAccent: '#ffffff',
            selectionBackground: '#add6ff',
            black: '#000000',
            red: '#cd3131',
            green: '#008000',
            yellow: '#795e00',
            blue: '#0451a5',
            magenta: '#bc05bc',
            cyan: '#0598bc',
            white: '#e5e5e5',
            brightBlack: '#666666',
            brightRed: '#cd3131',
            brightGreen: '#14ce14',
            brightYellow: '#b5ba00',
            brightBlue: '#0451a5',
            brightMagenta: '#bc05bc',
            brightCyan: '#0598bc',
            brightWhite: '#a5a5a5'
        }
    };

    // --- State ---
    let terminal = null;
    let fitAddon = null;
    let inputProxy = null;
    let socket = null;
    let currentTheme = 'dark';
    let reconnectAttempts = 0;
    let reconnectTimer = null;
    let wsPort = null;
    let hasSentFirstInput = false;
    const MAX_RECONNECT_ATTEMPTS = 50;

    function sendUserInput(data) {
        if (!socket || socket.readyState !== WebSocket.OPEN) return;
        socket.send(data);
        if (!hasSentFirstInput) {
            hasSentFirstInput = true;
            postToSwift('firstInput', {});
        }
    }

    // --- Initialize terminal ---
    function initTerminal() {
        // Check required dependencies — show visible error if missing
        if (typeof Terminal === 'undefined') {
            showStatus('Terminal failed to load', 'xterm.js is missing — run scripts/setup-xterm.sh');
            postToSwift('error', { message: 'xterm.js missing' });
            return;
        }
        if (typeof FitAddon === 'undefined') {
            showStatus('Terminal failed to load', 'addon-fit.js is missing — run scripts/setup-xterm.sh');
            postToSwift('error', { message: 'addon-fit.js missing' });
            return;
        }

        const termTheme = themes[currentTheme];

        terminal = new Terminal({
            theme: termTheme,
            fontFamily: 'Menlo, Monaco, "Courier New", monospace',
            fontSize: 13,
            lineHeight: 1.2,
            cursorBlink: true,
            cursorStyle: 'block',
            allowTransparency: true,
            scrollback: 5000,
            convertEol: false,
        });

        fitAddon = new FitAddon.FitAddon();
        terminal.loadAddon(fitAddon);

        if (typeof WebLinksAddon !== 'undefined') {
            terminal.loadAddon(new WebLinksAddon.WebLinksAddon());
        }

        terminal.open(document.getElementById('terminal'));
        fitAddon.fit();

        // Send user input to WebSocket
        terminal.onData(function(data) {
            sendUserInput(data);
        });

        // Handle resize
        terminal.onResize(function(size) {
            // Notify Swift about size changes
            postToSwift('resize', { cols: size.cols, rows: size.rows });
            // Notify WebSocket server
            if (socket && socket.readyState === WebSocket.OPEN) {
                // Send resize as a special message (JSON-encoded)
                socket.send(JSON.stringify({ type: 'resize', cols: size.cols, rows: size.rows }));
            }
        });

        // Fit on window resize
        const resizeObserver = new ResizeObserver(function() {
            if (fitAddon) {
                fitAddon.fit();
            }
        });
        resizeObserver.observe(document.getElementById('terminal-container'));

        // --- Input proxy for AU ViewBridge keyboard input ---
        // The AU ViewBridge only forwards keyboard input for contentEditable
        // surfaces via NSTextInputClient (same mechanism as Monaco editor).
        // xterm.js's hidden textarea doesn't trigger this pathway.
        //
        // A small contentEditable div acts as the input proxy: it receives text
        // input from WebKit, forwards it to the WebSocket, then clears itself.
        // Special keys (Enter, Escape, arrows, etc.) are handled via keydown.
        // xterm.js handles display — all output comes back through the WebSocket.
        inputProxy = document.getElementById('input-proxy');

        // Focus the proxy on terminal click (pointer-events:none means we
        // must focus programmatically — mouse events pass through to xterm.js)
        document.getElementById('terminal-container').addEventListener('mousedown', function() {
            inputProxy.focus();
        });

        // Regular character input
        inputProxy.addEventListener('input', function() {
            var text = inputProxy.textContent || '';
            if (text) {
                sendUserInput(text);
            }
            inputProxy.textContent = '';
        });

        // Special keys and modifier combinations
        inputProxy.addEventListener('keydown', function(e) {
            // Cmd+C: copy terminal selection to clipboard
            if (e.metaKey && e.key === 'c') {
                var sel = terminal ? terminal.getSelection() : '';
                if (sel) {
                    navigator.clipboard.writeText(sel);
                    e.preventDefault();
                }
                return;
            }
            // Cmd+A: select all terminal content
            if (e.metaKey && e.key === 'a') {
                if (terminal) terminal.selectAll();
                e.preventDefault();
                return;
            }
            // Other Cmd+key: pass through for app shortcuts (Cmd+S, Cmd+R, Cmd+N)
            if (e.metaKey) return;

            var data = null;

            if (e.ctrlKey && e.key.length === 1) {
                var code = e.key.toLowerCase().charCodeAt(0) - 96;
                if (code >= 1 && code <= 26) data = String.fromCharCode(code);
            } else {
                switch (e.key) {
                case 'Enter':      data = '\r'; break;
                case 'Escape':     data = '\x1b'; break;
                case 'Backspace':  data = '\x7f'; break;
                case 'Tab':        data = '\t'; e.preventDefault(); break;
                case 'ArrowUp':    data = '\x1b[A'; break;
                case 'ArrowDown':  data = '\x1b[B'; break;
                case 'ArrowRight': data = '\x1b[C'; break;
                case 'ArrowLeft':  data = '\x1b[D'; break;
                case 'Home':       data = '\x1b[H'; break;
                case 'End':        data = '\x1b[F'; break;
                case 'PageUp':     data = '\x1b[5~'; break;
                case 'PageDown':   data = '\x1b[6~'; break;
                case 'Delete':     data = '\x1b[3~'; break;
                default:
                    // Regular printable character — send directly
                    if (e.key.length === 1) {
                        data = e.key;
                    }
                    break;
                }
            }

            if (data !== null) {
                e.preventDefault();
                sendUserInput(data);
            }
        });

        // Notify Swift that terminal is ready
        postToSwift('terminalReady', {});
    }

    // --- WebSocket connection ---
    function connect(port) {
        wsPort = port;
        reconnectAttempts = 0;
        doConnect();
    }

    function doConnect() {
        if (!wsPort) return;

        if (socket) {
            socket.close();
            socket = null;
        }

        showStatus('Connecting...', '');

        try {
            socket = new WebSocket('ws://localhost:' + wsPort);
            socket.binaryType = 'arraybuffer';

            socket.onopen = function() {
                reconnectAttempts = 0;
                hasSentFirstInput = false;
                hideStatus();
                postToSwift('connected', {});

                // Focus the contentEditable input proxy — xterm's hidden
                // textarea does NOT trigger NSTextInputClient through the AU
                // ViewBridge, so focusing `terminal` here would silently
                // drop all keyboard input until the user clicks the terminal.
                if (inputProxy) inputProxy.focus();

                // Send initial terminal size
                if (terminal) {
                    socket.send(JSON.stringify({
                        type: 'resize',
                        cols: terminal.cols,
                        rows: terminal.rows
                    }));
                }
            };

            socket.onmessage = function(event) {
                if (terminal) {
                    if (event.data instanceof ArrayBuffer) {
                        terminal.write(new Uint8Array(event.data));
                    } else {
                        terminal.write(event.data);
                    }
                }
            };

            socket.onclose = function(event) {
                postToSwift('disconnected', { code: event.code, reason: event.reason });
                scheduleReconnect();
            };

            socket.onerror = function() {
                // onclose will fire after onerror
            };
        } catch (e) {
            showStatus('Connection failed', e.message);
            scheduleReconnect();
        }
    }

    function disconnect() {
        if (reconnectTimer) {
            clearTimeout(reconnectTimer);
            reconnectTimer = null;
        }
        if (socket) {
            socket.close();
            socket = null;
        }
        showStatus('Disconnected', '');
    }

    function scheduleReconnect() {
        if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
            showStatus('Connection lost', 'Open ConjureDSP app to reconnect');
            return;
        }

        reconnectAttempts++;
        // Exponential backoff: 500ms, 1s, 2s, 4s, max 10s
        var delay = Math.min(500 * Math.pow(2, reconnectAttempts - 1), 10000);
        showStatus('Reconnecting...', 'Attempt ' + reconnectAttempts);

        reconnectTimer = setTimeout(function() {
            reconnectTimer = null;
            doConnect();
        }, delay);
    }

    // --- Status overlay ---
    function showStatus(text, hint) {
        var overlay = document.getElementById('status-overlay');
        document.getElementById('status-text').textContent = text;
        document.getElementById('status-hint').textContent = hint || '';
        overlay.classList.add('visible');
    }

    function hideStatus() {
        document.getElementById('status-overlay').classList.remove('visible');
    }

    // --- Theme ---
    function setTheme(themeName) {
        currentTheme = themeName;
        if (terminal) {
            terminal.options.theme = themes[themeName];
        }
        // Update overlay text colors for light theme
        var statusText = document.getElementById('status-text');
        var statusHint = document.getElementById('status-hint');
        if (themeName === 'light') {
            statusText.style.color = '#555';
            statusHint.style.color = '#888';
        } else {
            statusText.style.color = '#888';
            statusHint.style.color = '#666';
        }
    }

    // --- Swift communication ---
    function postToSwift(event, data) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.terminalBridge) {
            window.webkit.messageHandlers.terminalBridge.postMessage({
                event: event,
                data: data
            });
        }
    }

    // --- Public API (called from Swift via evaluateJavaScript) ---
    window.terminalBridge = {
        connect: connect,
        disconnect: disconnect,
        setTheme: setTheme,
        fit: function() {
            if (fitAddon) fitAddon.fit();
        },
        write: function(text) {
            if (terminal) terminal.write(text);
        },
        clear: function() {
            if (terminal) terminal.clear();
        },
        focus: function() {
            if (inputProxy) inputProxy.focus();
        },
    };

    // --- Initialize on load ---
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initTerminal);
    } else {
        initTerminal();
    }
})();
