// ========== SING-BOX ==========

function _setSingboxTextAndClass(el, text, className) {
    if (!el) return;
    el.textContent = text;
    if (className) el.className = className;
}

function _toggleSingboxDisplay(el, show) {
    if (!el) return;
    el.style.display = show ? 'inline-block' : 'none';
}

async function loadSingboxStatus() {
    const statusEl = document.getElementById('singbox-status');
    const pidEl = document.getElementById('singbox-pid');
    const startBtn = document.getElementById('singbox-start-btn');
    const stopBtn = document.getElementById('singbox-stop-btn');
    const restartBtn = document.getElementById('singbox-restart-btn');

    if (!statusEl && !pidEl) return;

    if (statusEl) _setSingboxTextAndClass(statusEl, 'Проверка...', 'value status-checking');
    if (pidEl) pidEl.textContent = '-';

    try {
        const data = await apiRequest('/singbox/status');
        const running = !!(data && (data.running === true || data.status === 'running'));
        const autostartActive = !!(data && data.autostart_active === true);
        const pid = (data && data.pid) ? String(data.pid).trim() : '';

        if (statusEl) {
            if (!autostartActive && !running) {
                _setSingboxTextAndClass(statusEl, 'Отключен', 'value status-disabled');
            } else {
                _setSingboxTextAndClass(
                    statusEl,
                    running ? 'Запущен' : 'Остановлен',
                    running ? 'value status-running' : 'value status-stopped'
                );
            }
        }
        const toggleBtn = document.getElementById('singbox-toggle-autostart-btn');
        if (toggleBtn) toggleBtn.textContent = autostartActive ? 'Отключить' : 'Включить';
        if (pidEl) pidEl.textContent = pid || '-';

        const disabled = !autostartActive && !running;
        _toggleSingboxDisplay(startBtn, !running);
        _toggleSingboxDisplay(stopBtn, running);
        _toggleSingboxDisplay(restartBtn, !disabled);

        // Обновляем переключатель логирования
        try {
            const logData = await apiRequest('/singbox/logging');
            const loggingEl = document.getElementById('singbox-logging');
            if (loggingEl && typeof logData.enabled === 'boolean') {
                loggingEl.checked = logData.enabled;
            }
        } catch (e) {
            console.warn('Не удалось загрузить состояние логирования Sing-box:', e);
        }
    } catch (error) {
        console.error('Ошибка загрузки статуса Sing-box:', error);
        if (statusEl) _setSingboxTextAndClass(statusEl, 'Ошибка', 'value status-stopped');
        if (pidEl) pidEl.textContent = '-';
        _toggleSingboxDisplay(startBtn, true);
        _toggleSingboxDisplay(stopBtn, false);
        _toggleSingboxDisplay(restartBtn, true);
    }
}

async function _doSingboxAction(endpoint, loadingText, doneText) {
    const startBtn = document.getElementById('singbox-start-btn');
    const stopBtn = document.getElementById('singbox-stop-btn');
    const restartBtn = document.getElementById('singbox-restart-btn');
    const buttons = [startBtn, stopBtn, restartBtn].filter(Boolean);
    buttons.forEach((b) => (b.disabled = true));

    try {
        if (typeof showProgress === 'function') {
            showProgress(loadingText || 'Обработка...');
            if (typeof animateProgress === 'function') animateProgress(35, 250);
        }

        const data = await apiRequest(endpoint, 'POST');
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
        try {
            await loadSingboxStatus();
        } catch (_) {}
    }
}

async function startSingbox() {
    return _doSingboxAction('/singbox/start', 'Запуск Sing-box...', 'Sing-box запущен');
}

async function stopSingbox() {
    return _doSingboxAction('/singbox/stop', 'Остановка Sing-box...', 'Sing-box остановлен');
}

async function restartSingbox() {
    return _doSingboxAction('/singbox/restart', 'Перезапуск Sing-box...', 'Sing-box перезапущен');
}

