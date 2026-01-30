# -*- coding: utf-8 -*-

"""
API для управления маршрутизацией (routing blocks)
Работа с ipset'ами: NONBYPASS, ZAPRET, bypass
"""

from flask import Blueprint, jsonify, request
import os
import re
import sys
import subprocess

# Добавляем родительскую директорию в путь для импорта
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from api.common import check_auth, handle_api_error
import paths

routing_api = Blueprint('routing_api', __name__)

# Пути к hosts-файлам
IPSETS_DIR = f'{paths.ETC_DIR}/allow/dnsmasq-full/ipsets'
NONBYPASS_FILE = f'{IPSETS_DIR}/nonbypass.txt'
ZAPRET_FILE = f'{IPSETS_DIR}/zapret.txt'
BYPASS_FILE = f'{IPSETS_DIR}/bypass.txt'

# Создаем директорию если не существует
os.makedirs(IPSETS_DIR, exist_ok=True)


def generate_block_id(name):
    """Генерирует ID блока из названия"""
    # Транслитерация и нормализация
    translit_map = {
        'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'е': 'e', 'ё': 'yo',
        'ж': 'zh', 'з': 'z', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
        'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
        'ф': 'f', 'х': 'h', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'sch',
        'ъ': '', 'ы': 'y', 'ь': '', 'э': 'e', 'ю': 'yu', 'я': 'ya'
    }
    
    name_lower = name.lower()
    result = ''
    for char in name_lower:
        if char in translit_map:
            result += translit_map[char]
        elif char.isalnum() or char == '_':
            result += char
        elif char in ' -':
            result += '_'
    
    # Убираем множественные подчеркивания
    result = re.sub(r'_+', '_', result)
    result = result.strip('_')
    
    return result if result else 'block_' + str(hash(name) % 10000)


def is_ip(item):
    """Проверяет, является ли строка IP-адресом"""
    # Простая проверка: содержит только цифры, точки, слэши, двоеточия (для IPv6)
    item_clean = item.strip()
    # IPv4: 192.168.1.1 или 10.0.0.0/8
    if re.match(r'^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$', item_clean):
        return True
    # IPv6: 2001:0db8::1 или 2001:0db8::/32
    if ':' in item_clean and '/' in item_clean:
        return True
    return False


def parse_hosts_file(file_path):
    """
    Парсит hosts-файл и извлекает блоки
    
    Логика:
    1. Парсим все блоки с @BLOCK_START/@BLOCK_END
    2. Собираем строки вне блоков (не комментарии, не пустые)
    3. Если есть такие строки - создаем виртуальный блок "UNNAMED"
    """
    blocks = []
    unnamed_items = []
    
    if not os.path.exists(file_path):
        return blocks
    
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        # Находим все позиции блоков
        block_pattern = r'#\s*@BLOCK_START:([^:]+):(HOSTS|IPS)\s*\n(.*?)\n#\s*@BLOCK_END'
        matches = list(re.finditer(block_pattern, content, re.DOTALL | re.MULTILINE))
        
        # Собираем позиции всех блоков для определения строк вне блоков
        block_ranges = []
        for match in matches:
            start_pos = match.start()
            end_pos = match.end()
            block_ranges.append((start_pos, end_pos))
            
            # Парсим блок
            name = match.group(1).strip()
            block_type = match.group(2).strip()
            items_text = match.group(3).strip()
            
            # Парсим элементы (хосты или IP)
            items = []
            for line in items_text.split('\n'):
                line = line.strip()
                # Пропускаем комментарии и пустые строки
                if line and not line.startswith('#'):
                    items.append(line)
            
            if items:  # Добавляем только непустые блоки
                blocks.append({
                    'id': generate_block_id(name),
                    'name': name,
                    'type': block_type,
                    'items': items,
                    'is_unnamed': False
                })
        
        # Теперь собираем строки вне блоков
        # Проходим по файлу построчно и проверяем, находится ли строка в блоке
        lines = content.split('\n')
        current_pos = 0
        
        for line in lines:
            line_stripped = line.strip()
            line_start = current_pos
            line_end = current_pos + len(line)
            
            # Пропускаем пустые строки и комментарии
            if not line_stripped or line_stripped.startswith('#'):
                current_pos = line_end + 1  # +1 для \n
                continue
            
            # Проверяем, находится ли строка внутри какого-либо блока
            in_block = False
            for block_start, block_end in block_ranges:
                # Если строка пересекается с блоком (начало строки внутри блока или конец внутри блока)
                if line_start < block_end and line_end > block_start:
                    in_block = True
                    break
            
            if not in_block:
                unnamed_items.append(line_stripped)
            
            current_pos = line_end + 1  # +1 для \n
        
        # Если есть строки вне блоков - создаем виртуальный блок UNNAMED
        if unnamed_items:
            blocks.append({
                'id': 'unnamed',
                'name': 'UNNAMED',
                'type': 'HOSTS',  # Тип не важен для UNNAMED
                'items': unnamed_items,
                'is_unnamed': True
            })
        
    except Exception as e:
        print(f"Error parsing hosts file {file_path}: {e}")
        import traceback
        traceback.print_exc()
    
    return blocks


