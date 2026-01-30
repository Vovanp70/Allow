// ========== DNSMASQ full ==========

// Загрузка статуса DNSMASQ full
async function loadDnsmasqStatus() {
    // Проверяем элементы на главной странице и на вкладке DNSMASQ full
    // Сначала проверяем вкладку, потом главную страницу
    let statusElement = document.getElementById('dnsmasq-full-status');
    if (!statusElement) {
        statusElement = document.getElementById('dnsmasq-status');
    }
    
    if (!statusElement) {
        console.log('loadDnsmasqStatus: элементы не найдены, пробуем через 100мс');
        // Пробуем еще раз через небольшую задержку
        await new Promise(resolve => setTimeout(resolve, 100));
        statusElement = document.getElementById('dnsmasq-full-status') || document.getElementById('dnsmasq-status');
        if (!statusElement) {
            console.log('loadDnsmasqStatus: элементы все еще не найдены');
            return; // Элементы не найдены, пропускаем
        }
    }
    
    console.log('loadDnsmasqStatus: начало загрузки статуса DNSMASQ, элемент найден:', statusElement.id);
    
    try {
        const data = await apiRequest('/dnsmasq/status');
        console.log('loadDnsmasqStatus: данные получены:', data);
        
        const portElement = document.getElementById('dnsmasq-full-port') || document.getElementById('dnsmasq-port');
        
        if (data && data.running) {
            statusElement.textContent = 'Запущен';
            statusElement.className = 'value status-running';
        } else {
            statusElement.textContent = 'Остановлен';
            statusElement.className = 'value status-stopped';
        }
        
        if (portElement) {
            portElement.textContent = (data && data.port) ? data.port : '-';
        }
        
        console.log('loadDnsmasqStatus: статус обновлен успешно, текст:', statusElement.textContent);
    } catch (error) {
        console.error('Ошибка загрузки статуса DNSMASQ:', error);
        if (statusElement) {
            statusElement.textContent = 'Ошибка';
            statusElement.className = 'value status-stopped';
        }
        const portElement = document.getElementById('dnsmasq-full-port') || document.getElementById('dnsmasq-port');
        if (portElement) {
            portElement.textContent = '-';
        }
    }
}

// Перезапустить DNSMASQ full (DNSMASQ всегда должен работать, остановка запрещена)
async function restartDnsmasq() {
    const statusElement = document.getElementById('dnsmasq-status') || document.getElementById('dnsmasq-full-status');
    const restartBtn = document.getElementById('dnsmasq-full-restart-btn') || document.getElementById('dnsmasq-restart-btn');
    
    if (!statusElement) return;
    
    // Отключаем кнопку во время перезапуска
    if (restartBtn) {
        restartBtn.disabled = true;
        restartBtn.textContent = 'Перезапуск...';
    }
    
    statusElement.textContent = 'Перезапуск...';
    statusElement.className = 'value status-checking';
    
    try {
        // Показываем прогресс-бар
        showProgress('Перезапуск DNSMASQ...');
        updateProgress(10);
        
        animateProgress(30, 300, 'Остановка службы...');
        
        const data = await apiRequest('/dnsmasq/restart', 'POST');
        
        if (data.success) {
            animateProgress(60, 300, 'Запуск службы...');
            
            setTimeout(() => {
                animateProgress(85, 500, 'Проверка статуса...');
            }, 1000);
            
            setTimeout(async () => {
                try {
                    await loadDnsmasqStatus();
                    animateProgress(100, 300, 'Готово');
                    showToast('DNSMASQ успешно перезапущен');
                    
                    setTimeout(() => {
                        hideProgress();
                        if (restartBtn) {
                            restartBtn.disabled = false;
                            restartBtn.textContent = 'Перезапустить';
                        }
                    }, 800);
                } catch (error) {
                    hideProgress();
                    if (restartBtn) {
                        restartBtn.disabled = false;
                        restartBtn.textContent = 'Перезапустить';
                    }
                    showToast('Перезапуск выполнен, но не удалось проверить статус');
                }
            }, 2000);
        } else {
            hideProgress();
            if (restartBtn) {
                restartBtn.disabled = false;
                restartBtn.textContent = 'Перезапустить';
            }
            showToast('Ошибка: ' + (data.error || data.message || 'Неизвестная ошибка'));
            loadDnsmasqStatus();
        }
    } catch (error) {
        hideProgress();
        if (restartBtn) {
            restartBtn.disabled = false;
            restartBtn.textContent = 'Перезапустить';
        }
        showToast('Ошибка при перезапуске: ' + error.message);
        loadDnsmasqStatus();
    }
}

