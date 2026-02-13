// ========== STUBBY + STUBBY FAMILY ==========

let _updatingStubbyLoggingFromApi = false;

// ---------- Logs (определены первыми для onclick в HTML) ----------
function openStubbyLogs() {
    if (typeof openLogsViewer === 'function') {
        openLogsViewer('Логи Stubby', '/stubby/logs');
    }
}

function openStubbyFamilyLogs() {
    if (typeof openLogsViewer === 'function') {
        openLogsViewer('Логи Stubby Family', '/stubby-family/logs');
    }
}

async function clearStubbyLogs() {
    if (typeof openConfirmModal !== 'function') {
        try {
            const data = await apiRequest('/stubby/logs/clear', 'POST');
            if (data && data.success) {
                if (typeof showToast === 'function') showToast('Логи очищены');
                updateStubbyLogsSize();
            } else {
                if (typeof showToast === 'function') showToast('Ошибка при очистке логов', 3000);
            }
        } catch (error) {
            if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
        }
        return;
    }
    openConfirmModal(
        'Очистить логи Stubby?',
        'Вы уверены, что хотите очистить логи Stubby?',
        async () => {
            try {
                const data = await apiRequest('/stubby/logs/clear', 'POST');
                if (data && data.success) {
                    if (typeof showToast === 'function') showToast('Логи очищены');
                    updateStubbyLogsSize();
                } else {
                    if (typeof showToast === 'function') showToast('Ошибка при очистке логов', 3000);
                }
            } catch (error) {
                if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
            }
        }
    );
}

async function clearStubbyFamilyLogs() {
    if (typeof openConfirmModal !== 'function') {
        try {
            const data = await apiRequest('/stubby-family/logs/clear', 'POST');
            if (data && data.success) {
                if (typeof showToast === 'function') showToast('Логи очищены');
                updateStubbyFamilyLogsSize();
            } else {
                if (typeof showToast === 'function') showToast('Ошибка при очистке логов', 3000);
            }
        } catch (error) {
            if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
        }
        return;
    }
    openConfirmModal(
        'Очистить логи Stubby Family?',
        'Вы уверены, что хотите очистить логи Stubby Family?',
        async () => {
            try {
                const data = await apiRequest('/stubby-family/logs/clear', 'POST');
                if (data && data.success) {
                    if (typeof showToast === 'function') showToast('Логи очищены');
                    updateStubbyFamilyLogsSize();
                } else {
                    if (typeof showToast === 'function') showToast('Ошибка при очистке логов', 3000);
                }
            } catch (error) {
                if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
            }
        }
    );
}

window.openStubbyLogs = openStubbyLogs;
window.openStubbyFamilyLogs = openStubbyFamilyLogs;
window.clearStubbyLogs = clearStubbyLogs;
window.clearStubbyFamilyLogs = clearStubbyFamilyLogs;

// Обновить размер логов Stubby (подпись кнопки «Очистить»)
async function updateStubbyLogsSize() {
    try {
        const data = await apiRequest('/stubby/logs/size');
        const size = data.size_formatted || '0 B';
        const btn = document.getElementById('stubby-clear-logs-btn');
        if (btn) btn.textContent = `Очистить (${size})`;
    } catch (error) {
        console.error('Ошибка при получении размера логов Stubby:', error);
    }
}

// Обновить размер логов Stubby Family (подпись кнопки «Очистить»)
async function updateStubbyFamilyLogsSize() {
    try {
        const data = await apiRequest('/stubby-family/logs/size');
        const size = data.size_formatted || '0 B';
        const btn = document.getElementById('stubby-family-clear-logs-btn');
        if (btn) btn.textContent = `Очистить (${size})`;
    } catch (error) {
        console.error('Ошибка при получении размера логов Stubby Family:', error);
    }
}

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
    const loggingEnabled = !!(data && data.logging_enabled === true);
    return { running, port, loggingEnabled };
}

