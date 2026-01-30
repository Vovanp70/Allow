// ========== SYSTEM INFO ==========

// Обновление общей информации (интернет + внешний IP)
async function loadSystemInfo() {
    // Элементы есть на dashboard (tab-system-monitor.html)
    let internetEl = document.getElementById('internet-status');
    let externalIpEl = document.getElementById('external-ip');

    if (!internetEl && !externalIpEl) {
        console.log('loadSystemInfo: элементы не найдены, пробуем через 100мс');
        await new Promise(resolve => setTimeout(resolve, 100));
        internetEl = document.getElementById('internet-status');
        externalIpEl = document.getElementById('external-ip');
        if (!internetEl && !externalIpEl) {
            console.log('loadSystemInfo: элементы все еще не найдены');
            return;
        }
    }

    if (internetEl) {
        internetEl.textContent = 'Проверка...';
        internetEl.className = 'value status-checking';
    }
    if (externalIpEl) {
        externalIpEl.textContent = '-';
        externalIpEl.className = 'value';
    }

    try {
        const data = await apiRequest('/system/info');
        console.log('loadSystemInfo: данные получены:', data);

        const isConnected = !!(data && data.internet && (data.internet.connected || data.internet.status));

        if (internetEl) {
            if (isConnected) {
                internetEl.textContent = 'Есть';
                internetEl.className = 'value status-running';
            } else {
                internetEl.textContent = 'Нет';
                internetEl.className = 'value status-stopped';
            }
        }

        if (externalIpEl) {
            const ip = (data && data.external_ip) ? String(data.external_ip).trim() : '';
            if (ip) {
                externalIpEl.textContent = ip;
            } else if (isConnected) {
                externalIpEl.textContent = 'Не удалось определить';
            } else {
                externalIpEl.textContent = '-';
            }
        }
    } catch (error) {
        console.error('Ошибка загрузки общей информации:', error);
        if (internetEl) {
            internetEl.textContent = 'Ошибка';
            internetEl.className = 'value status-stopped';
        }
        if (externalIpEl) {
            externalIpEl.textContent = '-';
        }
    }
}

// ========== System (Общая информация) ==========

// Загрузка общей информации о системе (интернет + внешний IP)
async function loadSystemInfo() {
    let internetEl = document.getElementById('internet-status');
    let ipEl = document.getElementById('external-ip');

    // Если DOM ещё не готов / вкладка не та — попробуем чуть позже
    if (!internetEl && !ipEl) {
        await new Promise(resolve => setTimeout(resolve, 100));
        internetEl = document.getElementById('internet-status');
        ipEl = document.getElementById('external-ip');
        if (!internetEl && !ipEl) return;
    }

    if (internetEl) {
        internetEl.textContent = 'Проверка...';
        internetEl.className = 'value status-checking';
    }
    if (ipEl) {
        ipEl.textContent = '-';
    }

    try {
        const data = await apiRequest('/system/info');
        const connected = !!(data && data.internet && (data.internet.connected || data.internet.status));
        const externalIp = data ? data.external_ip : null;

        if (internetEl) {
            if (connected) {
                internetEl.textContent = 'Есть';
                internetEl.className = 'value status-running';
            } else {
                internetEl.textContent = 'Нет';
                internetEl.className = 'value status-stopped';
            }
        }

        if (ipEl) {
            ipEl.textContent = externalIp ? externalIp : '-';
        }
    } catch (error) {
        console.error('Ошибка загрузки общей информации:', error);
        if (internetEl) {
            internetEl.textContent = 'Ошибка';
            internetEl.className = 'value status-stopped';
        }
        if (ipEl) {
            ipEl.textContent = '-';
        }
    }
}