def write_hosts_file(file_path, blocks):
    """
    Записывает блоки обратно в hosts-файл в новом формате
    UNNAMED блоки не сохраняются (они виртуальные)
    """
    try:
        os.makedirs(os.path.dirname(file_path), exist_ok=True)
        
        lines = []
        lines.append('# Файл hosts для исключения из всех списков')
        lines.append('# Формат: IP domain или просто domain')
        lines.append('#')
        lines.append('# Блоки маршрутизации:')
        lines.append('# @BLOCK_START:Название:TYPE')
        lines.append('# где TYPE = HOSTS или IPS')
        lines.append('')
        
        # Сохраняем только обычные блоки (не UNNAMED)
        for block in blocks:
            if block.get('is_unnamed', False):
                continue  # Пропускаем UNNAMED блоки
            
            lines.append(f'# @BLOCK_START:{block["name"]}:{block["type"]}')
            for item in block['items']:
                lines.append(item)
            lines.append('# @BLOCK_END')
            lines.append('')
        
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines))
        
        return True
    except Exception as e:
        print(f"Error writing hosts file {file_path}: {e}")
        import traceback
        traceback.print_exc()
        return False


@routing_api.route('/blocks/<routing_type>', methods=['GET'])
def get_blocks(routing_type):
    """Получить блоки для типа маршрутизации (direct, bypass, vpn)"""
    try:
        if not check_auth():
            return jsonify({'error': 'Unauthorized'}), 401
        
        # Маппинг типов маршрутизации на файлы
        file_map = {
            'direct': NONBYPASS_FILE,  # Напрямую -> NONBYPASS
            'bypass': ZAPRET_FILE,  # Обход -> ZAPRET
            'vpn': BYPASS_FILE,  # VPN -> bypass
            'geoblock1': BYPASS_FILE  # GeoBlock 1 -> bypass
        }
        
        if routing_type not in file_map:
            return jsonify({'error': 'Invalid routing type'}), 400
        
        file_path = file_map[routing_type]
        blocks = parse_hosts_file(file_path)
        
        return jsonify({
            'success': True,
            'routing_type': routing_type,
            'file_path': file_path,
            'blocks': blocks
        })
    except Exception as e:
        print(f"Error in get_blocks: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e), 'success': False}), 500


@routing_api.route('/blocks/<routing_type>', methods=['POST'])
def save_blocks(routing_type):
    """Сохранить блоки для типа маршрутизации"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    file_map = {
        'direct': NONBYPASS_FILE,
        'bypass': ZAPRET_FILE,
        'vpn': BYPASS_FILE,
        'geoblock1': BYPASS_FILE
    }
    
    if routing_type not in file_map:
        return jsonify({'error': 'Invalid routing type'}), 400
    
    data = request.get_json()
    if not data or 'blocks' not in data:
        return jsonify({'error': 'Missing blocks data'}), 400
    
    blocks = data['blocks']
    
    # Валидация блоков
    for block in blocks:
        if 'name' not in block or 'type' not in block or 'items' not in block:
            return jsonify({'error': 'Invalid block format'}), 400
        if block['type'] not in ['HOSTS', 'IPS']:
            return jsonify({'error': 'Invalid block type'}), 400
        # UNNAMED блоки нельзя сохранять
        if block.get('is_unnamed', False) or block.get('name') == 'UNNAMED':
            return jsonify({'error': 'UNNAMED blocks cannot be saved'}), 400
    
    file_path = file_map[routing_type]
    if write_hosts_file(file_path, blocks):
        return jsonify({'success': True, 'message': 'Blocks saved successfully'})
    else:
        return jsonify({'error': 'Failed to save blocks'}), 500


@routing_api.route('/blocks/<routing_type>/<block_id>', methods=['GET'])
def get_block(routing_type, block_id):
    """Получить конкретный блок"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    file_map = {
        'direct': NONBYPASS_FILE,
        'bypass': ZAPRET_FILE,
        'vpn': BYPASS_FILE,
        'geoblock1': BYPASS_FILE
    }
    
    if routing_type not in file_map:
        return jsonify({'error': 'Invalid routing type'}), 400
    
    file_path = file_map[routing_type]
    blocks = parse_hosts_file(file_path)
    
    block = next((b for b in blocks if b['id'] == block_id), None)
    if not block:
        return jsonify({'error': 'Block not found'}), 404
    
    return jsonify({'success': True, 'block': block})