async function _loadStubbyLikeStatus(opts) {
    const {
        statusEndpoint,
        statusElId,
        portElId,
        startBtnId,
        stopBtnId,
        restartBtnId,
        toggleBtnId,
        loggingElId
    } = opts;

    let statusEl = document.getElementById(statusElId);
    let portEl = document.getElementById(portElId);

    if (!statusEl && !portEl) return;

    _setTextAndClass(statusEl, 'Проверка...', 'value status-checking');
    if (portEl) portEl.textContent = '-';

    try {
        const data = await apiRequest(statusEndpoint);
        const { running, port, loggingEnabled } = _normalizeServiceStatus(data);
        const autostartActive = !!(data && data.autostart_active === true);

        if (!autostartActive && !running) {
            _setTextAndClass(statusEl, 'Отключен', 'value status-disabled');
        } else {
            _setTextAndClass(
                statusEl,
                running ? 'Запущен' : 'Остановлен',
                running ? 'value status-running' : 'value status-stopped'
            );
        }

        if (toggleBtnId) {
            const toggleBtn = document.getElementById(toggleBtnId);
            if (toggleBtn) toggleBtn.textContent = autostartActive ? 'Отключить' : 'Включить';
        }

        if (portEl) portEl.textContent = port ? String(port) : '-';

        const startBtn = startBtnId ? document.getElementById(startBtnId) : null;
        const stopBtn = stopBtnId ? document.getElementById(stopBtnId) : null;
        _toggleDisplay(startBtn, !running);
        _toggleDisplay(stopBtn, running);

        if (restartBtnId) {
            const restartBtn = document.getElementById(restartBtnId);
            if (restartBtn) restartBtn.style.display = (!autostartActive && !running) ? 'none' : 'inline-block';
        }

        if (loggingElId) {
            const loggingEl = document.getElementById(loggingElId);
            if (loggingEl) {
                _updatingStubbyLoggingFromApi = true;
                loggingEl.checked = loggingEnabled;
                _updatingStubbyLoggingFromApi = false;
            }
        }
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
        stopBtnId: 'stubby-stop-btn',
        restartBtnId: 'stubby-restart-btn',
        toggleBtnId: 'stubby-toggle-autostart-btn',
        loggingElId: 'stubby-logging'
    });
}

