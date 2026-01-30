// ========== STUBBY + STUBBY FAMILY ==========

function _setTextAndClass(el, text, className) {
    if (!el) return;
    el.textContent = text;
    if (className) el.className = className;
}

function _toggleDisplay(el, show) {
    if (!el) return;
    el.style.display = show ? 'inline-block' : 'none';
}

function _normalizeServiceStatus(data) {
    const running = !!(data && (data.running === true || data.status === 'running'));
    const port =
        (data && (data.effective_port ?? data.port ?? data.active_port ?? data.config_port)) || null;
    return { running, port };
}

async function _loadStubbyLikeStatus(opts) {
    const {
        statusEndpoint,
        statusElId,
        portElId,
        startBtnId,
        stopBtnId
    } = opts;

    let statusEl = document.getElementById(statusElId);
    let portEl = document.getElementById(portElId);

    if (!statusEl && !portEl) return;

    _setTextAndClass(statusEl, 'Проверка...', 'value status-checking');
    if (portEl) portEl.textContent = '-';

    try {
        const data = await apiRequest(statusEndpoint);
        const { running, port } = _normalizeServiceStatus(data);

        _setTextAndClass(
            statusEl,
            running ? 'Запущен' : 'Остановлен',
            running ? 'value status-running' : 'value status-stopped'
        );

        if (portEl) portEl.textContent = port ? String(port) : '-';

        const startBtn = startBtnId ? document.getElementById(startBtnId) : null;
        const stopBtn = stopBtnId ? document.getElementById(stopBtnId) : null;
        _toggleDisplay(startBtn, !running);
        _toggleDisplay(stopBtn, running);
    } catch (error) {
        console.error('Ошибка загрузки статуса Stubby:', error);
        _setTextAndClass(statusEl, 'Ошибка', 'value status-stopped');
        if (portEl) portEl.textContent = '-';
    }
}

// ---------- Status loaders ----------

async function loadStubbyStatus() {
    return _loadStubbyLikeStatus({
        statusEndpoint: '/stubby/status',
        statusElId: 'stubby-status',
        portElId: 'stubby-port',
        startBtnId: 'stubby-start-btn',
        stopBtnId: 'stubby-stop-btn'
    });
}

async function loadStubbyFamilyStatus() {
    return _loadStubbyLikeStatus({
        statusEndpoint: '/stubby-family/status',
        statusElId: 'stubby-family-status',
        portElId: 'stubby-family-port',
        startBtnId: 'stubby-family-start-btn',
        stopBtnId: 'stubby-family-stop-btn'
    });
}

// ---------- Actions (Stubby) ----------

async function _doServiceAction(opts) {
    const { actionEndpoint, loadingText, doneText, reloadFn, buttonIds = [] } = opts;

    const buttons = buttonIds.map((id) => document.getElementById(id)).filter(Boolean);
    buttons.forEach((b) => (b.disabled = true));

    try {
        if (typeof showProgress === 'function') {
            showProgress(loadingText || 'Обработка...');
            if (typeof animateProgress === 'function') animateProgress(35, 250);
        }

        const data = await apiRequest(actionEndpoint, 'POST');
        if (data && data.success === false) {
            throw new Error(data.error || data.message || 'Request failed');
        }

        if (typeof animateProgress === 'function') animateProgress(90, 250);
        if (typeof showToast === 'function' && doneText) showToast(doneText);
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    } finally {
        if (typeof animateProgress === 'function') animateProgress(100, 200);
        if (typeof hideProgress === 'function') setTimeout(hideProgress, 400);
        buttons.forEach((b) => (b.disabled = false));
        if (typeof reloadFn === 'function') {
            try {
                await reloadFn();
            } catch (_) {}
        }
    }
}

async function startStubby() {
    return _doServiceAction({
        actionEndpoint: '/stubby/start',
        loadingText: 'Запуск Stubby...',
        doneText: 'Stubby запущен',
        reloadFn: loadStubbyStatus,
        buttonIds: ['stubby-start-btn', 'stubby-stop-btn']
    });
}

async function stopStubby() {
    return _doServiceAction({
        actionEndpoint: '/stubby/stop',
        loadingText: 'Остановка Stubby...',
        doneText: 'Stubby остановлен',
        reloadFn: loadStubbyStatus,
        buttonIds: ['stubby-start-btn', 'stubby-stop-btn']
    });
}

async function restartStubby() {
    return _doServiceAction({
        actionEndpoint: '/stubby/restart',
        loadingText: 'Перезапуск Stubby...',
        doneText: 'Stubby перезапущен',
        reloadFn: loadStubbyStatus,
        buttonIds: ['stubby-restart-btn']
    });
}

// ---------- Actions (Stubby Family) ----------

async function startStubbyFamily() {
    return _doServiceAction({
        actionEndpoint: '/stubby-family/start',
        loadingText: 'Запуск Stubby Family...',
        doneText: 'Stubby Family запущен',
        reloadFn: loadStubbyFamilyStatus,
        buttonIds: ['stubby-family-start-btn', 'stubby-family-stop-btn']
    });
}

async function stopStubbyFamily() {
    return _doServiceAction({
        actionEndpoint: '/stubby-family/stop',
        loadingText: 'Остановка Stubby Family...',
        doneText: 'Stubby Family остановлен',
        reloadFn: loadStubbyFamilyStatus,
        buttonIds: ['stubby-family-start-btn', 'stubby-family-stop-btn']
    });
}

async function restartStubbyFamily() {
    return _doServiceAction({
        actionEndpoint: '/stubby-family/restart',
        loadingText: 'Перезапуск Stubby Family...',
        doneText: 'Stubby Family перезапущен',
        reloadFn: loadStubbyFamilyStatus,
        buttonIds: ['stubby-family-restart-btn']
    });
}

// ---------- Config wrappers ----------

function openStubbyConfigModal() {
    // Используем переиспользуемый editor (raw file) — см. /api/stubby/config/full
    if (typeof openConfigEditor === 'function') {
        openConfigEditor(
            'Конфигурация Stubby',
            '/opt/etc/allow/stubby/stubby.yml',
            '/stubby/config/full',
            '/stubby/config/full'
        );
    }
}

function openStubbyFamilyConfigModal() {
    if (typeof openConfigEditor === 'function') {
        openConfigEditor(
            'Конфигурация Stubby Family',
            '/opt/etc/allow/stubby/stubby-family.yml',
            '/stubby-family/config/full',
            '/stubby-family/config/full'
        );
    }
}

