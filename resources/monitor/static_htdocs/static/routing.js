// ========== Маршрутизация (Routing) ==========

// Маппинг типов маршрутизации на ID контейнеров
const routingContainers = {
    'direct': 'direct-blocks',
    'bypass': 'bypass-blocks',
    'vpn': 'vpn-blocks'
};

// Хранилище накопленных изменений (не сохраненных на сервере)
// Структура: { 'direct': { blocks: [...], modified: true }, ... }
const pendingChanges = {
    'direct': null,
    'bypass': null,
    'vpn': null
};

// Исходное состояние блоков (для сравнения)
const originalBlocks = {
    'direct': null,
    'bypass': null,
    'vpn': null
};

// Загрузка блоков для типа маршрутизации
async function loadRoutingBlocks(routingType, usePending = false) {
    const containerId = routingContainers[routingType];
    const container = document.getElementById(containerId);
    
    if (!container) {
        console.error(`Container not found: ${containerId}`);
        return;
    }
    
    container.innerHTML = '<div style="text-align: center; padding: 20px; color: #6e6e73;">Загрузка...</div>';
    
    try {
        let blocks;
        
        // Если есть накопленные изменения и нужно их использовать
        if (usePending && pendingChanges[routingType] !== null) {
            blocks = pendingChanges[routingType].blocks;
        } else {
            const data = await apiRequest(`/routing/blocks/${routingType}`);
            
            if (!data.success || !data.blocks) {
                container.innerHTML = '<div style="text-align: center; padding: 20px; color: #ff3b30;">Ошибка загрузки блоков</div>';
                return;
            }
            
            blocks = data.blocks;
            
            // Сохраняем исходное состояние (только если не используем pending)
            if (!usePending) {
                originalBlocks[routingType] = JSON.parse(JSON.stringify(blocks));
                // Если нет накопленных изменений, сбрасываем pending
                if (pendingChanges[routingType] === null) {
                    pendingChanges[routingType] = { blocks: JSON.parse(JSON.stringify(blocks)), modified: false };
                }
            }
        }
        
        renderBlocks(container, blocks, routingType);
        updateSaveButton();
    } catch (error) {
        console.error(`Error loading blocks for ${routingType}:`, error);
        container.innerHTML = '<div style="text-align: center; padding: 20px; color: #ff3b30;">Ошибка: ' + error.message + '</div>';
    }
}

// Отображение блоков в контейнере
function renderBlocks(container, blocks, routingType) {
    if (!blocks || blocks.length === 0) {
        container.innerHTML = '<div style="text-align: center; padding: 20px; color: #6e6e73;">Нет блоков</div>';
        return;
    }
    
    container.innerHTML = '';
    
    blocks.forEach(block => {
        const blockElement = createBlockElement(block, routingType);
        container.appendChild(blockElement);
    });
}

// Подсчет IP и хостов в блоке (новая модель: hosts/subnets + auto/user)
// Список блоков приходит с hosts_count/ips_count; один блок — с массивами hosts/subnets
function countItemsForNewModel(block) {
    if (typeof block.hosts_count === 'number' && typeof block.ips_count === 'number') {
        return { ips: block.ips_count, hosts: block.hosts_count };
    }
    const hostsAuto = (block.hosts && Array.isArray(block.hosts.auto)) ? block.hosts.auto : [];
    const hostsUser = (block.hosts && Array.isArray(block.hosts.user)) ? block.hosts.user : [];
    const subnetsAuto = (block.subnets && Array.isArray(block.subnets.auto)) ? block.subnets.auto : [];
    const subnetsUser = (block.subnets && Array.isArray(block.subnets.user)) ? block.subnets.user : [];
    return {
        ips: subnetsAuto.length + subnetsUser.length,
        hosts: hostsAuto.length + hostsUser.length
    };
}

// Создание элемента блока
function createBlockElement(block, routingType) {
    const div = document.createElement('div');
    div.className = 'routing-block';
    div.dataset.blockId = block.id;
    div.dataset.routingType = routingType;
    div.dataset.isUnnamed = block.is_unnamed || false;
    
    // UNNAMED блок не перетаскивается
    if (!block.is_unnamed) {
        div.draggable = true;
        div.addEventListener('dragstart', handleDragStart);
        div.addEventListener('dragend', handleDragEnd);
    }
    
    const counts = countItemsForNewModel(block);
    
    div.innerHTML = `
        <div class="block-header">
            ${!block.is_unnamed ? `
                <div class="block-drag-handle" onclick="showMoveMenu(event, '${routingType}', '${block.id}')" title="Переместить блок">
                    ⋮⋮
                </div>
            ` : ''}
            <h3 class="block-title">${escapeHtml(block.name)}</h3>
            ${!block.is_unnamed ? `<button class="block-delete-btn" onclick="deleteBlock('${routingType}', '${block.id}', '${escapeHtml(block.name)}')" title="Удалить блок">✕</button>` : ''}
        </div>
        <div class="block-actions">
            ${!block.is_unnamed ? `<button class="btn btn-secondary btn-sm" onclick="editBlockItems('${routingType}', '${block.id}', 'IPS')">IPS - ${counts.ips}</button>` : ''}
            ${!block.is_unnamed ? `<button class="btn btn-secondary btn-sm" onclick="editBlockItems('${routingType}', '${block.id}', 'HOSTS')">HOSTS - ${counts.hosts}</button>` : ''}
        </div>
    `;
    
    return div;
}

