// Переиспользуемый компонент модального окна подтверждения

let confirmModalCallback = null;

// Открыть модальное окно подтверждения
function openConfirmModal(title, message, onConfirm, confirmButtonText = 'Подтвердить') {
    const modal = document.getElementById('confirmModal');
    const titleEl = document.getElementById('confirmModalTitle');
    const messageEl = document.getElementById('confirmModalMessage');
    const okBtn = document.getElementById('confirmModalOkBtn');
    
    titleEl.textContent = title;
    messageEl.textContent = message;
    okBtn.textContent = confirmButtonText;
    confirmModalCallback = onConfirm;
    
    modal.style.display = 'block';
}

// Выполнить действие подтверждения
function confirmModalAction() {
    if (confirmModalCallback) {
        confirmModalCallback();
        confirmModalCallback = null;
    }
    closeConfirmModal();
}

// Закрыть модальное окно подтверждения
function closeConfirmModal() {
    const modal = document.getElementById('confirmModal');
    modal.style.display = 'none';
    confirmModalCallback = null;
}

// Закрытие по клику вне модального окна
window.addEventListener('click', (event) => {
    const modal = document.getElementById('confirmModal');
    if (event.target === modal) {
        closeConfirmModal();
    }
});




