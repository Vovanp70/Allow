// Страница настроек: режим DoT, фильтр для детей, Sing-box прокси. Применение по кнопке «Сохранить».

let selectedMode = null;
let initialDnsMode = null;
let initialChildrenFilter = false;
let childrenFilterDirty = false;

function getModeCards() {
    return document.querySelectorAll('.dns-mode-card');
}

function getManualCard() {
    return document.querySelector('.dns-mode-card-manual');
}

function setManualCardVisible(visible) {
    const card = getManualCard();
    if (card) {
        if (visible) card.classList.add('visible');
        else card.classList.remove('visible');
    }
}

function setSelectedCard(mode) {
    selectedMode = mode;
    getModeCards().forEach(function (card) {
        if (card.getAttribute('data-mode') === mode) {
            card.classList.add('selected');
            card.setAttribute('aria-pressed', 'true');
        } else {
            card.classList.remove('selected');
            card.setAttribute('aria-pressed', 'false');
        }
    });
    updateSaveButton();
}

function bindCardClicks() {
    getModeCards().forEach(function (card) {
        card.addEventListener('click', function () {
            setSelectedCard(card.getAttribute('data-mode'));
        });
        card.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                setSelectedCard(card.getAttribute('data-mode'));
            }
        });
    });
}

async function loadCurrentMode() {
    const statusEl = document.getElementById('dns-mode-status');
    if (statusEl) statusEl.textContent = 'Загрузка...';
    try {
        const data = await apiRequest('/dns-mode/');
        const mode = data.mode || 'adblock';
        initialDnsMode = mode;
        if (mode === 'manual') {
            setManualCardVisible(true);
            setSelectedCard('manual');
        } else {
            setManualCardVisible(false);
            setSelectedCard(mode);
        }
        if (statusEl) statusEl.textContent = '';
    } catch (err) {
        if (statusEl) statusEl.textContent = 'Ошибка загрузки режима';
        setManualCardVisible(false);
        setSelectedCard('adblock');
        initialDnsMode = 'adblock';
    }
    updateSaveButton();
}

function isDnsModeDirty() {
    if (!selectedMode || selectedMode === 'manual') return false;
    return selectedMode !== initialDnsMode;
}

function isChildrenFilterDirty() {
    const toggleEl = document.getElementById('children-filter-toggle');
    if (!toggleEl) return false;
    return toggleEl.checked !== initialChildrenFilter;
}

function isAnyDirty() {
    return isDnsModeDirty() || childrenFilterDirty || (typeof window.isSingboxDirty === 'function' && window.isSingboxDirty());
}

function updateSaveButton() {
    const btn = document.getElementById('settings-save-btn');
    const hint = document.getElementById('settings-unsaved-hint');
    if (!btn) return;
    const dirty = isAnyDirty();
    btn.disabled = !dirty;
    if (hint) hint.textContent = dirty ? 'Есть несохранённые изменения' : '';
}

window.settingsUpdateSaveButton = updateSaveButton;

async function saveAllSettings() {
    const saveBtn = document.getElementById('settings-save-btn');
    const statusEl = document.getElementById('dns-mode-status');
    if (saveBtn) saveBtn.disabled = true;

    if (typeof showProgress === 'function') showProgress('Сохранение настроек…');

    try {
        if (isDnsModeDirty() && selectedMode && selectedMode !== 'manual') {
            const data = await apiRequest('/dns-mode/', 'POST', { mode: selectedMode });
            initialDnsMode = selectedMode;
            if (data.dns_check && data.dns_check.ok !== true && statusEl) {
                statusEl.textContent = 'Проверка Stubby не прошла: ' + (data.dns_check.error || 'неизвестная ошибка');
            } else if (statusEl) statusEl.textContent = '';
        }

        if (isChildrenFilterDirty()) {
            const toggleEl = document.getElementById('children-filter-toggle');
            const checked = toggleEl ? toggleEl.checked : false;
            await apiRequest('/settings/children-filter', 'POST', { enabled: checked });
            initialChildrenFilter = checked;
            childrenFilterDirty = false;
        }

        if (typeof window.saveSingboxDraft === 'function') {
            const result = await window.saveSingboxDraft();
            if (result && result.success !== true && typeof showToast === 'function') {
                showToast(result.error || 'Ошибка сохранения конфига Sing-box', 4000);
            }
        }

        if (typeof hideProgress === 'function') hideProgress();
        if (typeof showToast === 'function') showToast('Настройки сохранены');
    } catch (err) {
        if (typeof hideProgress === 'function') hideProgress();
        if (typeof showToast === 'function') showToast(err.message || 'Ошибка сохранения', 4000);
        if (statusEl) statusEl.textContent = err.message || 'Ошибка';
    } finally {
        updateSaveButton();
    }
}

// --- Фильтрация контента для детей (только UI, без API до «Сохранить») ---

async function loadChildrenFilterStatus() {
    const toggleEl = document.getElementById('children-filter-toggle');
    if (!toggleEl) return;
    try {
        const data = await apiRequest('/settings/children-filter');
        const enabled = !!(data && data.enabled === true);
        initialChildrenFilter = enabled;
        toggleEl.checked = enabled;
        childrenFilterDirty = false;
    } catch (err) {
        if (typeof showToast === 'function') showToast('Ошибка загрузки настройки');
    }
    updateSaveButton();
}

function onChildrenFilterChange() {
    childrenFilterDirty = true;
    updateSaveButton();
}

document.addEventListener('DOMContentLoaded', function () {
    bindCardClicks();
    loadCurrentMode();
    loadChildrenFilterStatus();

    const saveBtn = document.getElementById('settings-save-btn');
    if (saveBtn) saveBtn.addEventListener('click', saveAllSettings);

    const childrenToggle = document.getElementById('children-filter-toggle');
    if (childrenToggle) childrenToggle.addEventListener('change', onChildrenFilterChange);
});