// Редактирование элементов блока (только IPS или только HOSTS)
async function editBlockItems(routingType, blockId, itemType) {
    try {
        // Загружаем блок
        const blockData = await apiRequest(`/routing/blocks/${routingType}/${blockId}`);
        
        if (!blockData.success || !blockData.block) {
            showToast('Блок не найден', 3000);
            return;
        }
        
        const block = blockData.block;
        
        // UNNAMED блок нельзя редактировать
        if (block.is_unnamed) {
            showToast('Блок UNNAMED нельзя редактировать. Переместите элементы в обычный блок.', 3000);
            return;
        }
        
        // Разделяем auto и user по типу
        let autoItems = [];
        let userItems = [];
        if (itemType === 'IPS') {
            autoItems = (block.subnets && Array.isArray(block.subnets.auto)) ? block.subnets.auto : [];
            userItems = (block.subnets && Array.isArray(block.subnets.user)) ? block.subnets.user : [];
        } else if (itemType === 'HOSTS') {
            autoItems = (block.hosts && Array.isArray(block.hosts.auto)) ? block.hosts.auto : [];
            userItems = (block.hosts && Array.isArray(block.hosts.user)) ? block.hosts.user : [];
        }
        const allItems = [...autoItems, ...userItems];
        
        const title = `${block.name} - ${itemType}`;
        const filePath = `/opt/etc/allow/dnsmasq-full/ipsets/${routingType === 'direct' ? 'nonbypass' : routingType === 'bypass' ? 'zapret' : 'bypass'}.txt`;
        const itemsText = allItems.join('\n');
        
        // Сохраняем контекст для сохранения
        window.currentRoutingEdit = {
            routingType: routingType,
            blockId: blockId,
            itemType: itemType,
            autoItems: autoItems,
            userItems: userItems
        };
        
        // Переопределяем loadConfigEditor ПЕРЕД вызовом openConfigEditor
        const originalLoadConfigEditor = window.loadConfigEditor;
        window.loadConfigEditor = async function() {
            const textEl = document.getElementById('configEditorText');
            if (textEl) {
                textEl.value = itemsText;
            }
        };
        
        // Используем существующий редактор конфигурации
        openConfigEditor(
            title,
            filePath,
            `/routing/blocks/${routingType}/${blockId}/items`,
            `/routing/blocks/${routingType}/${blockId}/items`
        );
        
        // Переопределяем сохранение
        const originalSaveConfigEditor = window.saveConfigEditor;
        window.saveConfigEditor = async function() {
            const textEl = document.getElementById('configEditorText');
            const editedText = textEl.value;
            const editedItems = editedText.split('\n')
                .map(line => line.trim())
                .filter(line => line && !line.startsWith('#'));
            
            if (!window.currentRoutingEdit) {
                // Если контекст потерян, используем стандартное сохранение
                window.loadConfigEditor = originalLoadConfigEditor;
                return originalSaveConfigEditor();
            }
            
            const { routingType, blockId, itemType, autoItems, userItems } = window.currentRoutingEdit;
            
            try {
                // Инициализируем pendingChanges если нужно
                if (pendingChanges[routingType] === null) {
                    const data = await apiRequest(`/routing/blocks/${routingType}`);
                    if (data.success) {
                        pendingChanges[routingType] = {
                            blocks: JSON.parse(JSON.stringify(data.blocks)),
                            modified: false
                        };
                        originalBlocks[routingType] = JSON.parse(JSON.stringify(data.blocks));
                    }
                }
                
                // Считаем множества для diff: A (auto), U (user), F (final)
                const A = autoItems.slice();
                const U = userItems.slice();
                const F = editedItems.slice();

                const Aset = new Set(A);
                const Uset = new Set(U);

                // DeletedFromAuto = A \ F
                const deletedFromAuto = A.filter(token => !F.includes(token));

                // KeptUser = F ∩ U
                const keptUser = F.filter(token => Uset.has(token));

                // Added = F \ (A ∪ U)
                const added = F.filter(token => !Aset.has(token) && !Uset.has(token));

                const newUserItems = Array.from(new Set([...keptUser, ...added]));

                // Формируем payload для backend
                const payload = {
                    item_type: itemType,
                    items: F,
                    deleted_from_auto: deletedFromAuto
                };

                await apiRequest(
                    `/routing/blocks/${routingType}/${blockId}/items`,
                    'POST',
                    payload
                );

                // Обновляем блок в pendingChanges (user-часть)
                const blocks = pendingChanges[routingType].blocks;
                const blockIndex = blocks.findIndex(b => b.id === blockId);
                if (blockIndex !== -1) {
                    const targetBlock = blocks[blockIndex];
                    if (itemType === 'IPS') {
                        if (!targetBlock.subnets) targetBlock.subnets = {};
                        targetBlock.subnets.user = newUserItems;
                    } else if (itemType === 'HOSTS') {
                        if (!targetBlock.hosts) targetBlock.hosts = {};
                        targetBlock.hosts.user = newUserItems;
                    }
                    pendingChanges[routingType].modified = true;
                }

                showToast('Элементы блока изменены (изменения сохранены)', 3000);
                delete window.currentRoutingEdit;
                // Восстанавливаем функции
                window.loadConfigEditor = originalLoadConfigEditor;
                window.saveConfigEditor = originalSaveConfigEditor;
                setTimeout(() => {
                    closeConfigEditor();
                    // Перезагружаем блоки с использованием pending изменений
                    loadRoutingBlocks(routingType, true);
                }, 1000);
            } catch (error) {
                showToast('Ошибка при сохранении: ' + error.message, 3000);
            }
        };
        
        // Восстанавливаем loadConfigEditor при закрытии
        const originalCloseConfigEditor = window.closeConfigEditor;
        window.closeConfigEditor = function() {
            window.loadConfigEditor = originalLoadConfigEditor;
            window.closeConfigEditor = originalCloseConfigEditor;
            originalCloseConfigEditor();
        };
        
    } catch (error) {
        console.error('Error loading block:', error);
        showToast('Ошибка при загрузке блока: ' + error.message, 3000);
    }
}

// Drag and Drop функционал
let draggedBlock = null;
let draggedBlockData = null;

function handleDragStart(e) {
    draggedBlock = this;
    draggedBlockData = {
        blockId: this.dataset.blockId,
        routingType: this.dataset.routingType
    };
    this.style.opacity = '0.5';
    
    // Добавляем класс для визуальной обратной связи
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/html', this.outerHTML);
}

function handleDragEnd(e) {
    this.style.opacity = '1';
    // Убираем классы подсветки со всех колонок
    document.querySelectorAll('.routing-column').forEach(col => {
        col.classList.remove('drag-over');
    });
}

