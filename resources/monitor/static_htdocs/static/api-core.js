// Базовая конфигурация и общие утилиты для фронтенда System Monitor

// Конфигурация API (без токена: доступ только из локальной сети роутера)
const API_BASE = '/api';

// Функция для API запросов
async function apiRequest(endpoint, method = 'GET', body = null) {
    const options = {
        method: method,
        headers: { 'Content-Type': 'application/json' },
        credentials: 'same-origin'
    };
    if (body) {
        options.body = JSON.stringify(body);
    }

    // Эндпоинты конфиг-редактора через config.cgi вызываем напрямую, без префикса /api
    const url =
        endpoint.startsWith('/cgi-bin/')
            ? endpoint
            : `${API_BASE}${endpoint}`;

    const response = await fetch(url, options);
    const data = await response.json();

    if (!response.ok) {
        if (response.status === 401) {
            var isAuthEndpoint = (url.indexOf('/auth/login') !== -1) || (url.indexOf('/auth/logout') !== -1);
            if (!isAuthEndpoint) {
                var next = encodeURIComponent(location.pathname + location.search);
                location.href = '/login.html?next=' + next;
            }
            throw new Error(data.error || 'Unauthorized');
        }
        if (response.status === 404) {
            throw new Error(data.error || 'Not found');
        }
        throw new Error(data.error || data.message || 'Request failed');
    }
    return data;
}

// Показать всплывающее уведомление
function showToast(message, duration = 2000) {
    const toast = document.getElementById('toast');
    const toastMessage = document.getElementById('toast-message');
    if (!toast || !toastMessage) {
        console.warn('Toast elements not found');
        return;
    }
    toastMessage.textContent = message;
    toast.classList.add('show');
    
    setTimeout(() => {
        toast.classList.remove('show');
    }, duration);
}

// Общий обработчик кликов по фону для закрытия модальных окон
window.addEventListener('click', (event) => {
    const modalIds = [
        'configModal',
        'stubbyConfigModal',
        'stubbyLogsModal',
        'dnsmasqConfigModal',
        'dnsmasqLogsModal'
    ];
    
    modalIds.forEach((modalId) => {
        const modal = document.getElementById(modalId);
        if (modal && event.target === modal) {
            if (modalId === 'configModal' && typeof closeConfigModal === 'function') {
                closeConfigModal();
            } else if (modalId === 'stubbyConfigModal' && typeof closeStubbyConfigModal === 'function') {
                closeStubbyConfigModal();
            } else if (modalId === 'stubbyLogsModal' && typeof closeStubbyLogsModal === 'function') {
                closeStubbyLogsModal();
            } else if (modalId === 'dnsmasqConfigModal' && typeof closeDnsmasqConfigModal === 'function') {
                closeDnsmasqConfigModal();
            } else if (modalId === 'dnsmasqLogsModal' && typeof closeDnsmasqLogsModal === 'function') {
                closeDnsmasqLogsModal();
            }
        }
    });
});

// Функция форматирования чисел
function formatNumber(num) {
    if (num >= 1000000) {
        return (num / 1000000).toFixed(2) + 'M';
    } else if (num >= 1000) {
        return (num / 1000).toFixed(2) + 'K';
    }
    return num.toString();
}

// Функция форматирования байтов
function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

// Автообновление каждые 30 секунд
setInterval(() => {
    if (typeof loadSystemInfo === 'function') loadSystemInfo();
    if (typeof loadStubbyStatus === 'function') loadStubbyStatus();
    if (typeof loadStubbyFamilyStatus === 'function') loadStubbyFamilyStatus();
    if (typeof loadDnsmasqStatus === 'function') loadDnsmasqStatus();
    if (typeof loadDnsmasqFamilyStatus === 'function') loadDnsmasqFamilyStatus();
    if (typeof loadZapretStatus === 'function') loadZapretStatus();
}, 30000);

// Первоначальная загрузка (overlay до завершения — только дашборд; остальные страницы сами)
document.addEventListener('DOMContentLoaded', async () => {
    const loadFns = [];
    if (typeof loadSystemInfo === 'function') loadFns.push(loadSystemInfo);
    if (typeof loadStubbyStatus === 'function') loadFns.push(loadStubbyStatus);
    if (typeof loadStubbyFamilyStatus === 'function') loadFns.push(loadStubbyFamilyStatus);
    if (typeof loadDnsmasqStatus === 'function') loadFns.push(loadDnsmasqStatus);
    if (typeof loadDnsmasqFamilyStatus === 'function') loadFns.push(loadDnsmasqFamilyStatus);
    if (typeof loadZapretStatus === 'function') loadFns.push(loadZapretStatus);
    if (typeof loadChildrenFilterVisibility === 'function') loadFns.push(loadChildrenFilterVisibility);
    const isDashboard = !!document.getElementById('internet-status');
    if (loadFns.length > 0 && isDashboard && typeof showProgress === 'function') {
        showProgress('Загрузка...');
        try {
            await Promise.allSettled(loadFns.map(fn => fn()));
        } finally {
            if (typeof hideProgress === 'function') hideProgress();
        }
    } else if (loadFns.length > 0) {
        loadFns.forEach(fn => fn());
    }
});