async function toggleSingboxAutostart() {
    const toggleBtn = document.getElementById('singbox-toggle-autostart-btn');
    if (toggleBtn) toggleBtn.disabled = true;
    try {
        const statusData = await apiRequest('/singbox/status');
        const autostartActive = statusData && statusData.autostart_active === true;
        const action = autostartActive ? 'deactivate' : 'activate';
        if (typeof showProgress === 'function') showProgress(autostartActive ? 'Отключение Sing-box...' : 'Включение Sing-box...');
        const data = await apiRequest('/singbox/autostart', 'POST', { action });
        if (data.success) {
            if (typeof showToast === 'function') showToast(data.message || (autostartActive ? 'Sing-box отключен' : 'Sing-box включен'));
            await loadSingboxStatus();
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

function openSingboxLogs() {
    if (typeof openLogsViewer === 'function') {
        openLogsViewer('Логи Sing-box', '/singbox/logs');
    }
}

// Обновить размер логов Sing-box (подпись кнопки «Очистить»)
async function updateSingboxLogsSize() {
    try {
        const data = await apiRequest('/singbox/logs/size');
        const size = data.size_formatted || '0 B';
        const btn = document.getElementById('singbox-clear-logs-btn');
        if (btn) btn.textContent = `Очистить (${size})`;
    } catch (error) {
        console.error('Ошибка при получении размера логов Sing-box:', error);
    }
}

async function clearSingboxLogs() {
    try {
        const data = await apiRequest('/singbox/logs/clear', 'POST');
        if (data && data.success) {
            if (typeof showToast === 'function') showToast('Логи Sing-box очищены');
            updateSingboxLogsSize();
        } else {
            if (typeof showToast === 'function') showToast('Ошибка при очистке логов Sing-box', 3000);
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    }
}

// Сохранение логирования по кнопке (как на Dnsmasq)
async function saveSingboxLogging() {
    const loggingEl = document.getElementById('singbox-logging');
    if (!loggingEl) return;
    const enabled = !!loggingEl.checked;
    try {
        const data = await apiRequest('/singbox/logging', 'POST', { enabled });
        if (data && data.success === false) {
            throw new Error(data.message || 'Request failed');
        }
        if (typeof showToast === 'function') {
            showToast(enabled ? 'Логирование Sing-box включено' : 'Логирование Sing-box выключено');
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    }
}

window.saveSingboxLogging = saveSingboxLogging;

async function onSingboxLoggingToggle(event) {
    const enabled = !!event.target.checked;
    try {
        const data = await apiRequest('/singbox/logging', 'POST', { enabled });
        if (data && data.success === false) {
            throw new Error(data.message || 'Request failed');
        }
        if (typeof showToast === 'function') {
            showToast(enabled ? 'Логирование Sing-box включено' : 'Логирование Sing-box выключено');
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
        // Откатываем переключатель
        event.target.checked = !enabled;
    }
}

const SINGBOX_CONFIG_GET  = '/cgi-bin/config.cgi/sing-box/config/full';
const SINGBOX_CONFIG_POST = '/cgi-bin/config.cgi/sing-box/config/full';

function openSingboxConfigEditor() {
    if (typeof openConfigEditor === 'function') {
        openConfigEditor(
            'Конфигурация Sing-box',
            '/opt/etc/allow/sing-box/config.json',
            SINGBOX_CONFIG_GET,
            SINGBOX_CONFIG_POST
        );
    }
}

// --- Роутинг по марке (route-by-mark) ---
async function loadRouteByMarkMarks() {
    const selectEl = document.getElementById('singbox-route-by-mark-select');
    if (!selectEl) return;
    selectEl.innerHTML = '<option value="">— загрузка —</option>';
    try {
        const data = await apiRequest('/singbox/route-by-mark/marks');
        const marks = Array.isArray(data.marks) ? data.marks : [];
        selectEl.innerHTML = '<option value="">— выбрать марку —</option>';
        marks.forEach(function (m) {
            const opt = document.createElement('option');
            opt.value = m;
            opt.textContent = m;
            selectEl.appendChild(opt);
        });
    } catch (e) {
        selectEl.innerHTML = '<option value="">Ошибка загрузки</option>';
        console.warn('Route-by-mark marks:', e);
    }
}

async function loadRouteByMarkStatus() {
    const statusEl = document.getElementById('singbox-route-by-mark-status');
    const enableBtn = document.getElementById('singbox-route-by-mark-enable-btn');
    const disableBtn = document.getElementById('singbox-route-by-mark-disable-btn');
    const selectEl = document.getElementById('singbox-route-by-mark-select');
    if (statusEl) statusEl.textContent = '';
    try {
        const data = await apiRequest('/singbox/route-by-mark/status');
        const current = (data.current_mark || '').trim();
        const enabled = current && current !== 'nomark';
        if (enableBtn) enableBtn.style.display = enabled ? 'none' : '';
        if (disableBtn) disableBtn.style.display = enabled ? '' : 'none';
        if (selectEl) {
            selectEl.style.display = '';
            if (enabled && current) {
                if (!Array.prototype.find.call(selectEl.options, function (o) { return o.value === current; })) {
                    const opt = document.createElement('option');
                    opt.value = current;
                    opt.textContent = current;
                    selectEl.appendChild(opt);
                }
                selectEl.value = current;
                selectEl.classList.add('route-by-mark-selected');
            } else {
                selectEl.classList.remove('route-by-mark-selected');
            }
        }
    } catch (e) {
        if (enableBtn) enableBtn.style.display = '';
        if (disableBtn) disableBtn.style.display = '';
        if (selectEl) {
            selectEl.style.display = '';
            selectEl.classList.remove('route-by-mark-selected');
        }
    }
}

async function routeByMarkEnable() {
    const selectEl = document.getElementById('singbox-route-by-mark-select');
    const enableBtn = document.getElementById('singbox-route-by-mark-enable-btn');
    const disableBtn = document.getElementById('singbox-route-by-mark-disable-btn');
    const mark = selectEl && selectEl.value ? selectEl.value.trim() : '';
    if (!mark) {
        if (typeof showToast === 'function') showToast('Выберите марку', 2500);
        return;
    }
    if (enableBtn) enableBtn.disabled = true;
    if (disableBtn) disableBtn.disabled = true;
    try {
        if (typeof showProgress === 'function') {
            showProgress('Включение роутинга по марке...');
            if (typeof animateProgress === 'function') animateProgress(50, 200);
        }
        const data = await apiRequest('/singbox/route-by-mark', 'POST', { action: 'addmark', mark: mark });
        if (data && data.success !== false) {
            if (typeof showToast === 'function') showToast('Роутинг по марке ' + mark + ' включён');
            loadRouteByMarkStatus();
        } else {
            if (typeof showToast === 'function') showToast('Ошибка: ' + (data.error || data.message || 'Неизвестная ошибка'), 3000);
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
        if (typeof animateProgress === 'function') animateProgress(100, 100);
        if (enableBtn) enableBtn.disabled = false;
        if (disableBtn) disableBtn.disabled = false;
    }
}

async function routeByMarkDisable() {
    const enableBtn = document.getElementById('singbox-route-by-mark-enable-btn');
    const disableBtn = document.getElementById('singbox-route-by-mark-disable-btn');
    if (enableBtn) enableBtn.disabled = true;
    if (disableBtn) disableBtn.disabled = true;
    try {
        if (typeof showProgress === 'function') {
            showProgress('Выключение роутинга по марке...');
            if (typeof animateProgress === 'function') animateProgress(50, 200);
        }
        const data = await apiRequest('/singbox/route-by-mark', 'POST', { action: 'delmark' });
        if (data && data.success !== false) {
            if (typeof showToast === 'function') showToast('Роутинг по марке выключен');
            loadRouteByMarkStatus();
        } else {
            if (typeof showToast === 'function') showToast('Ошибка: ' + (data.error || data.message || 'Неизвестная ошибка'), 3000);
        }
    } catch (error) {
        if (typeof showToast === 'function') showToast('Ошибка: ' + error.message, 3000);
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
        if (typeof animateProgress === 'function') animateProgress(100, 100);
        if (enableBtn) enableBtn.disabled = false;
        if (disableBtn) disableBtn.disabled = false;
    }
}

window.routeByMarkEnable = routeByMarkEnable;
window.routeByMarkDisable = routeByMarkDisable;

function openMarkRulesModal() {
    const modal = document.getElementById('markRulesModal');
    if (modal) {
        modal.style.display = 'block';
        loadMarkRulesModal();
    }
}

function closeMarkRulesModal() {
    const modal = document.getElementById('markRulesModal');
    if (modal) modal.style.display = 'none';
}

async function loadMarkRulesModal() {
    const textEl = document.getElementById('markRulesModalText');
    if (!textEl) return;
    textEl.value = 'Загрузка...';
    try {
        const data = await apiRequest('/singbox/route-by-mark/iptables-rules');
        const lines = Array.isArray(data.lines) ? data.lines : [];
        textEl.value = lines.length ? lines.join('\n') : (data.output || '(пусто)');
    } catch (e) {
        textEl.value = 'Ошибка: ' + (e.message || 'не удалось загрузить');
    }
}

window.openMarkRulesModal = openMarkRulesModal;
window.closeMarkRulesModal = closeMarkRulesModal;
window.loadMarkRulesModal = loadMarkRulesModal;

// Вызов при загрузке страницы (дашборд или страница Sing-box)
function initSingboxPage() {
    loadSingboxStatus();
    const clearBtn = document.getElementById('singbox-clear-logs-btn');
    if (clearBtn) {
        updateSingboxLogsSize();
        setInterval(updateSingboxLogsSize, 30000);
    }
    const routeByMarkSelect = document.getElementById('singbox-route-by-mark-select');
    if (routeByMarkSelect) {
        loadRouteByMarkMarks().then(function () { return loadRouteByMarkStatus(); });
    }
}
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initSingboxPage);
} else {
    initSingboxPage();
}