// Загрузить конфигурацию DNSMASQ full для вкладки
async function loadDnsmasqFullConfig() {
    console.log('loadDnsmasqFullConfig: начало загрузки конфигурации');
    try {
        const data = await apiRequest('/dnsmasq/config');
        console.log('loadDnsmasqFullConfig: данные конфигурации получены:', data);
        
        // Заполняем редактируемые параметры
        const cacheSizeEl = document.getElementById('dnsmasq-full-cache-size');
        const minCacheTtlEl = document.getElementById('dnsmasq-full-min-cache-ttl');
        const maxCacheTtlEl = document.getElementById('dnsmasq-full-max-cache-ttl');
        const loggingEl = document.getElementById('dnsmasq-full-logging');
        
        if (data && data.editable) {
            if (cacheSizeEl) cacheSizeEl.value = data.editable['cache-size'] || '10000';
            if (minCacheTtlEl) minCacheTtlEl.value = data.editable['min-cache-ttl'] || '300';
            if (maxCacheTtlEl) maxCacheTtlEl.value = data.editable['max-cache-ttl'] || '3600';
        } else {
            // Если editable нет, используем значения по умолчанию
            if (cacheSizeEl) cacheSizeEl.value = '10000';
            if (minCacheTtlEl) minCacheTtlEl.value = '300';
            if (maxCacheTtlEl) maxCacheTtlEl.value = '3600';
        }
        
        if (loggingEl && data.logging_enabled !== undefined) {
            loggingEl.checked = data.logging_enabled || false;
        } else if (loggingEl && data.editable && data.editable.logging !== undefined) {
            loggingEl.checked = data.editable.logging || false;
        }
    } catch (error) {
        console.error('Ошибка при загрузке конфигурации DNSMASQ full:', error);
        // Не показываем toast для ошибки "Not found" - это нормально, если конфиг еще не создан
        if (error.message && !error.message.includes('Not found') && !error.message.includes('404')) {
            showToast('Ошибка при загрузке конфигурации: ' + error.message, 3000);
        }
        // Устанавливаем значения по умолчанию при ошибке
        const cacheSizeEl = document.getElementById('dnsmasq-full-cache-size');
        const minCacheTtlEl = document.getElementById('dnsmasq-full-min-cache-ttl');
        const maxCacheTtlEl = document.getElementById('dnsmasq-full-max-cache-ttl');
        
        if (cacheSizeEl) cacheSizeEl.value = '10000';
        if (minCacheTtlEl) minCacheTtlEl.value = '300';
        if (maxCacheTtlEl) maxCacheTtlEl.value = '3600';
    }
}

// Открыть модальное окно конфигурации DNSMASQ full (для системного монитора)
async function openDnsmasqConfigModal() {
    const modal = document.getElementById('dnsmasqConfigModal');
    modal.style.display = 'block';
    
    try {
        const data = await apiRequest('/dnsmasq/config');
        const loggingData = await apiRequest('/dnsmasq/status');
        
        // Заполняем редактируемые параметры
        if (data.editable) {
            const cacheSizeEl = document.getElementById('cache-size');
            const minCacheTtlEl = document.getElementById('min-cache-ttl');
            const maxCacheTtlEl = document.getElementById('max-cache-ttl');
            if (cacheSizeEl) cacheSizeEl.value = data.editable['cache-size'] || '10000';
            if (minCacheTtlEl) minCacheTtlEl.value = data.editable['min-cache-ttl'] || '300';
            if (maxCacheTtlEl) maxCacheTtlEl.value = data.editable['max-cache-ttl'] || '3600';
        }
        
        // Показываем полную конфигурацию для чтения
        const fullConfigEl = document.getElementById('dnsmasq-full-config');
        if (fullConfigEl && data.full_config) {
            fullConfigEl.value = data.full_config.join('\n');
        }
        
        const loggingEl = document.getElementById('dnsmasq-logging');
        if (loggingEl) {
            loggingEl.checked = loggingData.logging_enabled || false;
        }
    } catch (error) {
        showToast('Ошибка при загрузке конфигурации: ' + error.message, 3000);
        closeDnsmasqConfigModal();
    }
}

