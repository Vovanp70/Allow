// Переиспользуемый компонент просмотра логов

let currentLogsViewer = {
    title: '',
    apiEndpoint: '',
    warning: null
};

// Открыть просмотр логов
function openLogsViewer(title, apiEndpoint, warning = null) {
    currentLogsViewer = {
        title: title,
        apiEndpoint: apiEndpoint,
        warning: warning
    };
    
    const modal = document.getElementById('logsViewerModal');
    const titleEl = document.getElementById('logsViewerTitle');
    const warningEl = document.getElementById('logsViewerWarning');
    const textEl = document.getElementById('logsViewerText');
    
    titleEl.textContent = title;
    warningEl.textContent = warning || '';
    textEl.value = 'Загрузка...';
    modal.style.display = 'block';
    
    loadLogsViewer();
}

// Загрузить логи
async function loadLogsViewer() {
    const textEl = document.getElementById('logsViewerText');
    const linesEl = document.getElementById('logsViewerLines');
    const warningEl = document.getElementById('logsViewerWarning');
    
    try {
        const lines = parseInt(linesEl.value) || 100;
        const data = await apiRequest(`${currentLogsViewer.apiEndpoint}?lines=${lines}`);
        
        if (data.logs && data.logs.length > 0) {
            textEl.value = data.logs.join('\n');
        } else {
            const message = data.message || 'Логи пусты';
            textEl.value = message;
        }
        
        // Показываем предупреждение, если логирование выключено
        if (data.warning) {
            warningEl.textContent = data.warning;
            warningEl.style.display = 'block';
            // Не показываем toast для warning - это информационное сообщение
        } else if (currentLogsViewer.warning) {
            warningEl.textContent = currentLogsViewer.warning;
            warningEl.style.display = 'block';
        } else {
            warningEl.textContent = '';
            warningEl.style.display = 'none';
        }
    } catch (error) {
        // Если ошибка "Not found" - это может быть нормально, показываем сообщение
        if (error.message && (error.message.includes('Not found') || error.message.includes('404'))) {
            textEl.value = 'Файл логов не найден или пуст';
        } else {
            textEl.value = 'Ошибка при загрузке логов: ' + error.message;
            showToast('Ошибка при загрузке логов: ' + error.message, 3000);
        }
    }
}

// Закрыть просмотр логов
function closeLogsViewer() {
    const modal = document.getElementById('logsViewerModal');
    modal.style.display = 'none';
    currentLogsViewer = {
        title: '',
        apiEndpoint: '',
        warning: null
    };
}

// Закрытие по клику вне модального окна
window.addEventListener('click', (event) => {
    const modal = document.getElementById('logsViewerModal');
    if (event.target === modal) {
        closeLogsViewer();
    }
});