// Добавляем обработчики для колонок
document.addEventListener('DOMContentLoaded', function() {
    // Проверяем, что мы на странице маршрутизации
    if (document.querySelector('.routing-columns')) {
        // Загружаем блоки для всех колонок
        loadRoutingBlocks('direct');
        loadRoutingBlocks('bypass');
        loadRoutingBlocks('vpn');
        
        // Добавляем обработчики drag and drop для колонок
        const columns = document.querySelectorAll('.routing-column');
        columns.forEach(column => {
            const blocksContainer = column.querySelector('.blocks-container');
            
            blocksContainer.addEventListener('dragover', function(e) {
                e.preventDefault();
                e.dataTransfer.dropEffect = 'move';
                column.classList.add('drag-over');
            });
            
            blocksContainer.addEventListener('dragleave', function(e) {
                column.classList.remove('drag-over');
            });
            
            blocksContainer.addEventListener('drop', async function(e) {
                e.preventDefault();
                column.classList.remove('drag-over');
                
                if (!draggedBlockData) return;
                
                const targetRoutingType = column.id.replace('-column', '');
                
                // Если блок уже в этой колонке, ничего не делаем
                if (draggedBlockData.routingType === targetRoutingType) {
                    return;
                }
                
                try {
                    // Инициализируем pendingChanges если нужно
                    if (pendingChanges[draggedBlockData.routingType] === null) {
                        const sourceData = await apiRequest(`/routing/blocks/${draggedBlockData.routingType}`);
                        if (sourceData.success) {
                            pendingChanges[draggedBlockData.routingType] = {
                                blocks: JSON.parse(JSON.stringify(sourceData.blocks)),
                                modified: false
                            };
                            originalBlocks[draggedBlockData.routingType] = JSON.parse(JSON.stringify(sourceData.blocks));
                        }
                    }
                    
                    if (pendingChanges[targetRoutingType] === null) {
                        const targetData = await apiRequest(`/routing/blocks/${targetRoutingType}`);
                        if (targetData.success) {
                            pendingChanges[targetRoutingType] = {
                                blocks: JSON.parse(JSON.stringify(targetData.blocks)),
                                modified: false
                            };
                            originalBlocks[targetRoutingType] = JSON.parse(JSON.stringify(targetData.blocks));
                        }
                    }
                    
                    // Находим блок в исходной колонке
                    const sourceBlocks = pendingChanges[draggedBlockData.routingType].blocks;
                    const block = sourceBlocks.find(b => b.id === draggedBlockData.blockId);
                    if (!block) {
                        throw new Error('Блок не найден');
                    }
                    
                    // Удаляем блок из исходной колонки
                    pendingChanges[draggedBlockData.routingType].blocks = sourceBlocks.filter(b => b.id !== draggedBlockData.blockId);
                    pendingChanges[draggedBlockData.routingType].modified = true;
                    
                    // Добавляем блок в целевую колонку
                    const targetBlocks = pendingChanges[targetRoutingType].blocks || [];
                    targetBlocks.push(block);
                    pendingChanges[targetRoutingType].blocks = targetBlocks;
                    pendingChanges[targetRoutingType].modified = true;
                    
                    showToast('Блок перемещен (изменения не сохранены)', 2000);
                    
                    // Перезагружаем обе колонки с использованием pending изменений
                    loadRoutingBlocks(draggedBlockData.routingType, true);
                    loadRoutingBlocks(targetRoutingType, true);
                    
                } catch (error) {
                    console.error('Error moving block:', error);
                    showToast('Ошибка при перемещении блока: ' + error.message, 3000);
                }
                
                draggedBlock = null;
                draggedBlockData = null;
            });
        });
    }
});

// Текущий routing type для добавления блока
let addBlockRoutingType = null;

// Открыть модальное окно добавления блока
function addBlock(routingType) {
    addBlockRoutingType = routingType;
    const modal = document.getElementById('addBlockModal');
    const input = document.getElementById('addBlockName');
    if (modal && input) {
        input.value = '';
        modal.style.display = 'block';
        setTimeout(() => input.focus(), 100);
    }
}

// Закрыть модальное окно
function closeAddBlockModal() {
    const modal = document.getElementById('addBlockModal');
    if (modal) {
        modal.style.display = 'none';
    }
    addBlockRoutingType = null;
}

// Проверить, существует ли блок с таким ID
async function isBlockIdExists(blockId) {
    const routingTypes = ['direct', 'bypass', 'vpn'];
    
    for (const rt of routingTypes) {
        // Проверяем в pendingChanges
        if (pendingChanges[rt] && pendingChanges[rt].blocks) {
            if (pendingChanges[rt].blocks.some(b => b.id === blockId)) {
                return true;
            }
        } else {
            // Загружаем с сервера
            try {
                const data = await apiRequest(`/routing/blocks/${rt}`);
                if (data.success && data.blocks) {
                    if (data.blocks.some(b => b.id === blockId)) {
                        return true;
                    }
                }
            } catch (e) {
                console.error('Error checking blocks:', e);
            }
        }
    }
    return false;
}