// Закрыть модальное окно конфигурации DNSMASQ full
function closeDnsmasqConfigModal() {
    const modal = document.getElementById('dnsmasqConfigModal');
    modal.style.display = 'none';
}

// Сохранить конфигурацию DNSMASQ full
async function saveDnsmasqConfig() {
    try {
        // Собираем редактируемые параметры (из вкладки или модального окна)
        const cacheSizeEl = document.getElementById('dnsmasq-full-cache-size') || document.getElementById('cache-size');
        const minCacheTtlEl = document.getElementById('dnsmasq-full-min-cache-ttl') || document.getElementById('min-cache-ttl');
        const maxCacheTtlEl = document.getElementById('dnsmasq-full-max-cache-ttl') || document.getElementById('max-cache-ttl');
        
        const configData = {
            'cache-size': cacheSizeEl ? cacheSizeEl.value : '10000',
            'min-cache-ttl': minCacheTtlEl ? minCacheTtlEl.value : '300',
            'max-cache-ttl': maxCacheTtlEl ? maxCacheTtlEl.value : '3600'
        };
        
        const loggingEl = document.getElementById('dnsmasq-full-logging') || document.getElementById('dnsmasq-logging');
        const loggingEnabled = loggingEl ? loggingEl.checked : false;
        
        // Добавляем логирование в данные конфигурации
        configData.logging = loggingEnabled;
        
        // Показываем прогресс-бар при сохранении
        showProgress('Сохранение конфигурации...');
        updateProgress(10);
        
        // Сохраняем конфигурацию
        let data;
        try {
            animateProgress(40, 400, 'Применение изменений...');
            data = await apiRequest('/dnsmasq/config', 'POST', configData);
        } catch (error) {
            hideProgress();
            throw error;
        }
        
        if (data.success) {
            // Если dnsmasq перезапускается, показываем прогресс перезапуска
            if (data.message && data.message.includes('restarted')) {
                animateProgress(60, 300, 'Перезапуск dnsmasq...');
                
                // Симулируем прогресс перезапуска
                setTimeout(() => {
                    animateProgress(85, 1000, 'Проверка статуса...');
                }, 800);
                
                // Ждем немного и проверяем статус
                setTimeout(async () => {
                    try {
                        await loadDnsmasqStatus();
                        animateProgress(100, 300, 'Готово');
                        showToast('Конфигурация успешно сохранена и применена');
                        
                        setTimeout(() => {
                            hideProgress();
                            const modal = document.getElementById('dnsmasqConfigModal');
                            if (modal && modal.style.display === 'block') {
                                closeDnsmasqConfigModal();
                            }
                            loadDnsmasqFullConfig();
                        }, 800);
                    } catch (error) {
                        hideProgress();
                        showToast('Конфигурация сохранена, но не удалось проверить статус');
                    }
                }, 2000);
            } else {
                // Обычное сохранение без перезапуска
                animateProgress(100, 400, 'Готово');
                setTimeout(() => {
                    hideProgress();
                    showToast('Конфигурация успешно сохранена');
                    const modal = document.getElementById('dnsmasqConfigModal');
                    if (modal && modal.style.display === 'block') {
                        closeDnsmasqConfigModal();
                    }
                    loadDnsmasqStatus();
                    loadDnsmasqFullConfig();
                }, 800);
            }
        } else {
            hideProgress();
            showToast('Ошибка при сохранении: ' + (data.error || data.message || 'Неизвестная ошибка'), 3000);
        }
    } catch (error) {
        showToast('Ошибка при сохранении конфигурации: ' + error.message, 3000);
    }
}

// Открыть логи DNSMASQ
async function openDnsmasqLogs() {
    openLogsViewer('Логи DNSMASQ', '/dnsmasq/logs');
}

