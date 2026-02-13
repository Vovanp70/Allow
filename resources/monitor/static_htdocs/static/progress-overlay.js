// Переиспользуемый компонент кругового прогресс-бара (минималистичный: круг + бегунок)

let progressInterval = null;
let currentProgress = 0;
let progressTarget = 0;
let progressRefCount = 0;

// Показать прогресс-бар
function showProgress(message = 'Обработка...') {
    const overlay = document.getElementById('progressOverlay');
    const messageEl = document.getElementById('progressMessage');
    if (overlay) {
        progressRefCount++;
        if (messageEl) messageEl.textContent = message;
        overlay.style.display = 'flex';
        currentProgress = 0;
        progressTarget = 0;
    }
}

// Скрыть прогресс-бар (ref-count: несколько параллельных загрузок)
function hideProgress() {
    const overlay = document.getElementById('progressOverlay');
    if (overlay) {
        progressRefCount = Math.max(0, progressRefCount - 1);
        if (progressRefCount === 0) {
            overlay.style.display = 'none';
        }
        if (progressInterval) {
            clearInterval(progressInterval);
            progressInterval = null;
        }
        currentProgress = 0;
        progressTarget = 0;
    }
}

// Обновить прогресс (0-100)
function updateProgress(percent, message = null) {
    const overlay = document.getElementById('progressOverlay');
    const percentEl = overlay ? overlay.querySelector('.progress-percent') : null;
    const messageEl = document.getElementById('progressMessage');
    const progressCircle = overlay ? overlay.querySelector('.progress-ring-progress') : null;
    
    if (!overlay || !progressCircle) return;
    
    // Ограничиваем процент от 0 до 100
    percent = Math.max(0, Math.min(100, percent));
    progressTarget = percent;
    
    // Обновляем текст процента
    if (percentEl) {
        percentEl.textContent = Math.round(percent) + '%';
    }
    
    // Обновляем сообщение, если указано
    if (message && messageEl) {
        messageEl.textContent = message;
    }
    
    // Вычисляем длину окружности (2 * π * r)
    const radius = 54;
    const circumference = 2 * Math.PI * radius;
    
    // Вычисляем offset для анимации (чем больше процент, тем меньше offset)
    const offset = circumference - (percent / 100) * circumference;
    
    // Применяем стили
    progressCircle.style.strokeDasharray = `${circumference} ${circumference}`;
    progressCircle.style.strokeDashoffset = offset;
}

// Анимировать прогресс от текущего значения до целевого
function animateProgress(targetPercent, duration = 1000, message = null) {
    if (progressInterval) {
        clearInterval(progressInterval);
    }
    
    const startProgress = currentProgress;
    const progressDiff = targetPercent - startProgress;
    const startTime = Date.now();
    
    // Обновляем сообщение сразу, если указано
    if (message) {
        const messageEl = document.getElementById('progressMessage');
        if (messageEl) {
            messageEl.textContent = message;
        }
    }
    
    progressInterval = setInterval(() => {
        const elapsed = Date.now() - startTime;
        const progress = Math.min(elapsed / duration, 1);
        
        // Используем easing функцию для плавной анимации
        const eased = 1 - Math.pow(1 - progress, 3); // ease-out cubic
        currentProgress = startProgress + (progressDiff * eased);
        
        // Обновляем только прогресс, сообщение уже обновлено
        updateProgress(currentProgress);
        
        if (progress >= 1) {
            clearInterval(progressInterval);
            progressInterval = null;
            currentProgress = targetPercent;
            updateProgress(targetPercent);
        }
    }, 16); // ~60 FPS
}

// Симуляция прогресса с этапами
function simulateProgressWithStages(stages, onComplete = null) {
    if (!stages || stages.length === 0) {
        if (onComplete) onComplete();
        return;
    }
    
    let currentStage = 0;
    const totalStages = stages.length;
    
    function processNextStage() {
        if (currentStage >= totalStages) {
            updateProgress(100, 'Завершено');
            setTimeout(() => {
                hideProgress();
                if (onComplete) onComplete();
            }, 500);
            return;
        }
        
        const stage = stages[currentStage];
        const stageProgress = ((currentStage + 1) / totalStages) * 100;
        
        updateProgress(stageProgress, stage.message || `Этап ${currentStage + 1} из ${totalStages}`);
        
        if (stage.duration) {
            setTimeout(() => {
                currentStage++;
                processNextStage();
            }, stage.duration);
        } else {
            // Если duration не указан, ждем вызова stage.onComplete
            if (stage.onComplete) {
                stage.onComplete(() => {
                    currentStage++;
                    processNextStage();
                });
            } else {
                currentStage++;
                processNextStage();
            }
        }
    }
    
    processNextStage();
}