// Подтвердить добавление блока
async function submitAddBlock() {
    const input = document.getElementById('addBlockName');
    const name = input ? input.value.trim() : '';
    
    if (!name) {
        showToast('Введите название блока', 2000);
        return;
    }
    
    // Проверка длины имени
    if (name.length > 50) {
        showToast('Название слишком длинное (макс. 50 символов)', 3000);
        return;
    }
    
    // Проверка на недопустимые символы
    if (/[<>:"/\\|?*]/.test(name)) {
        showToast('Название содержит недопустимые символы', 3000);
        return;
    }
    
    const routingType = addBlockRoutingType;
    if (!routingType) {
        closeAddBlockModal();
        return;
    }
    
    // Генерируем ID и проверяем уникальность
    const blockId = generateBlockId(name);
    
    if (!blockId) {
        showToast('Не удалось создать ID из названия', 3000);
        return;
    }
    
    // Проверка на занятость ID
    const exists = await isBlockIdExists(blockId);
    if (exists) {
        showToast(`Блок с таким названием уже существует`, 3000);
        return;
    }
    
    closeAddBlockModal();
    
    try {
        // Инициализируем pendingChanges если нужно
        if (pendingChanges[routingType] === null) {
            const data = await apiRequest(`/routing/blocks/${routingType}`);
            if (data.success) {
                pendingChanges[routingType] = {
                    blocks: JSON.parse(JSON.stringify(data.blocks)),
                    modified: false
                };
                originalBlocks[routingType] = JSON.parse(JSON.stringify(data.blocks));
            } else {
                showToast('Ошибка при загрузке блоков', 3000);
                return;
            }
        }
        
        // Создаем новый блок (по умолчанию HOSTS, можно редактировать потом)
        const newBlock = {
            id: blockId,
            name: name,
            hosts: { auto: [], user: [] },
            subnets: { auto: [], user: [] }
        };
        
        // Добавляем к существующим блокам
        pendingChanges[routingType].blocks.push(newBlock);
        pendingChanges[routingType].modified = true;
        
        showToast('Блок добавлен (изменения не сохранены)', 2000);
        
        // Перезагружаем блоки с использованием pending изменений
        loadRoutingBlocks(routingType, true);
    } catch (error) {
        console.error('Error adding block:', error);
        showToast('Ошибка при добавлении блока: ' + error.message, 3000);
    }
}

// Обработка Enter и Escape в модальном окне
document.addEventListener('DOMContentLoaded', function() {
    const input = document.getElementById('addBlockName');
    if (input) {
        input.addEventListener('keypress', function(e) {
            if (e.key === 'Enter') {
                submitAddBlock();
            }
        });
    }
    
    // Закрытие по клику вне модального окна
    const modal = document.getElementById('addBlockModal');
    if (modal) {
        modal.addEventListener('click', function(e) {
            if (e.target === modal) {
                closeAddBlockModal();
            }
        });
    }
});

// Закрытие модального окна по Escape
document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') {
        const modal = document.getElementById('addBlockModal');
        if (modal && modal.style.display === 'block') {
            closeAddBlockModal();
        }
    }
});

// Удаление блока
function deleteBlock(routingType, blockId, blockName) {
    // Подтверждение удаления через модальное окно
    const message = `Удалить блок "${blockName}"?\n\nВсе user-элементы будут удалены.\nAuto-элементы будут перемещены в solitary.`;
    
    openConfirmModal('Удаление блока', message, async () => {
        try {
            const result = await apiRequest(`/routing/blocks/${routingType}/${blockId}`, 'DELETE');
            
            if (result.success) {
                showToast(`Блок "${blockName}" удалён`, 2000);
                
                // Сбрасываем pending для этого routing type
                pendingChanges[routingType] = null;
                originalBlocks[routingType] = null;
                
                // Перезагружаем блоки
                loadRoutingBlocks(routingType);
            } else {
                showToast('Ошибка: ' + (result.error || 'Не удалось удалить блок'), 3000);
            }
        } catch (error) {
            console.error('Error deleting block:', error);
            showToast('Ошибка при удалении блока: ' + error.message, 3000);
        }
    }, 'Удалить');
}

// Глобальное меню перемещения блока
let activeMoveMenu = null;

function closeMoveMenu() {
    if (activeMoveMenu) {
        activeMoveMenu.remove();
        activeMoveMenu = null;
    }
}

// Показать меню перемещения блока
function showMoveMenu(event, routingType, blockId) {
    event.stopPropagation();
    
    // Закрываем предыдущее меню
    closeMoveMenu();
    
    // Создаём меню
    const menu = document.createElement('div');
    menu.className = 'block-move-menu-fixed';
    menu.innerHTML = `
        <div class="block-move-menu-item" onclick="moveBlockTo(event, '${blockId}', '${routingType}', 'direct')">→ Напрямую</div>
        <div class="block-move-menu-item" onclick="moveBlockTo(event, '${blockId}', '${routingType}', 'bypass')">→ Встроенные инструменты</div>
        <div class="block-move-menu-item" onclick="moveBlockTo(event, '${blockId}', '${routingType}', 'vpn')">→ VPN</div>
    `;
    
    // Позиционируем относительно кнопки
    const rect = event.target.getBoundingClientRect();
    menu.style.top = (rect.bottom + 4) + 'px';
    menu.style.left = rect.left + 'px';
    
    document.body.appendChild(menu);
    activeMoveMenu = menu;
    
    // Проверяем, не выходит ли меню за правый край экрана
    const menuRect = menu.getBoundingClientRect();
    if (menuRect.right > window.innerWidth) {
        menu.style.left = (window.innerWidth - menuRect.width - 10) + 'px';
    }
}

// Закрыть меню при клике вне
document.addEventListener('click', function(e) {
    if (!e.target.closest('.block-drag-handle') && !e.target.closest('.block-move-menu-fixed')) {
        closeMoveMenu();
    }
});