// Очистить логи DNSMASQ
async function clearDnsmasqLogs() {
    try {
        const sizeData = await apiRequest('/dnsmasq/logs/size');
        const size = sizeData.size_formatted || '0 B';
        
        openConfirmModal(
            'Очистить логи DNSMASQ?',
            `Вы уверены, что хотите очистить логи DNSMASQ? Текущий размер: ${size}`,
            async () => {
                try {
                    const data = await apiRequest('/dnsmasq/logs/clear', 'POST');
                    if (data.success) {
                        showToast('Логи успешно очищены');
                        updateDnsmasqLogsSize();
                    } else {
                        showToast('Ошибка при очистке логов: ' + (data.error || 'Неизвестная ошибка'), 3000);
                    }
                } catch (error) {
                    showToast('Ошибка при очистке логов: ' + error.message, 3000);
                }
            }
        );
    } catch (error) {
        showToast('Ошибка при получении размера логов: ' + error.message, 3000);
    }
}

// Обновить размер логов DNSMASQ
async function updateDnsmasqLogsSize() {
    try {
        const data = await apiRequest('/dnsmasq/logs/size');
        const size = data.size_formatted || '0 B';
        const btn = document.getElementById('dnsmasq-clear-logs-btn');
        if (btn) {
            btn.textContent = `Очистить (${size})`;
        }
    } catch (error) {
        console.error('Ошибка при получении размера логов:', error);
    }
}

// Открыть редактор конфигурации DNSMASQ
function openDnsmasqConfigEditor() {
    // Используем путь к файлу конфигурации (может быть dnsmasq-full.conf или dnsmasq.conf)
    openConfigEditor(
        'Редактор конфигурации DNSMASQ',
        '/opt/etc/allow/dnsmasq-full/dnsmasq.conf',
        '/dnsmasq/config/full',
        '/dnsmasq/config/full'
    );
}

// Открыть модальное окно логов DNSMASQ full (legacy, для совместимости)
async function openDnsmasqLogsModal() {
    openDnsmasqLogs();
}

// Переключить режим редактирования полной конфигурации DNSMASQ (legacy, больше не используется)
function toggleDnsmasqFullEdit() {
    // Функция оставлена для совместимости, но больше не используется
    // Редактирование полной конфигурации теперь через openDnsmasqConfigEditor()
    openDnsmasqConfigEditor();
}

// Закрыть модальное окно логов DNSMASQ full
function closeDnsmasqLogsModal() {
    const modal = document.getElementById('dnsmasqLogsModal');
    modal.style.display = 'none';
}

// Загрузить логи DNSMASQ full
async function loadDnsmasqLogs() {
    try {
        const lines = parseInt(document.getElementById('dnsmasq-logs-lines').value) || 100;
        const data = await apiRequest(`/dnsmasq/logs?lines=${lines}`);
        
        // Показываем логи (даже если логирование выключено - показываем старые)
        if (data.logs && data.logs.length > 0) {
            document.getElementById('dnsmasq-logs-text').value = data.logs.join('\n');
        } else {
            const message = data.message || 'Логи пусты';
            document.getElementById('dnsmasq-logs-text').value = message;
        }
        
        // Показываем предупреждение, если логирование выключено
        if (data.warning) {
            showToast(data.warning, 5000);
        }
    } catch (error) {
        document.getElementById('dnsmasq-logs-text').value = 'Ошибка при загрузке логов: ' + error.message;
        showToast('Ошибка при загрузке логов: ' + error.message, 3000);
    }
}

// Инициализация при загрузке страницы DNSMASQ
document.addEventListener('DOMContentLoaded', async () => {
    // Проверяем, что мы на странице DNSMASQ
    if (document.getElementById('dnsmasq-full-status')) {
        await loadDnsmasqStatus();
        await loadDnsmasqFullConfig();
        await updateDnsmasqLogsSize();
        
        // Обновляем размер логов каждые 30 секунд
        setInterval(updateDnsmasqLogsSize, 30000);
    }
});



// ========== DNSMASQ Family ==========

