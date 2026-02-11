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
            ${!block.is_unnamed ? '<div class="block-drag-handle" title="Перетащите для перемещения в другую колонку">⋮⋮</div>' : ''}
            <h3 class="block-title">${escapeHtml(block.name)}</h3>
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
    if (document.querySelector('.routing-container')) {
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

// Добавление нового блока
async function addBlock(routingType) {
    const name = prompt('Введите название блока:');
    if (!name || !name.trim()) {
        return;
    }
    
    const type = confirm('Выберите тип блока:\n\nOK - Хосты (HOSTS)\nОтмена - IP адреса (IPS)') ? 'HOSTS' : 'IPS';
    
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
        
        // Создаем новый блок
        const newBlock = {
            id: generateBlockId(name),
            name: name.trim(),
            type: type,
            items: []
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
    if (!saveBtn) return;
    
    // Проверяем, есть ли несохраненные изменения
    const hasChanges = Object.values(pendingChanges).some(
        change => change !== null && change.modified
    );
    
    if (hasChanges) {
        saveBtn.style.display = 'inline-block';
        saveBtn.disabled = false;
    } else {
        saveBtn.style.display = 'none';
        saveBtn.disabled = true;
    }
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
        const items = block.items || [];
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

// Исправить дубликат между блоками - оставить только в одном блоке
function fixDuplicateBetweenBlocks(item, keepInBlock, removeFromBlocks) {
    // Инициализируем pendingChanges для всех затронутых типов маршрутизации
    const affectedTypes = new Set([keepInBlock.routingType]);
    removeFromBlocks.forEach(b => affectedTypes.add(b.routingType));
    
    // Находим оригинальное значение item (с правильным регистром)
    let originalItem = item;
    const normalizedItem = item.toLowerCase();
    
    // Ищем оригинальное значение в любом из блоков
    for (const routingType of affectedTypes) {
        const change = pendingChanges[routingType];
        const orig = originalBlocks[routingType];
        const blocks = (change && change.blocks.length > 0) ? change.blocks : (orig || []);
        
        for (const block of blocks) {
            if (block.items) {
                const found = block.items.find(i => i.trim().toLowerCase() === normalizedItem);
                if (found) {
                    originalItem = found.trim();
                    break;
                }
            }
        }
        if (originalItem !== item) break;
    }
    
    affectedTypes.forEach(routingType => {
        if (!pendingChanges[routingType]) {
            // Загружаем с сервера или используем originalBlocks
            if (originalBlocks[routingType]) {
                pendingChanges[routingType] = {
                    blocks: JSON.parse(JSON.stringify(originalBlocks[routingType])),
                    modified: false
                };
            } else {
                // Используем пустой массив, загрузка произойдет при следующей валидации
                pendingChanges[routingType] = {
                    blocks: [],
                    modified: false
                };
            }
        }
    });
    
    // Обновляем блок, в котором оставляем элемент
    const keepRoutingType = keepInBlock.routingType;
    const keepBlockIndex = pendingChanges[keepRoutingType].blocks.findIndex(
        b => b.name === keepInBlock.blockName && !b.is_unnamed
    );
    
    if (keepBlockIndex !== -1) {
        const block = pendingChanges[keepRoutingType].blocks[keepBlockIndex];
        // Убеждаемся, что элемент есть в блоке
        const hasItem = block.items.some(i => i.trim().toLowerCase() === normalizedItem);
        if (!hasItem) {
            block.items.push(originalItem);
        }
        pendingChanges[keepRoutingType].modified = true;
    }
    
    // Удаляем элемент из других блоков
    removeFromBlocks.forEach(blockInfo => {
        const routingType = blockInfo.routingType;
        const blockIndex = pendingChanges[routingType].blocks.findIndex(
            b => b.name === blockInfo.blockName && !b.is_unnamed
        );
        
        if (blockIndex !== -1) {
            const block = pendingChanges[routingType].blocks[blockIndex];
            block.items = block.items.filter(
                i => i.trim().toLowerCase() !== normalizedItem
            );
            pendingChanges[routingType].modified = true;
        }
    });
}

// Исправить дубликаты внутри блока
function fixInternalDuplicates(blockInfo, duplicates) {
    const routingType = blockInfo.routingType;
    
    // Инициализируем pendingChanges если нужно
    if (!pendingChanges[routingType]) {
        const change = originalBlocks[routingType] || [];
        pendingChanges[routingType] = {
            blocks: JSON.parse(JSON.stringify(change)),
            modified: false
        };
        if (!originalBlocks[routingType]) {
            originalBlocks[routingType] = JSON.parse(JSON.stringify(change));
        }
    }
    
    // Находим блок
    const blockIndex = pendingChanges[routingType].blocks.findIndex(
        b => b.name === blockInfo.blockName && !b.is_unnamed
    );
    
    if (blockIndex === -1) return;
    
    const block = pendingChanges[routingType].blocks[blockIndex];
    const normalizedDuplicates = duplicates.map(d => d.toLowerCase());
    
    // Удаляем дубликаты, оставляя только первое вхождение
    const seen = {};
    const hostsAuto = (block.hosts && Array.isArray(block.hosts.auto)) ? block.hosts.auto : [];
    const hostsUser = (block.hosts && Array.isArray(block.hosts.user)) ? block.hosts.user : [];
    const subnetsAuto = (block.subnets && Array.isArray(block.subnets.auto)) ? block.subnets.auto : [];
    const subnetsUser = (block.subnets && Array.isArray(block.subnets.user)) ? block.subnets.user : [];

    const allItems = [...hostsAuto, ...hostsUser, ...subnetsAuto, ...subnetsUser];

    const filtered = allItems.filter(item => {
        const normalizedItem = item.trim().toLowerCase();
        if (!normalizedItem) return false;
        
        if (normalizedDuplicates.includes(normalizedItem)) {
            if (seen[normalizedItem]) {
                return false; // Удаляем дубликат
            }
            seen[normalizedItem] = true;
        }
        return true;
    });
    
    // Разносим обратно по hosts/subnets, предполагая что структура не менялась,
    // а мы лишь удалили лишние повторы. Для простоты сохраняем только уникальные элементы
    // в тех же массивах user, auto оставляем как есть.
    block.hosts = block.hosts || {};
    block.subnets = block.subnets || {};
    block.hosts.auto = hostsAuto;
    block.subnets.auto = subnetsAuto;
    // Все оставшиеся элементы, которые были в hostsUser/subnetsUser, остаются там,
    // так как мы удаляли только дубли по значению.
    block.hosts.user = hostsUser.filter((item, index, self) => self.indexOf(item) === index);
    block.subnets.user = subnetsUser.filter((item, index, self) => self.indexOf(item) === index);

    pendingChanges[routingType].modified = true;
}

// Показать диалоговое окно с проблемами валидации и решениями
function showValidationDialog(issues, onContinue, onCancel) {
    const hasIssues = issues.duplicates.length > 0 || issues.internalDuplicates.length > 0;
    
    if (!hasIssues) {
        // Нет проблем, продолжаем
        onContinue();
        return;
    }
    
    // Создаем уникальный ID для диалога
    const dialogId = 'validation-dialog-' + Date.now();
    
    // Формируем сообщение с кнопками решений
    let message = '<div style="max-height: 500px; overflow-y: auto; text-align: left;">';
    message += '<h3 style="margin-top: 0; color: #ff3b30;">Обнаружены проблемы валидации:</h3>';
    
    // Дубликаты между блоками
    if (issues.duplicates.length > 0) {
        message += '<h4 style="color: #ff9500; margin-top: 15px;">Элементы в нескольких блоках:</h4>';
        message += '<div style="margin: 10px 0;">';
        
        issues.duplicates.forEach((dup, index) => {
            message += `<div style="margin: 10px 0; padding: 10px; background: #f5f5f7; border-radius: 8px; border-left: 3px solid #ff9500;">`;
            message += `<div style="margin-bottom: 8px;"><strong>${escapeHtml(dup.item)}</strong> находится в:</div>`;
            message += `<div style="margin-left: 15px; margin-bottom: 10px;">`;
            dup.blocks.forEach((block, blockIndex) => {
                message += `<div style="margin: 5px 0;">• ${escapeHtml(block.blockName)} (${escapeHtml(block.routingTypeName)})</div>`;
            });
            message += `</div>`;
            message += `<div style="margin-top: 10px;">Решение: оставить только в</div>`;
            message += `<div style="margin-top: 8px; display: flex; gap: 8px; flex-wrap: wrap;">`;
            dup.blocks.forEach((block, blockIndex) => {
                const btnId = `fix-dup-${index}-${blockIndex}`;
                message += `<button id="${btnId}" class="btn btn-secondary btn-sm" style="font-size: 12px; padding: 6px 12px;">${escapeHtml(block.blockName)}</button>`;
            });
            message += `</div>`;
            message += `</div>`;
        });
        
        message += '</div>';
    }
    
    // Дубликаты внутри блоков
    if (issues.internalDuplicates.length > 0) {
        message += '<h4 style="color: #ff9500; margin-top: 20px;">Дубликаты внутри блоков:</h4>';
        message += '<div style="margin: 10px 0;">';
        
        issues.internalDuplicates.forEach((dup, index) => {
            message += `<div style="margin: 10px 0; padding: 10px; background: #f5f5f7; border-radius: 8px; border-left: 3px solid #ff9500;">`;
            message += `<div style="margin-bottom: 8px;"><strong>${escapeHtml(dup.blockName)}</strong> (${escapeHtml(dup.routingTypeName)})</div>`;
            const dupList = dup.duplicates.slice(0, 10).map(d => escapeHtml(d)).join(', ');
            const more = dup.duplicates.length > 10 ? ` и еще ${dup.duplicates.length - 10}` : '';
            message += `<div style="margin: 5px 0; color: #6e6e73;">Дубликаты: ${dupList}${more}</div>`;
            const btnId = `fix-internal-${index}`;
            message += `<button id="${btnId}" class="btn btn-secondary btn-sm" style="margin-top: 8px; font-size: 12px; padding: 6px 12px;">Убрать дублирование</button>`;
            message += `</div>`;
        });
        
        message += '</div>';
    }
    
    message += '</div>';
    
    // Используем confirm modal, но с кастомным сообщением
    const modal = document.getElementById('confirmModal');
    const titleEl = document.getElementById('confirmModalTitle');
    const messageEl = document.getElementById('confirmModalMessage');
    const okBtn = document.getElementById('confirmModalOkBtn');
    const cancelBtn = document.getElementById('confirmModalCancelBtn');
    
    titleEl.textContent = 'Проблемы валидации';
    messageEl.innerHTML = message;
    okBtn.textContent = 'Продолжить всё равно';
    
    // Показываем кнопку отмены
    if (cancelBtn) {
        cancelBtn.style.display = 'inline-block';
    }
    
    // Добавляем обработчики для кнопок исправления
    setTimeout(() => {
        // Обработчики для дубликатов между блоками
        issues.duplicates.forEach((dup, index) => {
            dup.blocks.forEach((block, blockIndex) => {
                const btnId = `fix-dup-${index}-${blockIndex}`;
                const btn = document.getElementById(btnId);
                if (btn) {
                    btn.addEventListener('click', () => {
                        const keepInBlock = block;
                        const removeFromBlocks = dup.blocks.filter((b, i) => i !== blockIndex);
                        fixDuplicateBetweenBlocks(dup.item, keepInBlock, removeFromBlocks);
                        showToast(`Элемент "${dup.item}" оставлен только в блоке "${block.blockName}"`);
                        
                        // Перезагружаем блоки
                        loadRoutingBlocks(keepInBlock.routingType, true);
                        removeFromBlocks.forEach(b => loadRoutingBlocks(b.routingType, true));
                        
                        // Перепроверяем валидацию
                        setTimeout(async () => {
                            const newIssues = await validateRoutingBlocks();
                            if (newIssues.duplicates.length === 0 && newIssues.internalDuplicates.length === 0) {
                                closeConfirmModal();
                                onContinue();
                            } else {
                                showValidationDialog(newIssues, onContinue, onCancel);
                            }
                        }, 500);
                    });
                }
            });
        });
        
        // Обработчики для дубликатов внутри блоков
        issues.internalDuplicates.forEach((dup, index) => {
            const btnId = `fix-internal-${index}`;
            const btn = document.getElementById(btnId);
            if (btn) {
                btn.addEventListener('click', () => {
                    fixInternalDuplicates(dup, dup.duplicates);
                    showToast(`Дубликаты удалены из блока "${dup.blockName}"`);
                    
                    // Перезагружаем блоки
                    loadRoutingBlocks(dup.routingType, true);
                    
                    // Перепроверяем валидацию
                    setTimeout(async () => {
                        const newIssues = await validateRoutingBlocks();
                        if (newIssues.duplicates.length === 0 && newIssues.internalDuplicates.length === 0) {
                            closeConfirmModal();
                            onContinue();
                        } else {
                            showValidationDialog(newIssues, onContinue, onCancel);
                        }
                    }, 500);
                });
            }
        });
    }, 100);
    
    // Удаляем inline обработчик и добавляем свой
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
    
    // Устанавливаем новый обработчик подтверждения
    confirmModalCallback = () => {
        onContinue();
        // Восстанавливаем оригинальный обработчик отмены
        if (cancelBtn && cancelHandler) {
            cancelBtn.removeEventListener('click', cancelHandler);
            cancelBtn.setAttribute('onclick', 'closeConfirmModal()');
        }
    };
    
    modal.style.display = 'block';
}

// Сохранение всех изменений
async function saveAllRoutingChanges() {
    const saveBtn = document.getElementById('save-routing-changes-btn');
    if (saveBtn) {
        saveBtn.disabled = true;
        saveBtn.textContent = 'Проверка...';
    }
    
    try {
        // Валидация перед сохранением
        showToast('Проверка на дубликаты...', 2000);
        const validationIssues = await validateRoutingBlocks();
        
        // Показываем диалог с проблемами, если они есть
        showValidationDialog(
            validationIssues,
            // onContinue - продолжить сохранение
            async () => {
                if (saveBtn) {
                    saveBtn.textContent = 'Сохранение...';
                }
                
                try {
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
            },
            // onCancel - отменить сохранение
            () => {
                if (saveBtn) {
                    saveBtn.disabled = false;
                    saveBtn.textContent = 'Сохранить изменения';
                }
            }
        );
        
    } catch (error) {
        console.error('Error validating changes:', error);
        showToast('Ошибка при проверке: ' + error.message, 3000);
        if (saveBtn) {
            saveBtn.disabled = false;
            saveBtn.textContent = 'Сохранить изменения';
        }
    }
}

// Загрузка всех блоков при загрузке страницы
document.addEventListener('DOMContentLoaded', function() {
    // Проверяем, что мы на странице маршрутизации
    if (document.querySelector('.routing-container')) {
        // Загружаем блоки для всех колонок
        loadRoutingBlocks('direct');
        loadRoutingBlocks('bypass');
        loadRoutingBlocks('vpn');
    }
});