@routing_api.route('/blocks/<routing_type>/<block_id>/items', methods=['POST'])
def save_block_items(routing_type, block_id):
    """Сохранить элементы конкретного блока (хосты или IP)"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    file_map = {
        'direct': NONBYPASS_FILE,
        'bypass': ZAPRET_FILE,
        'vpn': BYPASS_FILE,
        'geoblock1': BYPASS_FILE
    }
    
    if routing_type not in file_map:
        return jsonify({'error': 'Invalid routing type'}), 400
    
    data = request.get_json()
    if not data or 'items' not in data:
        return jsonify({'error': 'Missing items data'}), 400
    
    items = data['items']
    if not isinstance(items, list):
        return jsonify({'error': 'Items must be a list'}), 400
    
    # Загружаем все блоки
    file_path = file_map[routing_type]
    blocks = parse_hosts_file(file_path)
    
    # Находим и обновляем блок
    block_found = False
    for block in blocks:
        if block['id'] == block_id:
            # UNNAMED блок нельзя редактировать
            if block.get('is_unnamed', False):
                return jsonify({'error': 'UNNAMED block cannot be edited'}), 400
            block['items'] = items
            block_found = True
            break
    
    if not block_found:
        return jsonify({'error': 'Block not found'}), 404
    
    # Сохраняем обратно (UNNAMED блоки не сохраняются)
    if write_hosts_file(file_path, blocks):
        return jsonify({'success': True, 'message': 'Block items saved successfully'})
    else:
        return jsonify({'error': 'Failed to save block items'}), 500


@routing_api.route('/apply', methods=['POST'])
def apply_changes():
    """
    Применить изменения маршрутизации:
    1. Очистить все IPSET, созданные dnsmasq-full
    2. Перезагрузить dnsmasq-full
    """
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Список всех IPSET, которые создает dnsmasq-full
        ipsets = ['nonbypass', 'bypass']
        
        # Очищаем все IPSET
        cleared_ipsets = []
        for ipset_name in ipsets:
            try:
                # Проверяем, существует ли ipset
                result = subprocess.run(
                    ['ipset', 'list', ipset_name],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                
                if result.returncode == 0:
                    # IPSET существует, очищаем его
                    flush_result = subprocess.run(
                        ['ipset', 'flush', ipset_name],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    
                    if flush_result.returncode == 0:
                        cleared_ipsets.append(ipset_name)
                    else:
                        print(f"Warning: Failed to flush ipset {ipset_name}: {flush_result.stderr}")
                # Если ipset не существует, просто пропускаем
            except subprocess.TimeoutExpired:
                print(f"Warning: Timeout while checking/flushing ipset {ipset_name}")
            except Exception as e:
                print(f"Warning: Error processing ipset {ipset_name}: {e}")
        
        # Перезагружаем dnsmasq-full
        DNSMASQ_INIT_SCRIPT = paths.DNSMASQ_INIT_SCRIPT
        DNSMASQ_PID_FILE = paths.DNSMASQ_PID_FILE
        
        # Проверяем альтернативные пути к скрипту
        if not os.path.exists(DNSMASQ_INIT_SCRIPT):
            # Пробуем альтернативный путь
            alt_script = f'{paths.ETC_DIR}/allow/dnsmasq-full/init.d/S98dnsmasq-full'
            if os.path.exists(alt_script):
                DNSMASQ_INIT_SCRIPT = alt_script
            else:
                return jsonify({
                    'success': False,
                    'error': f'DNSMASQ init script not found. Tried: {paths.DNSMASQ_INIT_SCRIPT}, {alt_script}'
                }), 500
        
        # Остановка
        subprocess.run([DNSMASQ_INIT_SCRIPT, 'stop'], check=False, capture_output=True)
        
        import time
        time.sleep(2)
        
        # Запуск
        result = subprocess.run(
            [DNSMASQ_INIT_SCRIPT, 'start'],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        time.sleep(2)
        
        # Проверяем что запустился
        is_running = False
        
        if os.path.exists(DNSMASQ_PID_FILE):
            try:
                with open(DNSMASQ_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        is_running = True
            except:
                pass
        
        if not is_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'dnsmasq' in line and 'grep' not in line:
                        if 'dnsmasq-full.conf' in line or '/opt' in line:
                            is_running = True
                            break
        
        dnsmasq_success = result.returncode == 0 and is_running
        
        if dnsmasq_success:
            return jsonify({
                'success': True,
                'message': 'Changes applied successfully',
                'cleared_ipsets': cleared_ipsets,
                'dnsmasq_restarted': True,
                'dnsmasq_running': is_running
            })
        else:
            return jsonify({
                'success': False,
                'error': result.stderr or 'Failed to restart dnsmasq',
                'cleared_ipsets': cleared_ipsets,
                'dnsmasq_restarted': False,
                'dnsmasq_running': is_running,
                'zapret_restarted': zapret_restarted,
                'zapret_running': zapret_running
            }), 500
            
    except Exception as e:
        print(f"Error in apply_changes: {e}")
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e), 'success': False}), 500