// Загрузка статуса DNSMASQ Family (dashboard + страница)
async function loadDnsmasqFamilyStatus() {
    const statusElement = document.getElementById('dnsmasq-family-status');
    if (!statusElement) return;

    try {
        const data = await apiRequest('/dnsmasq-family/status');
        const portElement = document.getElementById('dnsmasq-family-port');

        if (data && data.running) {
            statusElement.textContent = 'Запущен';
            statusElement.className = 'value status-running';
        } else {
            statusElement.textContent = 'Остановлен';
            statusElement.className = 'value status-stopped';
        }

        if (portElement) {
            portElement.textContent = (data && data.port) ? data.port : '-';
        }
    } catch (error) {
        console.error('Ошибка загрузки статуса DNSMASQ Family:', error);
        statusElement.textContent = 'Ошибка';
        statusElement.className = 'value status-stopped';
        const portElement = document.getElementById('dnsmasq-family-port');
        if (portElement) portElement.textContent = '-';
    }
}


// Перезапуск DNSMASQ Family
async function restartDnsmasqFamily() {
    const statusElement = document.getElementById('dnsmasq-family-status');
    const restartBtn = document.getElementById('dnsmasq-family-restart-btn');
    if (!statusElement) return;

    if (restartBtn) {
        restartBtn.disabled = true;
        restartBtn.textContent = 'Перезапуск...';
    }
    statusElement.textContent = 'Перезапуск...';
    statusElement.className = 'value status-checking';

    try {
        showProgress('Перезапуск DNSMASQ Family...');
        updateProgress(10);
        animateProgress(35, 300, 'Перезапуск службы...');

        const data = await apiRequest('/dnsmasq-family/restart', 'POST');
        if (data && data.success) {
            animateProgress(85, 500, 'Проверка статуса...');
            setTimeout(async () => {
                await loadDnsmasqFamilyStatus();
                animateProgress(100, 300, 'Готово');
                showToast('DNSMASQ Family успешно перезапущен');
                setTimeout(() => {
                    hideProgress();
                    if (restartBtn) {
                        restartBtn.disabled = false;
                        restartBtn.textContent = 'Перезапустить';
                    }
                }, 800);
            }, 1500);
        } else {
            hideProgress();
            if (restartBtn) {
                restartBtn.disabled = false;
                restartBtn.textContent = 'Перезапустить';
            }
            showToast('Ошибка: ' + (data.error || data.message || 'Неизвестная ошибка'), 3000);
            loadDnsmasqFamilyStatus();
        }
    } catch (error) {
        hideProgress();
        if (restartBtn) {
            restartBtn.disabled = false;
            restartBtn.textContent = 'Перезапустить';
        }
        showToast('Ошибка при перезапуске: ' + error.message, 3000);
        loadDnsmasqFamilyStatus();
    }
}


// Загрузка конфигурации DNSMASQ Family для страницы
async function loadDnsmasqFamilyConfig() {
    try {
        const data = await apiRequest('/dnsmasq-family/config');

        const cacheSizeEl = document.getElementById('dnsmasq-family-cache-size');
        const minCacheTtlEl = document.getElementById('dnsmasq-family-min-cache-ttl');
        const maxCacheTtlEl = document.getElementById('dnsmasq-family-max-cache-ttl');
        const loggingEl = document.getElementById('dnsmasq-family-logging');

        if (data && data.editable) {
            if (cacheSizeEl) cacheSizeEl.value = data.editable['cache-size'] || '1536';
            if (minCacheTtlEl) minCacheTtlEl.value = data.editable['min-cache-ttl'] || '0';
            if (maxCacheTtlEl) maxCacheTtlEl.value = data.editable['max-cache-ttl'] || '0';
        }

        if (loggingEl) {
            if (data.logging_enabled !== undefined) {
                loggingEl.checked = !!data.logging_enabled;
            } else if (data.editable && data.editable.logging !== undefined) {
                loggingEl.checked = !!data.editable.logging;
            }
        }
    } catch (error) {
        console.error('Ошибка при загрузке конфигурации DNSMASQ Family:', error);
    }
}