async function loadStubbyFamilyStatus() {
    return _loadStubbyLikeStatus({
        statusEndpoint: '/stubby-family/status',
        statusElId: 'stubby-family-status',
        portElId: 'stubby-family-port',
        startBtnId: 'stubby-family-start-btn',
        stopBtnId: 'stubby-family-stop-btn',
        restartBtnId: 'stubby-family-restart-btn',
        toggleBtnId: 'stubby-family-toggle-autostart-btn',
        loggingElId: 'stubby-family-logging'
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

async function toggleStubbyAutostart() {
    const toggleBtn = document.getElementById('stubby-toggle-autostart-btn');
    if (toggleBtn) toggleBtn.disabled = true;
    try {
        const statusData = await apiRequest('/stubby/status');
        const autostartActive = statusData && statusData.autostart_active === true;
        const action = autostartActive ? 'deactivate' : 'activate';
        if (typeof showProgress === 'function') showProgress(autostartActive ? 'Отключение Stubby...' : 'Включение Stubby...');
        const data = await apiRequest('/stubby/autostart', 'POST', { action });
        if (data.success) {
            if (typeof showToast === 'function') showToast(data.message || (autostartActive ? 'Stubby отключен' : 'Stubby включен'));
            await loadStubbyStatus();
        } else {
            if (typeof showToast === 'function') showToast('Ошибка: ' + (data.error || data.message || 'Неизвестная ошибка'), 3000);
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
        if (toggleBtn) toggleBtn.disabled = false;
    }
}

async function toggleStubbyFamilyAutostart() {
    const toggleBtn = document.getElementById('stubby-family-toggle-autostart-btn');
    if (toggleBtn) toggleBtn.disabled = true;
    try {
        const statusData = await apiRequest('/stubby-family/status');
        const autostartActive = statusData && statusData.autostart_active === true;
        const action = autostartActive ? 'deactivate' : 'activate';
        if (typeof showProgress === 'function') showProgress(autostartActive ? 'Отключение Stubby Family...' : 'Включение Stubby Family...');
        const data = await apiRequest('/stubby-family/autostart', 'POST', { action });
        if (data.success) {
            if (typeof showToast === 'function') showToast(data.message || (autostartActive ? 'Stubby Family отключен' : 'Stubby Family включен'));
            await loadStubbyFamilyStatus();
        } else {
            if (typeof showToast === 'function') showToast('Ошибка: ' + (data.error || data.message || 'Неизвестная ошибка'), 3000);
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
        if (toggleBtn) toggleBtn.disabled = false;
    }
}

// ---------- Logging toggle ----------

async function setStubbyLogging(enabled) {
    try {
        const data = await apiRequest('/stubby/logging', 'POST', { enabled });
        if (data && data.success) {
            if (typeof showToast === 'function') showToast(data.message || (enabled ? 'Логирование включено' : 'Логирование выключено'));
            loadStubbyStatus();
        } else {
            if (typeof showToast === 'function') showToast('Ошибка: ' + (data && data.message ? data.message : 'Не удалось изменить логирование'), 3000);
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    }
}

async function setStubbyFamilyLogging(enabled) {
    try {
        const data = await apiRequest('/stubby-family/logging', 'POST', { enabled });
        if (data && data.success) {
            if (typeof showToast === 'function') showToast(data.message || (enabled ? 'Логирование включено' : 'Логирование выключено'));
            loadStubbyFamilyStatus();
        } else {
            if (typeof showToast === 'function') showToast('Ошибка: ' + (data && data.message ? data.message : 'Не удалось изменить логирование'), 3000);
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    }
}

// Сохранение настроек логирования по кнопке (как на странице Dnsmasq)
async function saveStubbyLogging() {
    const loggingEl = document.getElementById('stubby-logging');
    if (!loggingEl) return;
    if (_updatingStubbyLoggingFromApi) return;
    await setStubbyLogging(loggingEl.checked);
}

async function saveStubbyFamilyLogging() {
    const loggingEl = document.getElementById('stubby-family-logging');
    if (!loggingEl) return;
    if (_updatingStubbyLoggingFromApi) return;
    await setStubbyFamilyLogging(loggingEl.checked);
}

window.saveStubbyLogging = saveStubbyLogging;
window.saveStubbyFamilyLogging = saveStubbyFamilyLogging;

// ---------- Config wrappers ----------

function openStubbyConfigModal() {
    // Используем переиспользуемый editor (raw file) — см. /api/stubby/config/full
    if (typeof openConfigEditor === 'function') {
        openConfigEditor(
            'Конфигурация Stubby',
            '/opt/etc/allow/stubby/stubby.yml',
            '/cgi-bin/config.cgi/stubby/config/full',
            '/cgi-bin/config.cgi/stubby/config/full'
        );
    }
}

function openStubbyFamilyConfigModal() {
    if (typeof openConfigEditor === 'function') {
        openConfigEditor(
            'Конфигурация Stubby Family',
            '/opt/etc/allow/stubby/stubby-family.yml',
            '/cgi-bin/config.cgi/stubby-family/config/full',
            '/cgi-bin/config.cgi/stubby-family/config/full'
        );
    }
}

// ---------- Page init: load status and bind logging toggle ----------

document.addEventListener('DOMContentLoaded', async () => {
    const stubbyStatusEl = document.getElementById('stubby-status');
    const stubbyFamilyStatusEl = document.getElementById('stubby-family-status');
    if (!stubbyStatusEl && !stubbyFamilyStatusEl) return;
    if (typeof showProgress === 'function') showProgress('Загрузка...');
    try {
        const promises = [];
        if (stubbyStatusEl) {
            promises.push(loadStubbyStatus());
            updateStubbyLogsSize();
            setInterval(updateStubbyLogsSize, 30000);
        }
        if (stubbyFamilyStatusEl) {
            promises.push(loadStubbyFamilyStatus());
            updateStubbyFamilyLogsSize();
            setInterval(updateStubbyFamilyLogsSize, 30000);
        }
        await Promise.allSettled(promises);
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
    }
});
