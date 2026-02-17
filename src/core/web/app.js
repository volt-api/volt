// ── Volt Web UI — Vanilla JS SPA ────────────────────────────────────────
// No framework, no build tools. ~2000 lines of plain JavaScript.

const VoltApp = (() => {
    'use strict';

    // ── State ───────────────────────────────────────────────────────────
    const state = {
        // Request
        method: 'GET',
        url: '',
        params: [],
        headers: [],
        bodyType: 'none',
        body: '',
        authType: 'none',
        auth: {},
        tests: '',

        // Response
        response: null,
        loading: false,

        // Collections
        collections: [],
        activeFile: null,

        // Environment
        environments: [],
        activeEnv: '',

        // History
        history: [],

        // UI
        theme: localStorage.getItem('volt-theme') || 'dark',
        sidebarCollapsed: false,
        activeReqTab: 'params',
        activeRespTab: 'resp-body',
        activeSidebarTab: 'collections',
        responseView: 'pretty',
    };

    // ── API Client ──────────────────────────────────────────────────────
    const api = {
        base: window.location.origin,

        async request(endpoint, options = {}) {
            try {
                const resp = await fetch(this.base + endpoint, {
                    headers: { 'Content-Type': 'application/json' },
                    ...options,
                });
                return await resp.json();
            } catch (err) {
                console.error('API Error:', err);
                return { error: err.message };
            }
        },

        async executeRequest(data) {
            return this.request('/api/request/execute', {
                method: 'POST',
                body: JSON.stringify(data),
            });
        },

        async parseVolt(content) {
            return this.request('/api/request/parse', {
                method: 'POST',
                body: content,
            });
        },

        async getCollections(dir) {
            const q = dir ? `?dir=${encodeURIComponent(dir)}` : '';
            return this.request('/api/collections' + q);
        },

        async getCollectionTree(dir) {
            const q = dir ? `?dir=${encodeURIComponent(dir)}` : '';
            return this.request('/api/collections/tree' + q);
        },

        async searchCollections(query) {
            return this.request('/api/collections/search?q=' + encodeURIComponent(query));
        },

        async getEnvironments() {
            return this.request('/api/environments');
        },

        async createEnvironment(data) {
            return this.request('/api/environments', {
                method: 'POST',
                body: JSON.stringify(data),
            });
        },

        async importCurl(cmd) {
            return this.request('/api/import/curl', {
                method: 'POST',
                body: cmd,
            });
        },

        async exportRequest(format, voltContent) {
            return this.request('/api/export/' + format, {
                method: 'POST',
                body: voltContent,
            });
        },

        async generateTests(responseBody) {
            return this.request('/api/test/generate', {
                method: 'POST',
                body: responseBody,
            });
        },

        async getHistory() {
            return this.request('/api/history');
        },

        async clearHistory() {
            return this.request('/api/history/clear', { method: 'POST' });
        },

        async getThemes() {
            return this.request('/api/themes');
        },

        async getConfig() {
            return this.request('/api/config');
        },

        async updateConfig(data) {
            return this.request('/api/config', {
                method: 'POST',
                body: JSON.stringify(data),
            });
        },
    };

    // ── DOM Helpers ─────────────────────────────────────────────────────
    const $ = (sel) => document.querySelector(sel);
    const $$ = (sel) => document.querySelectorAll(sel);

    function el(tag, attrs = {}, children = []) {
        const e = document.createElement(tag);
        Object.entries(attrs).forEach(([k, v]) => {
            if (k === 'class') e.className = v;
            else if (k === 'text') e.textContent = v;
            else if (k === 'html') e.innerHTML = v;
            else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
            else e.setAttribute(k, v);
        });
        children.forEach(c => {
            if (typeof c === 'string') e.appendChild(document.createTextNode(c));
            else if (c) e.appendChild(c);
        });
        return e;
    }

    // ── Initialization ──────────────────────────────────────────────────
    function init() {
        applyTheme(state.theme);
        bindEvents();
        loadCollections();
        loadEnvironments();
        loadHistory();
        updateMethodColor();
        addDefaultRows();
        updateAuthFields();
        setStatus('Ready');
    }

    // ── Event Binding ───────────────────────────────────────────────────
    function bindEvents() {
        // Send request
        $('#btn-send').addEventListener('click', sendRequest);

        // URL input — detect pasted cURL
        $('#url-input').addEventListener('paste', (e) => {
            setTimeout(() => {
                const val = $('#url-input').value.trim();
                if (val.startsWith('curl ') || val.startsWith('curl.exe ')) {
                    importCurlFromPaste(val);
                }
            }, 50);
        });

        // Method color
        $('#method-select').addEventListener('change', () => {
            state.method = $('#method-select').value;
            updateMethodColor();
        });

        // Theme
        $('#theme-select').addEventListener('change', (e) => {
            applyTheme(e.target.value);
        });

        // Request tabs
        $$('.req-tab').forEach(tab => {
            tab.addEventListener('click', () => switchReqTab(tab.dataset.tab));
        });

        // Response tabs
        $$('.resp-tab').forEach(tab => {
            tab.addEventListener('click', () => switchRespTab(tab.dataset.tab));
        });

        // Response view toggles
        $$('.view-toggle').forEach(btn => {
            btn.addEventListener('click', () => switchResponseView(btn.dataset.view));
        });

        // Sidebar tabs
        $$('.sidebar-tab').forEach(tab => {
            tab.addEventListener('click', () => switchSidebarTab(tab.dataset.tab));
        });

        // Sidebar toggle
        $('#sidebar-toggle').addEventListener('click', toggleSidebar);

        // Toolbar buttons
        $('#btn-import').addEventListener('click', showImportModal);
        $('#btn-history').addEventListener('click', () => switchSidebarTab('history-tab'));
        $('#btn-settings').addEventListener('click', showSettingsModal);

        // Add row buttons
        $$('.btn-add-row').forEach(btn => {
            btn.addEventListener('click', () => addKvRow(btn.dataset.target));
        });

        // Auth type
        $('#auth-type').addEventListener('change', () => {
            state.authType = $('#auth-type').value;
            updateAuthFields();
        });

        // Generate tests
        $('#btn-generate-tests').addEventListener('click', generateTests);

        // Response actions
        $('#btn-copy-response').addEventListener('click', copyResponse);
        $('#btn-export').addEventListener('click', showExportModal);
        $('#btn-save-as-volt').addEventListener('click', saveAsVolt);

        // New request
        $('#btn-new-request').addEventListener('click', newRequest);

        // Search
        $('#search-input').addEventListener('input', (e) => {
            if (e.target.value.length > 0) {
                searchCollections(e.target.value);
            } else {
                loadCollections();
            }
        });

        // Modal close
        $('#modal-close').addEventListener('click', hideModal);
        $('#modal-overlay').addEventListener('click', (e) => {
            if (e.target === $('#modal-overlay')) hideModal();
        });

        // Keyboard shortcuts
        document.addEventListener('keydown', handleKeyboard);

        // Drag & drop import
        document.body.addEventListener('dragover', (e) => { e.preventDefault(); });
        document.body.addEventListener('drop', handleFileDrop);
    }

    // ── Keyboard Shortcuts ──────────────────────────────────────────────
    function handleKeyboard(e) {
        // Ctrl+Enter — Send request
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
            e.preventDefault();
            sendRequest();
        }
        // Ctrl+S — Save as .volt
        if ((e.ctrlKey || e.metaKey) && e.key === 's') {
            e.preventDefault();
            saveAsVolt();
        }
        // Ctrl+L — Clear response
        if ((e.ctrlKey || e.metaKey) && e.key === 'l') {
            e.preventDefault();
            clearResponse();
        }
        // Ctrl+I — Import
        if ((e.ctrlKey || e.metaKey) && e.key === 'i') {
            e.preventDefault();
            showImportModal();
        }
        // Ctrl+H — History
        if ((e.ctrlKey || e.metaKey) && e.key === 'h') {
            e.preventDefault();
            switchSidebarTab('history-tab');
        }
        // Escape — Close modal
        if (e.key === 'Escape') {
            hideModal();
        }
    }

    // ── Send Request ────────────────────────────────────────────────────
    async function sendRequest() {
        const url = $('#url-input').value.trim();
        if (!url) {
            setStatus('Please enter a URL');
            return;
        }

        state.loading = true;
        $('#btn-send').classList.add('loading');
        $('#btn-send').textContent = 'Sending...';
        setStatus('Sending request...');

        // Build request data
        const data = {
            method: state.method,
            url: url,
            headers: {},
            auth: {},
        };

        // Collect headers from table
        const headerRows = $$('#headers-table tbody tr');
        headerRows.forEach(row => {
            const inputs = row.querySelectorAll('input');
            if (inputs.length >= 2 && inputs[0].value && inputs[1].value) {
                data.headers[inputs[0].value] = inputs[1].value;
            }
        });

        // Body
        const bodyType = document.querySelector('input[name="body-type"]:checked').value;
        if (bodyType !== 'none') {
            data.body = $('#body-editor').value;
            if (bodyType === 'json') {
                data.headers['Content-Type'] = data.headers['Content-Type'] || 'application/json';
            } else if (bodyType === 'form') {
                data.headers['Content-Type'] = data.headers['Content-Type'] || 'application/x-www-form-urlencoded';
            }
        }

        // Auth
        if (state.authType === 'bearer') {
            const tokenInput = $('#auth-bearer-token');
            if (tokenInput && tokenInput.value) {
                data.auth = { type: 'bearer', token: tokenInput.value };
            }
        } else if (state.authType === 'basic') {
            const userInput = $('#auth-basic-user');
            const passInput = $('#auth-basic-pass');
            if (userInput && passInput) {
                data.auth = { type: 'basic', username: userInput.value, password: passInput.value };
            }
        } else if (state.authType === 'apikey') {
            const keyInput = $('#auth-apikey-key');
            const valInput = $('#auth-apikey-value');
            const locInput = $('#auth-apikey-location');
            if (keyInput && valInput) {
                const loc = locInput ? locInput.value : 'header';
                if (loc === 'header') {
                    data.headers[keyInput.value] = valInput.value;
                }
            }
        }

        // Append query params
        const paramRows = $$('#params-table tbody tr');
        const params = new URLSearchParams();
        let hasParams = false;
        paramRows.forEach(row => {
            const inputs = row.querySelectorAll('input');
            if (inputs.length >= 2 && inputs[0].value) {
                params.append(inputs[0].value, inputs[1].value);
                hasParams = true;
            }
        });
        if (hasParams) {
            const sep = data.url.includes('?') ? '&' : '?';
            data.url += sep + params.toString();
        }

        const result = await api.executeRequest(data);

        state.loading = false;
        $('#btn-send').classList.remove('loading');
        $('#btn-send').textContent = 'Send';

        if (result.error) {
            setStatus('Error: ' + result.error);
            showError(result.error + (result.details ? '\n' + result.details : ''));
        } else {
            state.response = result;
            renderResponse(result);
            setStatus(`${result.status_code} — ${result.timing?.total_ms || 0}ms`);

            // Refresh history
            loadHistory();
        }
    }

    // ── Render Response ─────────────────────────────────────────────────
    function renderResponse(resp) {
        // Show response section, hide empty state
        $('#response-empty').classList.add('hidden');
        $('#response-meta').classList.add('visible');

        // Status badge
        const statusEl = $('#response-status');
        statusEl.textContent = resp.status_code + ' ' + (resp.status_text || '');
        statusEl.className = 'status-badge';
        if (resp.status_code >= 200 && resp.status_code < 300) statusEl.classList.add('status-2xx');
        else if (resp.status_code >= 300 && resp.status_code < 400) statusEl.classList.add('status-3xx');
        else if (resp.status_code >= 400 && resp.status_code < 500) statusEl.classList.add('status-4xx');
        else if (resp.status_code >= 500) statusEl.classList.add('status-5xx');

        // Time & Size
        $('#response-time').textContent = (resp.timing?.total_ms || 0) + ' ms';
        $('#response-size').textContent = formatBytes(resp.size_bytes || 0);

        // Body
        renderResponseBody(resp);

        // Headers
        renderResponseHeaders(resp.headers || {});

        // Timing
        renderTimingWaterfall(resp.timing || {});

        // Run tests if any
        runTests(resp);
    }

    function renderResponseBody(resp) {
        const bodyEl = $('#response-body');
        const body = resp.body;

        if (state.responseView === 'raw') {
            bodyEl.textContent = typeof body === 'object' ? JSON.stringify(body) : String(body);
            return;
        }

        if (state.responseView === 'preview' && typeof body === 'string' &&
            (body.trim().startsWith('<') || body.trim().startsWith('<!DOCTYPE'))) {
            bodyEl.innerHTML = '<iframe style="width:100%;height:100%;border:none;" srcdoc="' +
                body.replace(/"/g, '&quot;') + '"></iframe>';
            return;
        }

        // Pretty print JSON
        if (typeof body === 'object') {
            bodyEl.innerHTML = syntaxHighlight(JSON.stringify(body, null, 2));
        } else if (typeof body === 'string') {
            try {
                const parsed = JSON.parse(body);
                bodyEl.innerHTML = syntaxHighlight(JSON.stringify(parsed, null, 2));
            } catch {
                bodyEl.textContent = body;
            }
        } else {
            bodyEl.textContent = String(body);
        }
    }

    function renderResponseHeaders(headers) {
        const tbody = $('#response-headers-table tbody');
        tbody.innerHTML = '';
        Object.entries(headers).forEach(([name, value]) => {
            const tr = el('tr', {}, [
                el('td', { text: name }),
                el('td', { text: value }),
            ]);
            tbody.appendChild(tr);
        });
    }

    function renderTimingWaterfall(timing) {
        const container = $('#timing-waterfall');
        container.innerHTML = '';

        const phases = [
            { label: 'DNS', key: 'dns_ms', cls: 'timing-dns' },
            { label: 'Connect', key: 'connect_ms', cls: 'timing-connect' },
            { label: 'TLS', key: 'tls_ms', cls: 'timing-tls' },
            { label: 'TTFB', key: 'ttfb_ms', cls: 'timing-ttfb' },
            { label: 'Transfer', key: 'transfer_ms', cls: 'timing-transfer' },
        ];

        const total = timing.total_ms || 1;

        phases.forEach(phase => {
            const ms = timing[phase.key] || 0;
            const pct = Math.max((ms / total) * 100, ms > 0 ? 2 : 0);

            const row = el('div', { class: 'timing-row' }, [
                el('span', { class: 'timing-label', text: phase.label }),
                el('div', { class: 'timing-bar-container' }, [
                    el('div', {
                        class: 'timing-bar ' + phase.cls,
                        style: `width: ${pct}%`,
                        text: ms > 0 ? ms + 'ms' : '',
                    }),
                ]),
                el('span', { class: 'timing-value', text: ms + ' ms' }),
            ]);
            container.appendChild(row);
        });

        // Total
        const totalRow = el('div', { class: 'timing-row' }, [
            el('span', { class: 'timing-label', text: 'Total', style: 'font-weight:700;color:var(--text)' }),
            el('div', {}),
            el('span', { class: 'timing-value', text: total + ' ms', style: 'font-weight:700' }),
        ]);
        container.appendChild(totalRow);
    }

    // ── Test Runner ─────────────────────────────────────────────────────
    function runTests(resp) {
        const testsStr = $('#tests-editor').value.trim();
        if (!testsStr) return;

        const container = $('#test-results');
        container.innerHTML = '';

        const lines = testsStr.split('\n').filter(l => l.trim());
        lines.forEach(line => {
            const result = evaluateTest(line.trim(), resp);
            const div = el('div', { class: 'test-result ' + (result.pass ? 'pass' : 'fail') }, [
                el('span', { class: 'test-icon', text: result.pass ? '\u2713' : '\u2717' }),
                el('span', { text: line.trim() }),
            ]);
            container.appendChild(div);
        });
    }

    function evaluateTest(line, resp) {
        // Simple test evaluator: "status == 200", "$.name == John", "headers.content-type contains json"
        const parts = line.split(/\s+(==|!=|contains|>|<|>=|<=)\s+/);
        if (parts.length < 3) return { pass: false, message: 'Invalid test syntax' };

        const [field, op, expected] = parts;
        let actual;

        if (field === 'status') {
            actual = String(resp.status_code);
        } else if (field.startsWith('headers.')) {
            const headerName = field.slice(8);
            actual = resp.headers?.[headerName] || '';
        } else if (field.startsWith('$.')) {
            try {
                const body = typeof resp.body === 'object' ? resp.body : JSON.parse(resp.body);
                const path = field.slice(2).split('.');
                actual = path.reduce((obj, key) => obj?.[key], body);
                actual = String(actual);
            } catch {
                actual = '';
            }
        } else {
            actual = '';
        }

        const expectedStr = expected.replace(/^["']|["']$/g, '');

        switch (op) {
            case '==': return { pass: actual == expectedStr };
            case '!=': return { pass: actual != expectedStr };
            case 'contains': return { pass: String(actual).toLowerCase().includes(expectedStr.toLowerCase()) };
            case '>': return { pass: Number(actual) > Number(expectedStr) };
            case '<': return { pass: Number(actual) < Number(expectedStr) };
            case '>=': return { pass: Number(actual) >= Number(expectedStr) };
            case '<=': return { pass: Number(actual) <= Number(expectedStr) };
            default: return { pass: false };
        }
    }

    // ── JSON Syntax Highlighting ────────────────────────────────────────
    function syntaxHighlight(json) {
        return json.replace(
            /("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+\-]?\d+)?)/g,
            (match) => {
                let cls = 'json-number';
                if (/^"/.test(match)) {
                    cls = /:$/.test(match) ? 'json-key' : 'json-string';
                } else if (/true|false/.test(match)) {
                    cls = 'json-boolean';
                } else if (/null/.test(match)) {
                    cls = 'json-null';
                }
                // Escape HTML
                const escaped = match.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
                return '<span class="' + cls + '">' + escaped + '</span>';
            }
        );
    }

    // ── Collections ─────────────────────────────────────────────────────
    async function loadCollections() {
        const data = await api.getCollections();
        state.collections = data.files || [];
        renderCollections();
    }

    function renderCollections() {
        const container = $('#collection-tree');
        container.innerHTML = '';

        if (state.collections.length === 0) {
            container.innerHTML = '<div style="padding:16px;color:var(--text-muted);text-align:center;font-size:0.85rem;">' +
                'No .volt files found<br><small>Create a .volt file or import a collection</small></div>';
            return;
        }

        state.collections.sort().forEach(file => {
            const method = guessMethod(file);
            const item = el('div', {
                class: 'tree-item',
                onclick: () => loadVoltFile(file),
            }, [
                el('span', {
                    class: 'method-badge badge-' + method.toLowerCase(),
                    text: method,
                }),
                el('span', { text: file.replace('.volt', '') }),
            ]);
            container.appendChild(item);
        });
    }

    function guessMethod(filename) {
        const lower = filename.toLowerCase();
        if (lower.includes('post') || lower.includes('create')) return 'POST';
        if (lower.includes('put') || lower.includes('update')) return 'PUT';
        if (lower.includes('delete') || lower.includes('remove')) return 'DEL';
        if (lower.includes('patch')) return 'PATCH';
        return 'GET';
    }

    async function loadVoltFile(filename) {
        try {
            const resp = await fetch('/' + filename);
            if (!resp.ok) return;
            const content = await resp.text();
            const parsed = await api.parseVolt(content);
            if (parsed && !parsed.error) {
                fillRequestFromParsed(parsed);
                state.activeFile = filename;
                setStatus('Loaded: ' + filename);
            }
        } catch {
            // File not served by the embedded server, try API parse
            setStatus('Could not load file: ' + filename);
        }
    }

    async function searchCollections(query) {
        const data = await api.searchCollections(query);
        const container = $('#collection-tree');
        container.innerHTML = '';
        (data.results || []).forEach(file => {
            const item = el('div', {
                class: 'tree-item',
                onclick: () => loadVoltFile(file),
            }, [
                el('span', { text: file }),
            ]);
            container.appendChild(item);
        });
    }

    // ── Environments ────────────────────────────────────────────────────
    async function loadEnvironments() {
        const data = await api.getEnvironments();
        state.environments = data.environments || [];
        state.activeEnv = data.active || '';

        const select = $('#env-select');
        select.innerHTML = '<option value="">No Environment</option>';
        state.environments.forEach(env => {
            const name = typeof env === 'string' ? env : env.name;
            const opt = el('option', { value: name, text: name });
            if (name === state.activeEnv) opt.selected = true;
            select.appendChild(opt);
        });
    }

    // ── History ─────────────────────────────────────────────────────────
    async function loadHistory() {
        const data = await api.getHistory();
        state.history = data.entries || [];
    }

    function renderHistory() {
        const container = $('#collection-tree');
        container.innerHTML = '';

        if (state.history.length === 0) {
            container.innerHTML = '<div style="padding:16px;color:var(--text-muted);text-align:center;font-size:0.85rem;">No history yet</div>';
            return;
        }

        state.history.slice().reverse().forEach(entry => {
            const item = el('div', {
                class: 'history-item',
                onclick: () => {
                    $('#method-select').value = entry.method;
                    state.method = entry.method;
                    updateMethodColor();
                    $('#url-input').value = entry.url;
                },
            }, [
                el('span', {
                    class: 'method-badge badge-' + entry.method.toLowerCase(),
                    text: entry.method,
                }),
                el('span', { class: 'history-url', text: entry.url }),
                el('span', {
                    class: 'history-status',
                    text: String(entry.status),
                    style: `color: ${entry.status < 400 ? 'var(--success)' : 'var(--error)'}`,
                }),
                el('span', { class: 'history-time', text: entry.time_ms + 'ms' }),
            ]);
            container.appendChild(item);
        });
    }

    // ── Import / Export ─────────────────────────────────────────────────
    function showImportModal() {
        showModal('Import', `
            <div style="margin-bottom:12px">
                <label>Paste cURL command:</label>
                <textarea id="import-curl-input" placeholder="curl -X POST https://api.example.com/users -H 'Content-Type: application/json' -d '{&quot;name&quot;:&quot;John&quot;}'"></textarea>
            </div>
            <div class="drop-zone" id="import-drop-zone">
                <p>Or drag & drop a Postman collection JSON file here</p>
            </div>
        `, [
            { label: 'Import cURL', primary: true, onclick: importCurl },
            { label: 'Cancel', onclick: hideModal },
        ]);

        // Drag & drop handling for the modal zone
        const zone = $('#import-drop-zone');
        if (zone) {
            zone.addEventListener('dragover', (e) => { e.preventDefault(); zone.classList.add('drag-over'); });
            zone.addEventListener('dragleave', () => zone.classList.remove('drag-over'));
            zone.addEventListener('drop', (e) => {
                e.preventDefault();
                zone.classList.remove('drag-over');
                handleFileDrop(e);
            });
        }
    }

    async function importCurl() {
        const input = $('#import-curl-input');
        if (!input || !input.value.trim()) return;

        const data = await api.importCurl(input.value.trim());
        if (data.error) {
            setStatus('Import error: ' + data.error);
        } else {
            fillRequestFromParsed(data);
            setStatus('Imported from cURL');
        }
        hideModal();
    }

    async function importCurlFromPaste(curlCmd) {
        const data = await api.importCurl(curlCmd);
        if (!data.error) {
            fillRequestFromParsed(data);
            setStatus('Imported from pasted cURL');
        }
    }

    function fillRequestFromParsed(data) {
        if (data.method) {
            $('#method-select').value = data.method;
            state.method = data.method;
            updateMethodColor();
        }
        if (data.url) {
            $('#url-input').value = data.url;
        }
        if (data.headers) {
            clearTable('headers-table');
            Object.entries(data.headers).forEach(([k, v]) => {
                addKvRow('headers-table', k, v);
            });
        }
        if (data.body) {
            $('#body-editor').value = data.body;
            document.querySelector('input[name="body-type"][value="json"]').checked = true;
            switchReqTab('body');
        }
    }

    function showExportModal() {
        if (!state.response) {
            setStatus('Send a request first');
            return;
        }

        const formats = ['curl', 'python', 'javascript', 'go', 'ruby', 'php', 'rust', 'java', 'swift', 'kotlin'];

        showModal('Export Request', `
            <label>Format:</label>
            <select id="export-format" style="width:100%;padding:6px;margin-bottom:12px;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:4px;">
                ${formats.map(f => `<option value="${f}">${f.charAt(0).toUpperCase() + f.slice(1)}</option>`).join('')}
            </select>
            <label>Output:</label>
            <textarea id="export-output" readonly style="min-height:200px;"></textarea>
        `, [
            { label: 'Generate', primary: true, onclick: doExport },
            { label: 'Copy', onclick: copyExport },
            { label: 'Close', onclick: hideModal },
        ]);
    }

    async function doExport() {
        const format = $('#export-format').value;
        const voltContent = buildVoltContent();
        const result = await api.exportRequest(format, voltContent);
        const output = $('#export-output');
        if (output) {
            output.value = result.exported || result.error || 'Export failed';
        }
    }

    function copyExport() {
        const output = $('#export-output');
        if (output) {
            navigator.clipboard.writeText(output.value).then(() => setStatus('Copied to clipboard'));
        }
    }

    function buildVoltContent() {
        const method = state.method;
        const url = $('#url-input').value;
        let content = `${method} ${url}\n`;

        const headerRows = $$('#headers-table tbody tr');
        headerRows.forEach(row => {
            const inputs = row.querySelectorAll('input');
            if (inputs.length >= 2 && inputs[0].value) {
                content += `${inputs[0].value}: ${inputs[1].value}\n`;
            }
        });

        const bodyType = document.querySelector('input[name="body-type"]:checked').value;
        if (bodyType !== 'none' && $('#body-editor').value) {
            content += '\n' + $('#body-editor').value;
        }

        return content;
    }

    function saveAsVolt() {
        const content = buildVoltContent();
        const blob = new Blob([content], { type: 'text/plain' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'request.volt';
        a.click();
        URL.revokeObjectURL(a.href);
        setStatus('Saved as request.volt');
    }

    async function generateTests() {
        if (!state.response || !state.response.body) {
            setStatus('Send a request first to generate tests');
            return;
        }

        const body = typeof state.response.body === 'object'
            ? JSON.stringify(state.response.body)
            : state.response.body;

        const result = await api.generateTests(body);
        if (result.tests) {
            $('#tests-editor').value = result.tests;
            switchReqTab('tests');
            setStatus('Tests generated');
        } else {
            setStatus('Could not generate tests: ' + (result.error || ''));
        }
    }

    // ── File Drop Handler ───────────────────────────────────────────────
    function handleFileDrop(e) {
        e.preventDefault();
        const files = e.dataTransfer?.files;
        if (!files || files.length === 0) return;

        const file = files[0];
        const reader = new FileReader();

        reader.onload = async (evt) => {
            const content = evt.target.result;

            if (file.name.endsWith('.json')) {
                // Try Postman collection import
                try {
                    const json = JSON.parse(content);
                    if (json.info && json.item) {
                        // Postman collection format
                        setStatus('Imported Postman collection: ' + (json.info.name || file.name));
                        // Refresh collections
                        loadCollections();
                    }
                } catch {
                    setStatus('Invalid JSON file');
                }
            } else if (file.name.endsWith('.volt')) {
                const parsed = await api.parseVolt(content);
                if (!parsed.error) {
                    fillRequestFromParsed(parsed);
                    setStatus('Loaded: ' + file.name);
                }
            }

            hideModal();
        };

        reader.readAsText(file);
    }

    // ── Tab Switching ───────────────────────────────────────────────────
    function switchReqTab(tab) {
        state.activeReqTab = tab;
        $$('.req-tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
        $$('.req-panel').forEach(p => p.classList.toggle('active', p.id === 'panel-' + tab));
    }

    function switchRespTab(tab) {
        state.activeRespTab = tab;
        $$('.resp-tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
        $$('.resp-panel').forEach(p => p.classList.toggle('active', p.id === 'panel-' + tab));
    }

    function switchSidebarTab(tab) {
        state.activeSidebarTab = tab;
        $$('.sidebar-tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));

        if (tab === 'history-tab') {
            renderHistory();
        } else {
            renderCollections();
        }
    }

    function switchResponseView(view) {
        state.responseView = view;
        $$('.view-toggle').forEach(b => b.classList.toggle('active', b.dataset.view === view));
        if (state.response) renderResponseBody(state.response);
    }

    // ── Theme ───────────────────────────────────────────────────────────
    function applyTheme(theme) {
        state.theme = theme;
        document.documentElement.setAttribute('data-theme', theme);
        localStorage.setItem('volt-theme', theme);
        $('#theme-select').value = theme;
    }

    // ── Sidebar ─────────────────────────────────────────────────────────
    function toggleSidebar() {
        state.sidebarCollapsed = !state.sidebarCollapsed;
        const sidebar = $('#sidebar');
        const toggle = $('#sidebar-toggle');
        sidebar.classList.toggle('collapsed', state.sidebarCollapsed);
        toggle.innerHTML = state.sidebarCollapsed ? '&rsaquo;' : '&lsaquo;';

        // Update grid
        const layout = $('.main-layout');
        layout.style.gridTemplateColumns = state.sidebarCollapsed ? '0 1fr' : '260px 1fr';
    }

    // ── KV Table Helpers ────────────────────────────────────────────────
    function addKvRow(tableId, key, value) {
        const tbody = $(`#${tableId} tbody`);
        const tr = el('tr', {}, [
            el('td', {}, [el('input', { type: 'text', placeholder: 'Key', value: key || '' })]),
            el('td', {}, [el('input', { type: 'text', placeholder: 'Value', value: value || '' })]),
            el('td', {}, [el('button', { class: 'btn-remove', text: '\u00D7', onclick: () => tr.remove() })]),
        ]);
        tbody.appendChild(tr);
    }

    function clearTable(tableId) {
        $(`#${tableId} tbody`).innerHTML = '';
    }

    function addDefaultRows() {
        addKvRow('params-table');
        addKvRow('headers-table', 'Accept', 'application/json');
    }

    // ── Auth Fields ─────────────────────────────────────────────────────
    function updateAuthFields() {
        const container = $('#auth-fields');
        container.innerHTML = '';

        switch (state.authType) {
            case 'bearer':
                container.innerHTML = `
                    <label>Token</label>
                    <input type="text" id="auth-bearer-token" placeholder="Enter bearer token">
                `;
                break;
            case 'basic':
                container.innerHTML = `
                    <label>Username</label>
                    <input type="text" id="auth-basic-user" placeholder="Username">
                    <label>Password</label>
                    <input type="text" id="auth-basic-pass" placeholder="Password">
                `;
                break;
            case 'apikey':
                container.innerHTML = `
                    <label>Key</label>
                    <input type="text" id="auth-apikey-key" placeholder="X-API-Key">
                    <label>Value</label>
                    <input type="text" id="auth-apikey-value" placeholder="your-api-key">
                    <label>Add to</label>
                    <select id="auth-apikey-location" style="width:100%;padding:4px;background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:4px;">
                        <option value="header">Header</option>
                        <option value="query">Query Param</option>
                    </select>
                `;
                break;
        }
    }

    // ── Method Color ────────────────────────────────────────────────────
    function updateMethodColor() {
        const select = $('#method-select');
        const method = select.value.toLowerCase();
        select.style.color = `var(--method-${method})`;
    }

    // ── Modal ───────────────────────────────────────────────────────────
    function showModal(title, bodyHtml, buttons) {
        $('#modal-title').textContent = title;
        $('#modal-body').innerHTML = bodyHtml;

        const footer = $('#modal-footer');
        footer.innerHTML = '';
        (buttons || []).forEach(btn => {
            const button = el('button', {
                class: btn.primary ? 'btn-send' : 'btn-secondary',
                text: btn.label,
                onclick: btn.onclick,
            });
            footer.appendChild(button);
        });

        $('#modal-overlay').classList.add('visible');
    }

    function hideModal() {
        $('#modal-overlay').classList.remove('visible');
    }

    function showSettingsModal() {
        showModal('Settings', `
            <label>Base URL (prepended to relative URLs)</label>
            <input type="url" id="settings-base-url" placeholder="https://api.example.com">
            <label>Default Timeout (ms)</label>
            <input type="text" id="settings-timeout" value="30000">
            <label>Theme</label>
            <p style="color:var(--text-muted);font-size:0.8rem;">Use the theme selector in the toolbar</p>
        `, [
            { label: 'Save', primary: true, onclick: saveSettings },
            { label: 'Cancel', onclick: hideModal },
        ]);

        // Load current settings
        api.getConfig().then(config => {
            const baseUrl = $('#settings-base-url');
            const timeout = $('#settings-timeout');
            if (baseUrl && config.base_url) baseUrl.value = config.base_url;
            if (timeout && config.timeout) timeout.value = config.timeout;
        });
    }

    async function saveSettings() {
        const baseUrl = $('#settings-base-url')?.value || '';
        const timeout = $('#settings-timeout')?.value || '30000';

        await api.updateConfig({
            base_url: baseUrl,
            timeout: parseInt(timeout, 10),
            theme: state.theme,
        });

        setStatus('Settings saved');
        hideModal();
    }

    // ── Utility ─────────────────────────────────────────────────────────
    function newRequest() {
        $('#method-select').value = 'GET';
        state.method = 'GET';
        updateMethodColor();
        $('#url-input').value = '';
        clearTable('params-table');
        clearTable('headers-table');
        addDefaultRows();
        $('#body-editor').value = '';
        $('#tests-editor').value = '';
        document.querySelector('input[name="body-type"][value="none"]').checked = true;
        $('#auth-type').value = 'none';
        state.authType = 'none';
        updateAuthFields();
        clearResponse();
        state.activeFile = null;
        setStatus('New request');
        $('#url-input').focus();
    }

    function clearResponse() {
        state.response = null;
        $('#response-body').innerHTML = '<span class="placeholder">Send a request to see the response</span>';
        $('#response-headers-table tbody').innerHTML = '';
        $('#timing-waterfall').innerHTML = '';
        $('#test-results').innerHTML = '<span class="placeholder">Add tests in the request panel to see results</span>';
        $('#response-meta').classList.remove('visible');
        $('#response-empty').classList.remove('hidden');
    }

    function copyResponse() {
        if (!state.response) return;
        const body = typeof state.response.body === 'object'
            ? JSON.stringify(state.response.body, null, 2)
            : String(state.response.body);
        navigator.clipboard.writeText(body).then(() => setStatus('Response copied to clipboard'));
    }

    function showError(msg) {
        $('#response-body').innerHTML = '<span style="color:var(--error)">' + escapeHtml(msg) + '</span>';
        $('#response-empty').classList.add('hidden');
    }

    function setStatus(msg) {
        $('#status-message').textContent = msg;
    }

    function formatBytes(bytes) {
        if (bytes === 0) return '0 B';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
    }

    function escapeHtml(str) {
        return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    // ── Boot ────────────────────────────────────────────────────────────
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

    // Public API (for debugging)
    return { state, api, sendRequest, newRequest };
})();