// Сохранить конфигурацию DNSMASQ Family (редактируемые параметры)
async function saveDnsmasqFamilyConfig() {
    try {
        const cacheSizeEl = document.getElementById('dnsmasq-family-cache-size');
        const minCacheTtlEl = document.getElementById('dnsmasq-family-min-cache-ttl');
        const maxCacheTtlEl = document.getElementById('dnsmasq-family-max-cache-ttl');
        const loggingEl = document.getElementById('dnsmasq-family-logging');

        const configData = {
            'cache-size': cacheSizeEl ? cacheSizeEl.value : '1536',
            'min-cache-ttl': minCacheTtlEl ? minCacheTtlEl.value : '0',
            'max-cache-ttl': maxCacheTtlEl ? maxCacheTtlEl.value : '0',
            'logging': loggingEl ? !!loggingEl.checked : false
        };

        showProgress('Сохранение конфигурации (Family)...');
        updateProgress(10);
        animateProgress(40, 400, 'Применение изменений...');

        const data = await apiRequest('/dnsmasq-family/config', 'POST', configData);

        if (data && data.success) {
            animateProgress(85, 600, 'Проверка статуса...');
            setTimeout(async () => {
                await loadDnsmasqFamilyStatus();
                await loadDnsmasqFamilyConfig();
                await updateDnsmasqFamilyLogsSize();
                animateProgress(100, 300, 'Готово');
                showToast('Конфигурация DNSMASQ Family сохранена');
                setTimeout(() => hideProgress(), 600);
            }, 1200);
        } else {
            hideProgress();
            showToast('Ошибка при сохранении: ' + (data.error || data.message || 'Неизвестная ошибка'), 3000);
        }
    } catch (error) {
        hideProgress();
        showToast('Ошибка при сохранении конфигурации: ' + error.message, 3000);
    }
}


// Открыть редактор конфигурации DNSMASQ Family
function openDnsmasqFamilyConfigEditor() {
    openConfigEditor(
        'Редактор конфигурации DNSMASQ Family',
        '/opt/etc/allow/dnsmasq-full/dnsmasq-family.conf',
        '/dnsmasq-family/config/full',
        '/dnsmasq-family/config/full'
    );
}


// Логи DNSMASQ Family
async function openDnsmasqFamilyLogs() {
    openLogsViewer('Логи DNSMASQ Family', '/dnsmasq-family/logs');
}

async function updateDnsmasqFamilyLogsSize() {
    try {
        const data = await apiRequest('/dnsmasq-family/logs/size');
        const size = data.size_formatted || '0 B';
        const btn = document.getElementById('dnsmasq-family-clear-logs-btn');
        if (btn) {
            btn.textContent = `Очистить (${size})`;
        }
    } catch (error) {
        console.error('Ошибка при получении размера логов DNSMASQ Family:', error);
    }
}

async function clearDnsmasqFamilyLogs() {
    try {
        const sizeData = await apiRequest('/dnsmasq-family/logs/size');
        const size = sizeData.size_formatted || '0 B';

        openConfirmModal(
            'Очистить логи DNSMASQ Family?',
            `Вы уверены, что хотите очистить логи DNSMASQ Family? Текущий размер: ${size}`,
            async () => {
                try {
                    const data = await apiRequest('/dnsmasq-family/logs/clear', 'POST');
                    if (data.success) {
                        showToast('Логи успешно очищены');
                        updateDnsmasqFamilyLogsSize();
                    } else {
                        showToast('Ошибка при очистке логов: ' + (data.error || 'Неизвестная ошибка'), 3000);
                    }
                } catch (error) {
                    showToast('Ошибка при очистке логов: ' + error.message, 3000);
                }
            }
        );
    } catch (error) {
        showToast('Ошибка при получении размера логов: ' + error.message, 3000);
    }
}


// Инициализация при загрузке страницы DNSMASQ Family
document.addEventListener('DOMContentLoaded', async () => {
    if (document.getElementById('dnsmasq-family-cache-size')) {
        await loadDnsmasqFamilyStatus();
        await loadDnsmasqFamilyConfig();
        await updateDnsmasqFamilyLogsSize();
        setInterval(updateDnsmasqFamilyLogsSize, 30000);
    }
});