// Переместить блок в другую колонку
async function moveBlockTo(event, blockId, fromRoutingType, toRoutingType) {
    event.stopPropagation();
    
    // Закрываем меню
    closeMoveMenu();
    
    if (fromRoutingType === toRoutingType) {
        showToast('Блок уже в этой колонке', 2000);
        return;
    }
    
    try {
        // Инициализируем pendingChanges если нужно
        if (pendingChanges[fromRoutingType] === null) {
            const sourceData = await apiRequest(`/routing/blocks/${fromRoutingType}`);
            if (sourceData.success) {
                pendingChanges[fromRoutingType] = {
                    blocks: JSON.parse(JSON.stringify(sourceData.blocks)),
                    modified: false
                };
                originalBlocks[fromRoutingType] = JSON.parse(JSON.stringify(sourceData.blocks));
            }
        }
        
        if (pendingChanges[toRoutingType] === null) {
            const targetData = await apiRequest(`/routing/blocks/${toRoutingType}`);
            if (targetData.success) {
                pendingChanges[toRoutingType] = {
                    blocks: JSON.parse(JSON.stringify(targetData.blocks)),
                    modified: false
                };
                originalBlocks[toRoutingType] = JSON.parse(JSON.stringify(targetData.blocks));
            }
        }
        
        // Находим блок в исходной колонке
        const sourceBlocks = pendingChanges[fromRoutingType].blocks;
        const block = sourceBlocks.find(b => b.id === blockId);
        if (!block) {
            throw new Error('Блок не найден');
        }
        
        // Удаляем блок из исходной колонки
        pendingChanges[fromRoutingType].blocks = sourceBlocks.filter(b => b.id !== blockId);
        pendingChanges[fromRoutingType].modified = true;
        
        // Добавляем блок в целевую колонку
        const targetBlocks = pendingChanges[toRoutingType].blocks || [];
        targetBlocks.push(block);
        pendingChanges[toRoutingType].blocks = targetBlocks;
        pendingChanges[toRoutingType].modified = true;
        
        const targetNames = {
            'direct': 'Напрямую',
            'bypass': 'Встроенные инструменты',
            'vpn': 'VPN'
        };
        showToast(`Блок перемещён в "${targetNames[toRoutingType]}" (не сохранено)`, 2000);
        
        // Перезагружаем обе колонки
        loadRoutingBlocks(fromRoutingType, true);
        loadRoutingBlocks(toRoutingType, true);
        
    } catch (error) {
        console.error('Error moving block:', error);
        showToast('Ошибка при перемещении: ' + error.message, 3000);
    }
}

// Генерация ID блока (аналогично Python функции)
function generateBlockId(name) {
    const translitMap = {
        'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'yo',
        'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
        'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
        'ф': 'f', 'х': 'h', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'sch',
        'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya'
    };
    
    let result = '';
    const nameLower = name.toLowerCase();
    
    for (let char of nameLower) {
        if (translitMap[char]) {
            result += translitMap[char];
        } else if (/[a-z0-9_]/.test(char)) {
            result += char;
        } else if (char === ' ' || char === '-') {
            result += '_';
        }
    }
    
    result = result.replace(/_+/g, '_').replace(/^_|_$/g, '');
    
    return result || 'block_' + (Math.abs(name.split('').reduce((a, b) => a + b.charCodeAt(0), 0)) % 10000);
}

// Экранирование HTML
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// Обновление кнопки сохранения
function updateSaveButton() {
    const saveBtn = document.getElementById('save-routing-changes-btn');
    const hintEl = document.getElementById('routing-unsaved-hint');
    if (!saveBtn) return;
    
    // Проверяем, есть ли несохраненные изменения
    const hasChanges = Object.values(pendingChanges).some(
        change => change !== null && change.modified
    );
    
    if (hasChanges) {
        saveBtn.disabled = false;
        if (hintEl) hintEl.textContent = 'Есть несохранённые изменения';
    } else {
        saveBtn.disabled = true;
        if (hintEl) hintEl.textContent = '';
    }
}

// Загрузить полные данные блока (hosts, subnets)
async function fetchBlockFullData(routingType, blockId) {
    const data = await apiRequest(`/routing/blocks/${routingType}/${blockId}`);
    return (data.success && data.block) ? data.block : null;
}

// Валидация блоков на дубликаты
async function validateRoutingBlocks() {
    const issues = {
        duplicates: [], // IP/хосты в нескольких блоках
        internalDuplicates: [] // Дубликаты внутри блоков
    };
    
    // Собираем все блоки из всех колонок
    const allBlocks = [];
    const routingTypes = ['direct', 'bypass', 'vpn'];
    
    for (const routingType of routingTypes) {
        let blocks = [];
        const change = pendingChanges[routingType];
        
        if (change !== null && change.modified) {
            // Используем измененные блоки
            blocks = change.blocks;
        } else {
            // Если нет изменений, используем originalBlocks или загружаем с сервера
            if (originalBlocks[routingType]) {
                blocks = originalBlocks[routingType];
            } else {
                // Загружаем с сервера
                try {
                    const data = await apiRequest(`/routing/blocks/${routingType}`);
                    if (data.success && data.blocks) {
                        blocks = data.blocks;
                    }
                } catch (error) {
                    console.error(`Error loading blocks for validation: ${routingType}`, error);
                }
            }
        }
        
        blocks.forEach(block => {
            if (block.is_unnamed) return; // Пропускаем UNNAMED блоки
            
            allBlocks.push({
                ...block,
                routingType: routingType,
                routingTypeName: routingType === 'direct' ? 'Напрямую' : 
                                routingType === 'bypass' ? 'Встроенные инструменты обхода' : 'VPN'
            });
        });
    }
    
    // Обогащаем блоки полными данными (hosts, subnets), если их нет
    await Promise.all(allBlocks.map(async (block) => {
        const hasFullData = block.hosts && Array.isArray(block.hosts.auto);
        if (!hasFullData) {
            const full = await fetchBlockFullData(block.routingType, block.id);
            if (full) {
                block.hosts = full.hosts || { auto: [], user: [] };
                block.subnets = full.subnets || { auto: [], user: [] };
            }
        }
    }));
    
    // Проверка дубликатов между блоками
    const itemToBlocks = {}; // item -> {originalItem: "...", blocks: Set/Map}
    
    allBlocks.forEach(block => {
        const hostsAuto = (block.hosts && Array.isArray(block.hosts.auto)) ? block.hosts.auto : [];
        const hostsUser = (block.hosts && Array.isArray(block.hosts.user)) ? block.hosts.user : [];
        const subnetsAuto = (block.subnets && Array.isArray(block.subnets.auto)) ? block.subnets.auto : [];
        const subnetsUser = (block.subnets && Array.isArray(block.subnets.user)) ? block.subnets.user : [];
        const items = [...hostsAuto, ...hostsUser, ...subnetsAuto, ...subnetsUser];
        const blockKey = `${block.routingType}:${block.id}:${block.name}`;
        
        items.forEach(item => {
            const normalizedItem = item.trim().toLowerCase();
            if (!normalizedItem) return;
            
            if (!itemToBlocks[normalizedItem]) {
                itemToBlocks[normalizedItem] = {
                    originalItem: item.trim(),
                    blocks: new Map() // Используем Map для уникальности блоков
                };
            }
            
            // Добавляем блок только если его еще нет (по ключу)
            if (!itemToBlocks[normalizedItem].blocks.has(blockKey)) {
                itemToBlocks[normalizedItem].blocks.set(blockKey, {
                    blockName: block.name,
                    blockId: block.id,
                    routingType: block.routingType,
                    routingTypeName: block.routingTypeName
                });
            }
        });
    });
    
    // Находим элементы, которые находятся в нескольких РАЗНЫХ блоках
    for (const [normalizedItem, data] of Object.entries(itemToBlocks)) {
        const uniqueBlocks = Array.from(data.blocks.values());
        // Показываем как дубликат между блоками только если элемент в РАЗНЫХ блоках
        if (uniqueBlocks.length > 1) {
            issues.duplicates.push({
                item: data.originalItem,
                normalizedItem: normalizedItem,
                blocks: uniqueBlocks
            });
        }
    }
    
    // Проверка дубликатов внутри блоков
    allBlocks.forEach(block => {
        const hostsAuto = (block.hosts && Array.isArray(block.hosts.auto)) ? block.hosts.auto : [];
        const hostsUser = (block.hosts && Array.isArray(block.hosts.user)) ? block.hosts.user : [];
        const subnetsAuto = (block.subnets && Array.isArray(block.subnets.auto)) ? block.subnets.auto : [];
        const subnetsUser = (block.subnets && Array.isArray(block.subnets.user)) ? block.subnets.user : [];
        const items = [...hostsAuto, ...hostsUser, ...subnetsAuto, ...subnetsUser];
        const seen = {};
        const duplicates = [];
        
        items.forEach((item, index) => {
            const normalizedItem = item.trim().toLowerCase();
            if (!normalizedItem) return;
            
            if (seen[normalizedItem]) {
                if (!duplicates.includes(normalizedItem)) {
                    duplicates.push(normalizedItem);
                }
            } else {
                seen[normalizedItem] = true;
            }
        });
        
        if (duplicates.length > 0) {
            issues.internalDuplicates.push({
                blockName: block.name,
                routingType: block.routingType,
                routingTypeName: block.routingTypeName,
                duplicates: duplicates
            });
        }
    });
    
    return issues;
}

