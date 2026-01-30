# -*- coding: utf-8 -*-

"""
API для управления Stubby
"""

from flask import Blueprint, jsonify, request
import subprocess
import os
import socket
import sys
import shutil

# Добавляем родительскую директорию в путь для импорта config
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config

stubby_api = Blueprint('stubby_api', __name__)

# Импортируем пути из централизованного модуля
import paths
from api.common import run_init_status_kv, get_ports_from_status_kv

# Используем пути из paths.py
STUBBY_INIT_SCRIPT = paths.STUBBY_INIT_SCRIPT
STUBBY_CONFIG_FILE = paths.STUBBY_CONFIG_FILE
STUBBY_PID_FILE = paths.STUBBY_PID_FILE

def get_stubby_ports():
    """
    Возвращает порты stubby по policy 1 (active если running, иначе config).
    """
    kv = run_init_status_kv(STUBBY_INIT_SCRIPT)
    config_port, active_port, effective_port, mismatch, status = get_ports_from_status_kv(
        kv,
        default_port=41500
    )
    return {
        'status_kv': kv,
        'status': status,  # running|notrunning|None
        'config_port': config_port,
        'active_port': active_port,
        'effective_port': effective_port,
        'mismatch': mismatch,
    }


def check_auth():
    """Проверка аутентификации через токен"""
    from flask import request
    token = request.headers.get('X-Auth-Token')
    if token != config.AUTH_TOKEN:
        return False
    return True


