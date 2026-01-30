// Базовая конфигурация и общие утилиты для фронтенда System Monitor

// Конфигурация API
const API_BASE = '/api';
let AUTH_TOKEN = null;

// Навигация теперь происходит через ссылки, функция switchTab больше не нужна

// Получение токена при загрузке страницы
async function initAuth() {
    try {
        const response = await fetch('/api/auth-token');
        const data = await response.json();
        AUTH_TOKEN = data.token;
    } catch (error) {
        console.error('Failed to get auth token:', error);
        alert('Ошибка получения токена аутентификации');
    }
}

// Функция для API запросов
async function apiRequest(endpoint, method = 'GET', body = null) {
    if (!AUTH_TOKEN) {
        await initAuth();
    }
    
    const options = {
        method: method,
        headers: {
            'Content-Type': 'application/json',
            'X-Auth-Token': AUTH_TOKEN
        }
    };
    
    if (body) {
        options.body = JSON.stringify(body);
    }
    
    try {
        const response = await fetch(`${API_BASE}${endpoint}`, options);
        const data = await response.json();
        
        if (!response.ok) {
            if (response.status === 401) {
                // Токен неверный, попробуем получить заново
                await initAuth();
                // Повторный запрос
                options.headers['X-Auth-Token'] = AUTH_TOKEN;
                const retryResponse = await fetch(`${API_BASE}${endpoint}`, options);
                const retryData = await retryResponse.json();
                if (!retryResponse.ok) {
                    throw new Error(retryData.error || 'Request failed');
                }
                return retryData;
            }
            // Для 404 возвращаем более понятное сообщение
            if (response.status === 404) {
                throw new Error(data.error || 'Not found');
            }
            throw new Error(data.error || data.message || 'Request failed');
        }
        
        return data;
    } catch (error) {
        console.error('API request error:', error);
        throw error;
    }
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

// Первоначальная загрузка
document.addEventListener('DOMContentLoaded', async () => {
    await initAuth();
    if (typeof loadSystemInfo === 'function') loadSystemInfo();
    if (typeof loadStubbyStatus === 'function') loadStubbyStatus();
    if (typeof loadStubbyFamilyStatus === 'function') loadStubbyFamilyStatus();
    if (typeof loadDnsmasqStatus === 'function') loadDnsmasqStatus();
    if (typeof loadDnsmasqFamilyStatus === 'function') loadDnsmasqFamilyStatus();
    if (typeof loadZapretStatus === 'function') loadZapretStatus();
});