// Удалить элемент из hosts/subnets блока
function removeItemFromBlock(block, normalizedItem) {
    const filter = (arr) => (Array.isArray(arr) ? arr : []).filter(
        i => i.trim().toLowerCase() !== normalizedItem
    );
    if (block.hosts) {
        block.hosts.auto = filter(block.hosts.auto);
        block.hosts.user = filter(block.hosts.user);
    }
    if (block.subnets) {
        block.subnets.auto = filter(block.subnets.auto);
        block.subnets.user = filter(block.subnets.user);
    }
}

// Проверить, есть ли элемент в блоке
function blockHasItem(block, normalizedItem) {
    const check = (arr) => (Array.isArray(arr) ? arr : []).some(
        i => i.trim().toLowerCase() === normalizedItem
    );
    return (block.hosts && (check(block.hosts.auto) || check(block.hosts.user))) ||
           (block.subnets && (check(block.subnets.auto) || check(block.subnets.user)));
}

// Найти оригинальное значение (с регистром) в блоке
function findOriginalInBlock(block, normalizedItem) {
    const search = (arr) => (Array.isArray(arr) ? arr : []).find(
        i => i.trim().toLowerCase() === normalizedItem
    );
    const found = (block.hosts && (search(block.hosts.auto) || search(block.hosts.user))) ||
                  (block.subnets && (search(block.subnets.auto) || search(block.subnets.user)));
    return found ? found.trim() : null;
}

// Исправить дубликат между блоками - оставить только в одном блоке
function fixDuplicateBetweenBlocks(item, keepInBlock, removeFromBlocks) {
    const normalizedItem = item.trim().toLowerCase();
    const affectedTypes = new Set([keepInBlock.routingType]);
    removeFromBlocks.forEach(b => affectedTypes.add(b.routingType));
    
    // Инициализируем pendingChanges
    affectedTypes.forEach(routingType => {
        if (!pendingChanges[routingType]) {
            const orig = originalBlocks[routingType];
            pendingChanges[routingType] = {
                blocks: orig ? JSON.parse(JSON.stringify(orig)) : [],
                modified: false
            };
        }
    });
    
    // Находим оригинальное значение
    let originalItem = item.trim();
    for (const routingType of affectedTypes) {
        const blocks = pendingChanges[routingType].blocks;
        for (const block of blocks) {
            const found = findOriginalInBlock(block, normalizedItem);
            if (found) {
                originalItem = found;
                break;
            }
        }
    }
    
    // Удаляем элемент из блоков, из которых убираем
    removeFromBlocks.forEach(blockInfo => {
        const blocks = pendingChanges[blockInfo.routingType].blocks;
        const block = blocks.find(b => b.name === blockInfo.blockName && !b.is_unnamed);
        if (block) {
            removeItemFromBlock(block, normalizedItem);
            pendingChanges[blockInfo.routingType].modified = true;
        }
    });
    
    // Убеждаемся, что элемент есть в блоке, где оставляем
    const keepBlocks = pendingChanges[keepInBlock.routingType].blocks;
    const keepBlock = keepBlocks.find(b => b.name === keepInBlock.blockName && !b.is_unnamed);
    if (keepBlock && !blockHasItem(keepBlock, normalizedItem)) {
        (keepBlock.hosts = keepBlock.hosts || {}).user = (keepBlock.hosts.user || []).concat(originalItem);
        pendingChanges[keepInBlock.routingType].modified = true;
    }
}

// Убрать дубликаты в массиве, оставив первое вхождение
function dedupeArray(arr) {
    const seen = {};
    return (arr || []).filter(item => {
        const n = item.trim().toLowerCase();
        if (!n) return false;
        if (seen[n]) return false;
        seen[n] = true;
        return true;
    });
}

