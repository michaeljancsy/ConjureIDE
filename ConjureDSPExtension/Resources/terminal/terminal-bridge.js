// terminal-bridge.js
// Bridges xterm.js terminal with WebSocket relay and Swift WKWebView host.

(function() {
    'use strict';

    // --- Theme definitions ---
    const themes = {
        dark: {
            background: '#1e1e1e',
            foreground: '#d4d4d4',
            cursor: '#d4d4d4',
            cursorAccent: '#1e1e1e',
            selectionBackground: '#264f78',
            black: '#000000',
            red: '#cd3131',
            green: '#0dbc79',
            yellow: '#e5e510',
            blue: '#2472c8',
            magenta: '#bc3fbc',
            cyan: '#11a8cd',
            white: '#e5e5e5',
            brightBlack: '#666666',
            brightRed: '#f14c4c',
            brightGreen: '#23d18b',
            brightYellow: '#f5f543',
            brightBlue: '#3b8eea',
            brightMagenta: '#d670d6',
            brightCyan: '#29b8db',
            brightWhite: '#e5e5e5'
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
    let socket = null;
    let currentTheme = 'dark';
    let reconnectAttempts = 0;
    let reconnectTimer = null;
    let wsPort = null;
    const MAX_RECONNECT_ATTEMPTS = 50;

    // --- Initialize terminal ---
    function initTerminal() {
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
            if (socket && socket.readyState === WebSocket.OPEN) {
                socket.send(data);
            }
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
        var inputProxy = document.getElementById('input-proxy');

        // Focus the proxy on terminal click (pointer-events:none means we
        // must focus programmatically — mouse events pass through to xterm.js)
        document.getElementById('terminal-container').addEventListener('mousedown', function() {
            inputProxy.focus();
        });

        // Regular character input
        inputProxy.addEventListener('input', function() {
            var text = inputProxy.textContent || '';
            if (text && socket && socket.readyState === WebSocket.OPEN) {
                socket.send(text);
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
                if (socket && socket.readyState === WebSocket.OPEN) {
                    socket.send(data);
                }
            }
        });

        // --- DEBUG: Diagnose keyboard input ---
        document.addEventListener('mousedown', function(e) {
            var ta = document.querySelector('.xterm-helper-textarea');
            var info = '[click] activeElement=' + (document.activeElement ? document.activeElement.className || document.activeElement.tagName : 'none');
            info += ' textarea=' + (ta ? 'exists' : 'MISSING');
            info += ' hasFocus=' + document.hasFocus();
            if (terminal) terminal.write('\r\n\x1b[33m' + info + '\x1b[0m\r\n');
            postToSwift('debug', { message: info });
        });

        document.addEventListener('keydown', function(e) {
            var info = '[keydown] key=' + e.key + ' activeElement=' + (document.activeElement ? document.activeElement.className || document.activeElement.tagName : 'none');
            if (terminal) terminal.write('\r\n\x1b[32m' + info + '\x1b[0m\r\n');
            postToSwift('debug', { message: info });
        });
        // --- END DEBUG ---

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
                hideStatus();
                postToSwift('connected', {});

                // Focus terminal so it receives keyboard input
                if (terminal) terminal.focus();

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
            if (terminal) terminal.focus();
        },
        // Send raw input data to the WebSocket (bypasses xterm.js keyboard handling).
        // Used when the WKWebView doesn't receive keyboard events due to
        // AU extension ViewBridge first responder issues.
        sendInput: function(data) {
            if (socket && socket.readyState === WebSocket.OPEN) {
                socket.send(data);
            }
        },
        // Send base64-encoded input data to the WebSocket.
        // Called from Swift's performKeyEquivalent to inject keyboard input.
        sendInputBase64: function(b64) {
            var binary = atob(b64);
            if (socket && socket.readyState === WebSocket.OPEN) {
                socket.send(binary);
            }
        }
    };

    // --- Initialize on load ---
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', initTerminal);
    } else {
        initTerminal();
    }
})();
