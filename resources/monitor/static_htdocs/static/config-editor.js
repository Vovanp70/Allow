// Переиспользуемый компонент редактора конфигурации

let currentConfigEditor = {
    title: '',
    filePath: '',
    apiEndpoint: '',
    saveEndpoint: ''
};

// Открыть редактор конфигурации
function openConfigEditor(title, filePath, apiEndpoint, saveEndpoint) {
    currentConfigEditor = {
        title: title,
        filePath: filePath,
        apiEndpoint: apiEndpoint,
        saveEndpoint: saveEndpoint
    };
    
    const modal = document.getElementById('configEditorModal');
    const titleEl = document.getElementById('configEditorTitle');
    const filePathEl = document.getElementById('configEditorFilePath');
    const textEl = document.getElementById('configEditorText');
    
    titleEl.textContent = title;
    filePathEl.textContent = filePath;
    textEl.value = 'Загрузка...';
    modal.style.display = 'block';
    
    loadConfigEditor();
}

// Загрузить конфигурацию в редактор
async function loadConfigEditor() {
    const textEl = document.getElementById('configEditorText');
    if (typeof showProgress === 'function') showProgress('Загрузка...');
    try {
        const data = await apiRequest(currentConfigEditor.apiEndpoint);
        
        if (data.config) {
            // Если конфигурация пришла как массив строк
            if (Array.isArray(data.config)) {
                // Убираем лишние переводы строк в конце каждой строки
                textEl.value = data.config.map(line => {
                    // Убираем \r\n или \n в конце строки
                    return typeof line === 'string' ? line.replace(/\r?\n$/, '') : String(line);
                }).join('\n');
            } else {
                // Если пришла как строка
                textEl.value = data.config;
            }
        } else if (data.full_config) {
            // Альтернативное поле
            if (Array.isArray(data.full_config)) {
                textEl.value = data.full_config.map(line => {
                    return typeof line === 'string' ? line.replace(/\r?\n$/, '') : String(line);
                }).join('\n');
            } else {
                textEl.value = data.full_config;
            }
        } else {
            textEl.value = '# Конфигурация не найдена\n# Файл будет создан при сохранении';
        }
    } catch (error) {
        // Если ошибка "Not found" - это нормально, показываем пустую конфигурацию
        if (error.message && (error.message.includes('Not found') || error.message.includes('404'))) {
            textEl.value = '# Конфигурация не найдена\n# Файл будет создан при сохранении';
        } else {
            textEl.value = 'Ошибка при загрузке конфигурации: ' + error.message;
            showToast('Ошибка при загрузке: ' + error.message, 3000);
        }
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
    }
}

// Сохранить конфигурацию из редактора
async function saveConfigEditor() {
    const textEl = document.getElementById('configEditorText');
    const configText = textEl.value;
    if (typeof showProgress === 'function') showProgress('Сохранение...');
    try {
        const data = await apiRequest(
            currentConfigEditor.saveEndpoint,
            'POST',
            { config: configText }
        );
        
        if (data.success) {
            showToast('Конфигурация успешно сохранена');
            setTimeout(() => {
                closeConfigEditor();
            }, 1000);
        } else {
            showToast('Ошибка при сохранении: ' + (data.error || data.message || 'Неизвестная ошибка'), 3000);
        }
    } catch (error) {
        showToast('Ошибка при сохранении: ' + error.message, 3000);
    } finally {
        if (typeof hideProgress === 'function') hideProgress();
    }
}

// Закрыть редактор конфигурации
function closeConfigEditor() {
    const modal = document.getElementById('configEditorModal');
    modal.style.display = 'none';
    currentConfigEditor = {
        title: '',
        filePath: '',
        apiEndpoint: '',
        saveEndpoint: ''
    };
}

// Закрытие по клику вне модального окна
window.addEventListener('click', (event) => {
    const modal = document.getElementById('configEditorModal');
    if (event.target === modal) {
        closeConfigEditor();
    }
});