// Сохранить элементы блока на сервер
async function persistBlockItemsToServer(routingType, blockId, block) {
    const hostsAuto = (block.hosts && block.hosts.auto) || [];
    const hostsUser = (block.hosts && block.hosts.user) || [];
    const subnetsAuto = (block.subnets && block.subnets.auto) || [];
    const subnetsUser = (block.subnets && block.subnets.user) || [];
    
    const hostsF = [...hostsAuto, ...hostsUser];
    const subnetsF = [...subnetsAuto, ...subnetsUser];
    
    await apiRequest(`/routing/blocks/${routingType}/${blockId}/items`, 'POST', {
        item_type: 'HOSTS',
        items: hostsF,
        deleted_from_auto: []
    });
    await apiRequest(`/routing/blocks/${routingType}/${blockId}/items`, 'POST', {
        item_type: 'IPS',
        items: subnetsF,
        deleted_from_auto: []
    });
}

// Исправить дубликаты внутри блока
function fixInternalDuplicates(blockInfo, duplicates) {
    const routingType = blockInfo.routingType;
    
    if (!pendingChanges[routingType]) {
        const orig = originalBlocks[routingType] || [];
        pendingChanges[routingType] = {
            blocks: JSON.parse(JSON.stringify(orig)),
            modified: false
        };
    }
    
    const block = pendingChanges[routingType].blocks.find(
        b => b.name === blockInfo.blockName && !b.is_unnamed
    );
    if (!block) return;
    
    block.hosts = block.hosts || { auto: [], user: [] };
    block.subnets = block.subnets || { auto: [], user: [] };
    
    block.hosts.auto = dedupeArray(block.hosts.auto);
    block.hosts.user = dedupeArray(block.hosts.user);
    block.subnets.auto = dedupeArray(block.subnets.auto);
    block.subnets.user = dedupeArray(block.subnets.user);
    
    pendingChanges[routingType].modified = true;
}

// Показать диалоговое окно с проблемами валидации
// Пользователь выбирает действия (radio/checkbox), затем нажимает "Продолжить"
function showValidationDialog(issues, onContinue, onCancel) {
    const hasIssues = issues.duplicates.length > 0 || issues.internalDuplicates.length > 0;
    
    if (!hasIssues) {
        onContinue();
        return;
    }
    
    let message = '<div style="max-height: 500px; overflow-y: auto; text-align: left;">';
    message += '<p style="margin: 0 0 15px 0; color: #6e6e73;">Выберите действия, затем нажмите «Продолжить»:</p>';
    
    // Дубликаты между блоками — radio
    if (issues.duplicates.length > 0) {
        message += '<h4 style="color: #ff9500; margin-top: 15px;">Элементы в нескольких блоках</h4>';
        
        issues.duplicates.forEach((dup, dupIndex) => {
            const radioName = 'dup-radio-' + dupIndex;
            message += `<div style="margin: 10px 0; padding: 10px; background: #f5f5f7; border-radius: 8px; border-left: 3px solid #ff9500;">`;
            message += `<div style="margin-bottom: 8px;"><strong>${escapeHtml(dup.item)}</strong> — оставить только в:</div>`;
            message += '<div style="margin-left: 10px;">';
            dup.blocks.forEach((block, blockIndex) => {
                const checked = blockIndex === 0 ? ' checked' : '';
                message += `<label style="display: block; margin: 6px 0; cursor: pointer;">`;
                message += `<input type="radio" name="${radioName}" value="${blockIndex}"${checked}> `;
                message += escapeHtml(block.blockName) + ' (' + escapeHtml(block.routingTypeName) + ')';
                message += `</label>`;
            });
            message += '</div></div>';
        });
    }
    
    // Дубликаты внутри блоков — checkbox
    if (issues.internalDuplicates.length > 0) {
        message += '<h4 style="color: #ff9500; margin-top: 20px;">Дубликаты внутри блоков</h4>';
        
        issues.internalDuplicates.forEach((dup, index) => {
            const cbId = 'fix-internal-' + index;
            const dupList = dup.duplicates.slice(0, 10).map(d => escapeHtml(d)).join(', ');
            const more = dup.duplicates.length > 10 ? ` и еще ${dup.duplicates.length - 10}` : '';
            message += `<div style="margin: 10px 0; padding: 10px; background: #f5f5f7; border-radius: 8px; border-left: 3px solid #ff9500;">`;
            message += `<label style="cursor: pointer; display: block;">`;
            message += `<input type="checkbox" id="${cbId}" checked> `;
            message += `<strong>${escapeHtml(dup.blockName)}</strong> (${escapeHtml(dup.routingTypeName)}): `;
            message += `убрать дубликаты (${dupList}${more})`;
            message += `</label></div>`;
        });
    }
    
    message += '</div>';
    
    const modal = document.getElementById('confirmModal');
    const titleEl = document.getElementById('confirmModalTitle');
    const messageEl = document.getElementById('confirmModalMessage');
    const okBtn = document.getElementById('confirmModalOkBtn');
    const cancelBtn = document.getElementById('confirmModalCancelBtn');
    
    titleEl.textContent = 'Проблемы валидации';
    messageEl.innerHTML = message;
    okBtn.textContent = 'Продолжить';
    
    if (cancelBtn) {
        cancelBtn.style.display = 'inline-block';
    }
    
    let cancelHandler = null;
    if (cancelBtn) {
        cancelBtn.removeAttribute('onclick');
        cancelHandler = (e) => {
            e.preventDefault();
            e.stopPropagation();
            onCancel();
            if (cancelBtn) {
                cancelBtn.removeEventListener('click', cancelHandler);
                cancelBtn.setAttribute('onclick', 'closeConfirmModal()');
            }
            closeConfirmModal();
        };
        cancelBtn.addEventListener('click', cancelHandler);
    }
    
    confirmModalCallback = () => {
        if (cancelBtn && cancelHandler) {
            cancelBtn.removeEventListener('click', cancelHandler);
            cancelBtn.setAttribute('onclick', 'closeConfirmModal()');
        }
        closeConfirmModal();
        
        (async () => {
            const toEnrich = new Map();
            issues.duplicates.forEach(dup => {
                dup.blocks.forEach(b => toEnrich.set(`${b.routingType}\0${b.blockId || b.blockName}`, { rt: b.routingType, bid: b.blockId || b.blockName }));
            });
            issues.internalDuplicates.forEach((dup, idx) => {
                if (document.getElementById('fix-internal-' + idx)?.checked) {
                    toEnrich.set(`${dup.routingType}\0${dup.blockName}`, { rt: dup.routingType, bid: dup.blockName });
                }
            });
            
            for (const { rt, bid } of toEnrich.values()) {
                if (!pendingChanges[rt]) {
                    const data = await apiRequest(`/routing/blocks/${rt}`);
                    if (data.success && data.blocks) {
                        pendingChanges[rt] = { blocks: JSON.parse(JSON.stringify(data.blocks)), modified: false };
                        if (!originalBlocks[rt]) originalBlocks[rt] = JSON.parse(JSON.stringify(data.blocks));
                    }
                }
                const blocks = pendingChanges[rt]?.blocks || [];
                const block = blocks.find(b => (b.id || b.name) === bid);
                if (block && !(block.hosts && Array.isArray(block.hosts.auto))) {
                    const full = await fetchBlockFullData(rt, bid);
                    if (full) {
                        block.hosts = full.hosts || { auto: [], user: [] };
                        block.subnets = full.subnets || { auto: [], user: [] };
                    }
                }
            }

            
            // Применяем исправления
            const toPersist = new Map();
            issues.duplicates.forEach((dup, dupIndex) => {
                const radioName = 'dup-radio-' + dupIndex;
                const selected = document.querySelector(`input[name="${radioName}"]:checked`);
                if (selected) {
                    const blockIndex = parseInt(selected.value, 10);
                    const keepInBlock = dup.blocks[blockIndex];
                    const removeFromBlocks = dup.blocks.filter((_, i) => i !== blockIndex);
                    fixDuplicateBetweenBlocks(dup.item, keepInBlock, removeFromBlocks);
                    toPersist.set(keepInBlock.routingType + '\0' + (keepInBlock.blockId || keepInBlock.blockName), { rt: keepInBlock.routingType, bid: keepInBlock.blockId || keepInBlock.blockName });
                    removeFromBlocks.forEach(b => toPersist.set(b.routingType + '\0' + (b.blockId || b.blockName), { rt: b.routingType, bid: b.blockId || b.blockName }));
                }
            });
            
            issues.internalDuplicates.forEach((dup, index) => {
                const cb = document.getElementById('fix-internal-' + index);
                if (cb && cb.checked) {
                    fixInternalDuplicates(dup, dup.duplicates);
                    toPersist.set(dup.routingType + '\0' + dup.blockName, { rt: dup.routingType, bid: dup.blockName });
                }
            });
            
            for (const { rt, bid } of toPersist.values()) {
                const blocks = (pendingChanges[rt] && pendingChanges[rt].blocks) || [];
                const block = blocks.find(b => (b.id || b.name) === bid);
                if (block && block.hosts && Array.isArray(block.hosts.auto)) {
                    await persistBlockItemsToServer(rt, block.id || block.name, block);
                }
            }
            onContinue();
        })().catch(err => {
            console.error(err);
            showToast('Ошибка при сохранении: ' + err.message, 3000);
        });
    };
    
    modal.style.display = 'block';
}