def check_port(port):
    """Проверка открытости порта"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(1)
        result = sock.connect_ex(('127.0.0.1', port))
        sock.close()
        return result == 0
    except:
        return False


@stubby_api.route('/status', methods=['GET'])
def get_status():
    """Получить статус Stubby"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        is_running = False
        pid = None
        
        # Проверка через PID файл
        if os.path.exists(STUBBY_PID_FILE):
            try:
                with open(STUBBY_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        # Проверяем что это действительно stubby
                        try:
                            with open(f'/proc/{pid}/cmdline', 'r') as cmd:
                                cmdline = cmd.read()
                                if 'stubby' in cmdline and 'stubby.yml' in cmdline:
                                    is_running = True
                        except:
                            pass
            except:
                pass
        
        # Если PID файл не помог, проверяем через ps
        if not is_running:
            result_list = subprocess.run(
                ['ps', 'w'],
                capture_output=True,
                text=True
            )
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'stubby' in line and 'stubby.yml' in line and 'grep' not in line:
                        parts = line.split()
                        if len(parts) > 0:
                            try:
                                pid = parts[0]
                                if os.path.exists(f'/proc/{pid}'):
                                    is_running = True
                                    break
                            except:
                                pass
        
        ports = get_stubby_ports()
        effective_port = ports.get('effective_port')
        config_port = ports.get('config_port')
        active_port = ports.get('active_port')
        mismatch = ports.get('mismatch')

        # Если init status доступен — доверяем ему по running/pid
        if ports.get('status') in ('running', 'notrunning'):
            is_running = (ports.get('status') == 'running')
            kv_pid = ports.get('status_kv', {}).get('PID')
            pid = kv_pid or pid

        # Проверка порта (policy 1: проверяем effective_port)
        port_open = check_port(int(effective_port)) if effective_port else False

        return jsonify({
            'running': is_running,
            'port_open': port_open,
            'pid': pid,
            # backward-compat field
            'port': effective_port,
            'config_port': config_port,
            'active_port': active_port,
            'effective_port': effective_port,
            'mismatch': mismatch,
            'status': 'running' if is_running else 'stopped'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@stubby_api.route('/start', methods=['POST'])
def start():
    """Запустить Stubby"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Проверяем что не запущен
        is_running_check = False
        if os.path.exists(STUBBY_PID_FILE):
            try:
                with open(STUBBY_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        is_running_check = True
            except:
                pass
        
        if not is_running_check:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'stubby' in line and 'stubby.yml' in line and 'grep' not in line:
                        is_running_check = True
                        break
        
        if is_running_check:
            return jsonify({
                'success': False,
                'message': 'Stubby already running'
            }), 400
        
        # Проверяем конфигурацию перед запуском
        config_check = subprocess.run(
            ['stubby', '-C', STUBBY_CONFIG_FILE, '-i'],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if config_check.returncode != 0:
            error_msg = config_check.stderr if config_check.stderr else config_check.stdout
            return jsonify({
                'success': False,
                'error': f'Configuration error: {error_msg}',
                'message': 'Stubby configuration is invalid'
            }), 400
        
        # Запуск
        result = subprocess.run(
            [STUBBY_INIT_SCRIPT, 'start'],
            capture_output=True,
            text=True
        )
        
        import time
        time.sleep(2)
        
        # Проверяем что запустился
        is_running = False
        pid = None
        if os.path.exists(STUBBY_PID_FILE):
            try:
                with open(STUBBY_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        is_running = True
            except:
                pass
        
        if not is_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'stubby' in line and 'stubby.yml' in line and 'grep' not in line:
                        parts = line.split()
                        if len(parts) > 0:
                            try:
                                pid = parts[0]
                                if os.path.exists(f'/proc/{pid}'):
                                    is_running = True
                                    break
                            except:
                                pass
        
        ports = get_stubby_ports()
        effective_port = ports.get('effective_port')
        port_open = check_port(int(effective_port)) if (is_running and effective_port) else False

        if result.returncode == 0 and is_running:
            return jsonify({
                'success': True,
                'message': 'Stubby started successfully',
                'is_running': is_running,
                'port_open': port_open,
                'pid': pid
            })
        else:
            error_msg = result.stderr if result.stderr else result.stdout

            return jsonify({
                'success': False,
                'error': error_msg or 'Failed to start',
                'is_running': is_running,
                'port_open': port_open,
                'details': None
            }), 500
            
    except subprocess.TimeoutExpired:
        return jsonify({
            'success': False,
            'error': 'Start timeout',
            'message': 'Stubby start took too long'
        }), 500
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e),
            'message': 'Unexpected error during start'
        }), 500


@stubby_api.route('/stop', methods=['POST'])
def stop():
    """Остановить Stubby"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Проверяем что запущен
        was_running = False
        if os.path.exists(STUBBY_PID_FILE):
            try:
                with open(STUBBY_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        was_running = True
            except:
                pass
        
        if not was_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'stubby' in line and 'stubby.yml' in line and 'grep' not in line:
                        was_running = True
                        break
        
        if not was_running:
            return jsonify({
                'success': False,
                'message': 'Stubby is not running'
            }), 400
        
        # Остановка
        subprocess.run([STUBBY_INIT_SCRIPT, 'stop'], check=False, capture_output=True)
        
        import time
        time.sleep(2)
        
        # Проверяем что остановился
        is_running = False
        if os.path.exists(STUBBY_PID_FILE):
            try:
                with open(STUBBY_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        is_running = True
            except:
                pass
        
        if not is_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'stubby' in line and 'stubby.yml' in line and 'grep' not in line:
                        is_running = True
                        break
        
        # Если все еще запущен, убиваем принудительно
        if is_running:
            result_pid = subprocess.run(['pgrep', '-f', 'stubby.*stubby.yml'], capture_output=True, text=True)
            if result_pid.returncode == 0:
                pids = result_pid.stdout.strip().split('\n')
                for pid in pids:
                    if pid.strip():
                        try:
                            subprocess.run(['kill', '-9', pid.strip()], check=False, capture_output=True)
                        except:
                            pass
            
            time.sleep(1)
            result_final = subprocess.run(['pgrep', '-f', 'stubby.*stubby.yml'], capture_output=True)
            is_running = result_final.returncode == 0
        
        if not is_running:
            return jsonify({
                'success': True,
                'message': 'Stubby stopped successfully',
                'was_running': was_running,
                'is_running': is_running
            })
        else:
            return jsonify({
                'success': False,
                'error': 'Failed to stop Stubby process',
                'was_running': was_running,
                'is_running': is_running
            }), 500
            
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@stubby_api.route('/restart', methods=['POST'])
def restart():
    """Перезапустить Stubby"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Получаем статус до перезапуска
        was_running = False
        if os.path.exists(STUBBY_PID_FILE):
            try:
                with open(STUBBY_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        was_running = True
            except:
                pass
        
        if not was_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'stubby' in line and 'stubby.yml' in line and 'grep' not in line:
                        was_running = True
                        break
        
        # Остановка
        subprocess.run([STUBBY_INIT_SCRIPT, 'stop'], check=False)
        
        import time
        time.sleep(2)
        
        # Запуск
        result = subprocess.run(
            [STUBBY_INIT_SCRIPT, 'start'],
            capture_output=True,
            text=True
        )
        
        time.sleep(2)
        
        # Проверяем что запустился
        is_running = False
        pid = None
        if os.path.exists(STUBBY_PID_FILE):
            try:
                with open(STUBBY_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        is_running = True
            except:
                pass
        
        if not is_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'stubby' in line and 'stubby.yml' in line and 'grep' not in line:
                        parts = line.split()
                        if len(parts) > 0:
                            try:
                                pid = parts[0]
                                if os.path.exists(f'/proc/{pid}'):
                                    is_running = True
                                    break
                            except:
                                pass
        
        ports = get_stubby_ports()
        effective_port = ports.get('effective_port')
        port_open = check_port(int(effective_port)) if (is_running and effective_port) else False
        
        if result.returncode == 0 and is_running:
            return jsonify({
                'success': True, 
                'message': 'Stubby restarted successfully',
                'was_running': was_running,
                'is_running': is_running,
                'port_open': port_open,
                'pid': pid
            })
        else:
            return jsonify({
                'success': False, 
                'error': result.stderr or 'Failed to start',
                'was_running': was_running,
                'is_running': is_running,
                'port_open': port_open
            }), 500
            
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def parse_yaml_simple(yaml_content):
    """Простой парсер YAML для базовых структур"""
    result = {}
    lines = yaml_content.split('\n')
    stack = [result]
    indent_stack = [-1]
    
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        
        # Определяем уровень отступа
        indent = len(line) - len(line.lstrip())
        
        # Убираем элементы стека с большим отступом
        while len(indent_stack) > 1 and indent_stack[-1] >= indent:
            stack.pop()
            indent_stack.pop()
        
        # Обрабатываем строку
        if ':' in stripped:
            parts = stripped.split(':', 1)
            key = parts[0].strip()
            value = parts[1].strip() if len(parts) > 1 else ''
            
            # Убираем кавычки
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1]
            
            current = stack[-1]
            
            if value == '':
                # Вложенная структура
                new_dict = {}
                current[key] = new_dict
                stack.append(new_dict)
                indent_stack.append(indent)
            else:
                # Простое значение
                # Пробуем преобразовать в число или булево
                if value.lower() == 'true':
                    current[key] = True
                elif value.lower() == 'false':
                    current[key] = False
                elif value.isdigit():
                    current[key] = int(value)
                else:
                    try:
                        # Пробуем float
                        if '.' in value:
                            current[key] = float(value)
                        else:
                            current[key] = value
                    except:
                        current[key] = value
        elif stripped.startswith('-'):
            # Элемент массива
            item = stripped[1:].strip()
            current = stack[-1]
            
            # Находим последний ключ (для массива)
            if isinstance(current, dict) and len(current) > 0:
                last_key = list(current.keys())[-1]
                if not isinstance(current[last_key], list):
                    current[last_key] = []
                current[last_key].append(item.strip('"\'') if item else {})
            else:
                # Массив на верхнем уровне (не должно быть в нашем случае)
                if not isinstance(current, list):
                    current = []
                current.append(item.strip('"\''))
    
    return result


def yaml_to_dict_simple(yaml_content):
    """Конвертирует простой YAML в словарь (для массивов вложенных объектов)"""
    result = {}
    lines = yaml_content.split('\n')
    
    # Стек для отслеживания вложенности: (indent, dict)
    stack = [(-1, result)]
    
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            i += 1
            continue
        
        indent = len(line) - len(line.lstrip())
        
        # Убираем элементы стека с большим или равным отступом
        while len(stack) > 1 and stack[-1][0] >= indent:
            stack.pop()
        
        current_dict = stack[-1][1]
        
        # Обрабатываем ключ: значение
        if ':' in stripped and not stripped.startswith('-'):
            parts = stripped.split(':', 1)
            key = parts[0].strip()
            value = parts[1].strip() if len(parts) > 1 else ''
            
            # Убираем кавычки
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1]
            
            # Преобразуем значение
            if value == '':
                # Вложенная структура (может быть массив или объект)
                # Создаем как пустой словарь, будет преобразован в массив при первом `-`
                current_dict[key] = {}
                stack.append((indent, current_dict[key]))
            else:
                # Простое значение
                if value.lower() == 'true':
                    current_dict[key] = True
                elif value.lower() == 'false':
                    current_dict[key] = False
                elif value.isdigit():
                    current_dict[key] = int(value)
                else:
                    try:
                        if '.' in value:
                            current_dict[key] = float(value)
                        else:
                            current_dict[key] = value
                    except:
                        current_dict[key] = value
        elif stripped.startswith('-'):
            # Элемент массива
            item_content = stripped[1:].strip()
            
            # Если current_dict пустой, значит мы внутри пустого словаря, который должен быть массивом
            # Нужно найти родительский словарь и ключ в нем
            array_key = None
            array_dict = None
            
            if len(current_dict) == 0 and len(stack) > 1:
                # Мы внутри пустого словаря - берем родительский словарь
                parent_stack_item = stack[-2]  # Предыдущий элемент стека
                parent_dict = parent_stack_item[1]
                # Ищем последний ключ в родительском словаре, который является пустым словарем
                for k in reversed(list(parent_dict.keys())):
                    if isinstance(parent_dict[k], dict) and len(parent_dict[k]) == 0:
                        array_key = k
                        array_dict = parent_dict
                        parent_dict[k] = []  # Преобразуем в массив
                        break
            else:
                # Ищем в текущем словаре
                for k in reversed(list(current_dict.keys())):
                    if isinstance(current_dict[k], list):
                        array_key = k
                        array_dict = current_dict
                        break
                    elif isinstance(current_dict[k], dict) and len(current_dict[k]) == 0:
                        # Пустой словарь - преобразуем в массив
                        array_key = k
                        array_dict = current_dict
                        current_dict[k] = []
                        break
            
            if array_key is None:
                # Берем последний ключ из текущего словаря
                if len(current_dict) > 0:
                    array_key = list(current_dict.keys())[-1]
                    array_dict = current_dict
                    if isinstance(current_dict[array_key], dict) and len(current_dict[array_key]) == 0:
                        current_dict[array_key] = []
                    elif not isinstance(current_dict[array_key], list):
                        i += 1
                        continue
                elif len(stack) > 1:
                    # Пробуем найти в родительском словаре
                    parent_stack_item = stack[-2]
                    parent_dict = parent_stack_item[1]
                    if len(parent_dict) > 0:
                        array_key = list(parent_dict.keys())[-1]
                        array_dict = parent_dict
                        if isinstance(parent_dict[array_key], dict) and len(parent_dict[array_key]) == 0:
                            parent_dict[array_key] = []
                        elif not isinstance(parent_dict[array_key], list):
                            i += 1
                            continue
                    else:
                        i += 1
                        continue
                else:
                    i += 1
                    continue
            
            if array_key is None or array_dict is None:
                i += 1
                continue
            
            # Убеждаемся что это массив
            if not isinstance(array_dict[array_key], list):
                if isinstance(array_dict[array_key], dict) and len(array_dict[array_key]) == 0:
                    array_dict[array_key] = []
                else:
                    i += 1
                    continue
            
            # Проверяем следующую строку - это может быть объект
            if i + 1 < len(lines):
                next_line = lines[i + 1]
                next_stripped = next_line.strip()
                next_indent = len(next_line) - len(next_line.lstrip())
                
                if next_indent > indent and ':' in next_stripped and not next_stripped.startswith('-'):
                    # Это объект в массиве
                    item_dict = {}
                    array_dict[array_key].append(item_dict)
                    i += 1
                    
                    # Читаем все строки объекта
                    while i < len(lines):
                        obj_line = lines[i]
                        obj_stripped = obj_line.strip()
                        obj_indent = len(obj_line) - len(obj_line.lstrip())
                        
                        if obj_indent <= indent:
                            break
                        
                        if ':' in obj_stripped and not obj_stripped.startswith('-'):
                            obj_parts = obj_stripped.split(':', 1)
                            obj_key = obj_parts[0].strip()
                            obj_value = obj_stripped.split(':', 1)[1].strip() if len(obj_parts) > 1 else ''
                            
                            # Убираем кавычки
                            if obj_value.startswith('"') and obj_value.endswith('"'):
                                obj_value = obj_value[1:-1]
                            elif obj_value.startswith("'") and obj_value.endswith("'"):
                                obj_value = obj_value[1:-1]
                            
                            # Преобразуем значение
                            if obj_value.lower() == 'true':
                                item_dict[obj_key] = True
                            elif obj_value.lower() == 'false':
                                item_dict[obj_key] = False
                            elif obj_value.isdigit():
                                item_dict[obj_key] = int(obj_value)
                            else:
                                try:
                                    if '.' in obj_value:
                                        item_dict[obj_key] = float(obj_value)
                                    else:
                                        item_dict[obj_key] = obj_value
                                except:
                                    item_dict[obj_key] = obj_value
                        
                        i += 1
                    
                    continue
                else:
                    # Простое значение массива
                    array_dict[array_key].append(item_content.strip('"\''))
        
        i += 1
    
    return result


@stubby_api.route('/config', methods=['GET'])
def get_config():
    """Получить текущую конфигурацию Stubby"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        if not os.path.exists(STUBBY_CONFIG_FILE):
            return jsonify({'error': 'Config file not found'}), 404
        
        # Читаем YAML конфигурацию
        with open(STUBBY_CONFIG_FILE, 'r') as f:
            yaml_content = f.read()
        
        # Парсим YAML вручную
        try:
            config_data = yaml_to_dict_simple(yaml_content)
        except Exception as e:
            return jsonify({
                'error': f'Failed to parse YAML: {str(e)}',
                'yaml_content_preview': yaml_content[:500] if len(yaml_content) > 500 else yaml_content
            }), 500
        
        # Извлекаем upstream серверы для удобного управления
        upstream_servers = config_data.get('upstream_recursive_servers', [])
        
        # Проверяем тип - должно быть списком
        if not isinstance(upstream_servers, list):
            if isinstance(upstream_servers, dict):
                # Это ошибка парсинга - должно быть массивом
                # Пытаемся преобразовать словарь в список
                upstream_servers = list(upstream_servers.values()) if upstream_servers else []
            else:
                upstream_servers = []
        
        # Убеждаемся что все серверы имеют правильную структуру
        valid_servers = []
        for server in upstream_servers:
            if isinstance(server, dict) and 'address_data' in server:
                # Нормализуем структуру сервера
                normalized_server = {
                    'address_data': str(server.get('address_data', '')),
                    'tls_auth_name': str(server.get('tls_auth_name', '')),
                    'tls_port': int(server.get('tls_port', 853)) if isinstance(server.get('tls_port'), (int, str)) and str(server.get('tls_port', '')).isdigit() else 853
                }
                valid_servers.append(normalized_server)
        
        return jsonify({
            'full_config': config_data,
            'upstream_servers': valid_servers,
            'config_keys': list(config_data.keys())
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def dict_to_yaml_simple(data, indent=0):
    """Конвертирует словарь в простой YAML формат"""
    yaml_lines = []
    spaces = '  ' * indent
    
    # Сортируем ключи для стабильного вывода (но сохраняем порядок важных ключей)
    important_keys = ['resolution_type', 'round_robin_upstreams', 'appdata_dir', 
                      'tls_authentication', 'tls_query_padding_blocksize', 
                      'edns_client_subnet_private', 'idle_timeout', 'timeout',
                      'listen_addresses', 'dns_transport_list', 'upstream_recursive_servers']
    
    all_keys = list(data.keys())
    sorted_keys = []
    for key in important_keys:
        if key in all_keys:
            sorted_keys.append(key)
    for key in all_keys:
        if key not in sorted_keys:
            sorted_keys.append(key)
    
    for key in sorted_keys:
        value = data[key]
        if isinstance(value, dict):
            yaml_lines.append(f"{spaces}{key}:")
            yaml_lines.extend(dict_to_yaml_simple(value, indent + 1))
        elif isinstance(value, list):
            yaml_lines.append(f"{spaces}{key}:")
            for item in value:
                if isinstance(item, dict):
                    yaml_lines.append(f"{spaces}  -")
                    # Добавляем элементы объекта с отступом (4 пробела от начала строки с `-`)
                    for item_key, item_value in item.items():
                        if isinstance(item_value, bool):
                            yaml_lines.append(f"{spaces}    {item_key}: {str(item_value).lower()}")
                        elif isinstance(item_value, (int, float)):
                            yaml_lines.append(f"{spaces}    {item_key}: {item_value}")
                        else:
                            # Строковое значение - добавляем кавычки
                            item_str = str(item_value)
                            # Всегда кавычки для строковых значений в объектах массивов
                            yaml_lines.append(f"{spaces}    {item_key}: \"{item_value}\"")
                else:
                    if isinstance(item, (int, float, bool)):
                        yaml_lines.append(f"{spaces}  - {item}")
                    else:
                        item_str = str(item)
                        if ':' in item_str or '@' in item_str or item_str.startswith('-'):
                            yaml_lines.append(f"{spaces}  - \"{item}\"")
                        else:
                            yaml_lines.append(f"{spaces}  - {item}")
        else:
            # Простое значение
            if isinstance(value, bool):
                yaml_lines.append(f"{spaces}{key}: {str(value).lower()}")
            elif isinstance(value, (int, float)):
                yaml_lines.append(f"{spaces}{key}: {value}")
            else:
                # Строка - добавляем кавычки если нужно
                value_str = str(value)
                if ':' in value_str or '@' in value_str or (' ' in value_str and indent == 0):
                    yaml_lines.append(f"{spaces}{key}: \"{value}\"")
                else:
                    yaml_lines.append(f"{spaces}{key}: {value}")
    
    return yaml_lines


@stubby_api.route('/config', methods=['POST'])
def save_config():
    """Сохранить конфигурацию Stubby (только upstream серверы)"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        if not os.path.exists(STUBBY_CONFIG_FILE):
            return jsonify({'error': 'Config file not found'}), 404
        
        # Получаем данные из запроса (только upstream серверы)
        request_data = request.get_json()
        if not request_data or 'upstream_servers' not in request_data:
            return jsonify({'error': 'No upstream servers data provided'}), 400
        
        # Читаем текущую конфигурацию
        with open(STUBBY_CONFIG_FILE, 'r') as f:
            original_yaml = f.read()
        
        # Парсим YAML вручную
        try:
            config_data = yaml_to_dict_simple(original_yaml)
        except Exception as e:
            return jsonify({
                'success': False,
                'error': f'Failed to parse existing config: {str(e)}',
                'message': 'Configuration parsing error'
            }), 400
        
        # Проверяем, что все важные ключи присутствуют
        required_keys = ['resolution_type', 'listen_addresses', 'dns_transport_list', 'upstream_recursive_servers']
        missing_keys = [k for k in required_keys if k not in config_data]
        if missing_keys:
            return jsonify({
                'success': False,
                'error': f'Missing required keys in config: {missing_keys}',
                'message': 'Configuration is incomplete'
            }), 400
        
        # Обновляем только upstream серверы
        upstream_servers = request_data['upstream_servers']
        
        # Убеждаемся, что это массив
        if not isinstance(upstream_servers, list):
            return jsonify({
                'success': False,
                'error': 'upstream_servers must be a list',
                'message': 'Invalid upstream servers format'
            }), 400
        
        # Нормализуем серверы - убеждаемся что tls_port это число
        normalized_servers = []
        for server in upstream_servers:
            if isinstance(server, dict) and 'address_data' in server:
                normalized_server = {
                    'address_data': str(server['address_data']),
                    'tls_auth_name': str(server.get('tls_auth_name', '')),
                    'tls_port': int(server.get('tls_port', 853))
                }
                normalized_servers.append(normalized_server)
        
        if not normalized_servers:
            return jsonify({
                'success': False,
                'error': 'No valid servers provided',
                'message': 'At least one server with address_data is required'
            }), 400
        
        config_data['upstream_recursive_servers'] = normalized_servers
        
        # Конвертируем словарь в YAML
        try:
            yaml_lines = dict_to_yaml_simple(config_data)
            yaml_content = '\n'.join(yaml_lines) + '\n'
        except Exception as e:
            return jsonify({
                'success': False,
                'error': f'Failed to convert to YAML: {str(e)}',
                'message': 'YAML conversion error'
            }), 400
        
        # Создаем резервную копию
        backup_file = STUBBY_CONFIG_FILE + '.backup'
        try:
            with open(backup_file, 'w') as f:
                f.write(original_yaml)
        except:
            pass
        
        # Сохраняем YAML конфигурацию
        try:
            with open(STUBBY_CONFIG_FILE, 'w') as f:
                f.write(yaml_content)
        except Exception as e:
            # Восстанавливаем из backup
            try:
                with open(backup_file, 'r') as f:
                    backup_content = f.read()
                with open(STUBBY_CONFIG_FILE, 'w') as f:
                    f.write(backup_content)
            except:
                pass
            return jsonify({
                'success': False,
                'error': f'Failed to write config file: {str(e)}',
                'message': 'File write error'
            }), 500
        
        # Проверяем валидность конфигурации
        result = subprocess.run(
            ['stubby', '-C', STUBBY_CONFIG_FILE, '-i'],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode == 0:
            return jsonify({
                'success': True,
                'message': 'Configuration saved and validated'
            })
        else:
            # Восстанавливаем из backup при ошибке валидации
            try:
                with open(backup_file, 'r') as f:
                    backup_content = f.read()
                with open(STUBBY_CONFIG_FILE, 'w') as f:
                    f.write(backup_content)
            except:
                pass
            
            error_msg = result.stderr if result.stderr else result.stdout
            return jsonify({
                'success': False,
                'error': error_msg,
                'message': 'Configuration validation failed, backup restored'
            }), 400
            
    except subprocess.TimeoutExpired:
        return jsonify({
            'success': False,
            'error': 'Configuration validation timeout',
            'message': 'Stubby validation took too long'
        }), 500
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e),
            'message': 'Unexpected error'
        }), 500


@stubby_api.route('/config/full', methods=['GET'])
def get_full_config():
    """Получить полный конфиг Stubby для редактора"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        if not os.path.exists(STUBBY_CONFIG_FILE):
            return jsonify({
                'config': [],
                'file_path': STUBBY_CONFIG_FILE
            })

        with open(STUBBY_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()

        return jsonify({
            'config': lines,
            'file_path': STUBBY_CONFIG_FILE
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@stubby_api.route('/config/full', methods=['POST'])
def save_full_config():
    """Сохранить полный конфиг Stubby из редактора (с валидацией)"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        data = request.get_json()
        if not data or 'config' not in data:
            return jsonify({'error': 'No configuration data provided'}), 400

        config_text = data['config']
        if isinstance(config_text, str):
            lines = config_text.split('\n')
        else:
            lines = config_text

        tmp_file = STUBBY_CONFIG_FILE + '.tmp'
        backup_file = STUBBY_CONFIG_FILE + '.backup'

        # Backup
        try:
            if os.path.exists(STUBBY_CONFIG_FILE):
                shutil.copy2(STUBBY_CONFIG_FILE, backup_file)
        except Exception:
            pass

        # Write tmp
        os.makedirs(os.path.dirname(STUBBY_CONFIG_FILE), exist_ok=True)
        with open(tmp_file, 'w', encoding='utf-8') as f:
            for line in lines:
                line_clean = (line if isinstance(line, str) else str(line)).replace('\r', '').rstrip('\n')
                f.write(line_clean + '\n')

        # Validate
        result = subprocess.run(
            ['stubby', '-C', tmp_file, '-i'],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode != 0:
            try:
                os.remove(tmp_file)
            except Exception:
                pass
            return jsonify({
                'success': False,
                'error': result.stderr or result.stdout or 'Configuration validation failed',
                'message': 'Configuration has errors'
            }), 400

        # Replace
        shutil.move(tmp_file, STUBBY_CONFIG_FILE)

        return jsonify({
            'success': True,
            'message': 'Configuration saved and validated'
        })
    except subprocess.TimeoutExpired:
        return jsonify({
            'success': False,
            'error': 'Configuration validation timeout',
            'message': 'Stubby validation took too long'
        }), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500