// Сохранение всех изменений
async function saveAllRoutingChanges() {
    const saveBtn = document.getElementById('save-routing-changes-btn');
    if (saveBtn) {
        saveBtn.disabled = true;
        saveBtn.textContent = 'Сохранение...';
    }
    
    try {
        // --- Проверка на дубликаты отключена (закомментирована) ---
        // showToast('Проверка на дубликаты...', 2000);
        // const validationIssues = await validateRoutingBlocks();
        // showValidationDialog(
        //     validationIssues,
        //     async () => {
        //         if (saveBtn) { saveBtn.textContent = 'Сохранение...'; }
        //         try { ... } catch (error) { ... }
        //     },
        //     () => { if (saveBtn) { saveBtn.disabled = false; saveBtn.textContent = 'Сохранить изменения'; } }
        // );

        showToast('Сохранение изменений...', 2000);
        
        // Сохраняем все измененные колонки
        const savePromises = [];
        for (const [routingType, change] of Object.entries(pendingChanges)) {
            if (change !== null && change.modified) {
                savePromises.push(
                    apiRequest(
                        `/routing/blocks/${routingType}`,
                        'POST',
                        { blocks: change.blocks }
                    )
                );
            }
        }
        
        await Promise.all(savePromises);
        
        // Применяем изменения: очищаем IPSET и перезагружаем dnsmasq
        showToast('Применение изменений (очистка IPSET, перезагрузка dnsmasq)...', 3000);
        
        const applyResult = await apiRequest('/routing/apply', 'POST');
        
        if (applyResult.success) {
            showToast('Все изменения успешно применены');
            
            // Сбрасываем pendingChanges
            for (const routingType of Object.keys(pendingChanges)) {
                pendingChanges[routingType] = null;
                originalBlocks[routingType] = null;
            }
            
            // Перезагружаем все колонки с сервера
            await loadRoutingBlocks('direct');
            await loadRoutingBlocks('bypass');
            await loadRoutingBlocks('vpn');
            
            updateSaveButton();
        } else {
            throw new Error(applyResult.error || 'Ошибка при применении изменений');
        }
        
    } catch (error) {
        console.error('Error saving changes:', error);
        showToast('Ошибка при сохранении: ' + error.message, 3000);
        if (saveBtn) {
            saveBtn.disabled = false;
            saveBtn.textContent = 'Сохранить изменения';
        }
    }
}

// Загрузка всех блоков при загрузке страницы
document.addEventListener('DOMContentLoaded', function() {
    // Проверяем, что мы на странице маршрутизации
    if (document.querySelector('.routing-columns')) {
        // Загружаем блоки для всех колонок
        loadRoutingBlocks('direct');
        loadRoutingBlocks('bypass');
        loadRoutingBlocks('vpn');
    }
});

