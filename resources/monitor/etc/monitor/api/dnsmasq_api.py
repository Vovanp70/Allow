# -*- coding: utf-8 -*-

"""
API для управления DNSMASQ full
"""

from flask import Blueprint, jsonify, request
import subprocess
import os
import socket
import sys

# Добавляем родительскую директорию в путь для импорта
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config
from api.common import check_auth, check_port, check_process_running, handle_api_error, run_init_status_kv, get_ports_from_status_kv

dnsmasq_api = Blueprint('dnsmasq_api', __name__)

# Импортируем пути из централизованного модуля
import paths

# Используем пути из paths.py
DNSMASQ_INIT_SCRIPT = paths.DNSMASQ_INIT_SCRIPT
DNSMASQ_CONFIG_FILE = paths.DNSMASQ_CONFIG_FILE
DNSMASQ_CONFIG_FILE_ALT = paths.DNSMASQ_CONFIG_FILE_ALT
DNSMASQ_PID_FILE = paths.DNSMASQ_PID_FILE
DNSMASQ_LOG_FILE = paths.DNSMASQ_LOG_FILE

def get_dnsmasq_ports():
    """
    Возвращает порты dnsmasq по policy 1 (active если running, иначе config).
    """
    kv = run_init_status_kv(DNSMASQ_INIT_SCRIPT)
    config_port, active_port, effective_port, mismatch, status = get_ports_from_status_kv(
        kv,
        default_port=5300
    )
    return {
        'status_kv': kv,
        'status': status,
        'config_port': config_port,
        'active_port': active_port,
        'effective_port': effective_port,
        'mismatch': mismatch,
    }

def get_dnsmasq_config_file():
    """Получить путь к файлу конфигурации DNSMASQ (проверяем оба варианта)"""
    return paths.get_dnsmasq_config_file()


def get_dnsmasq_port():
    """Определить эффективный порт DNSMASQ (policy 1)"""
    ports = get_dnsmasq_ports()
    if ports.get('effective_port'):
        return int(ports['effective_port'])

    # Сначала пробуем из конфига (проверяем оба пути)
    config_file = get_dnsmasq_config_file()
    if os.path.exists(config_file):
        try:
            with open(config_file, 'r') as f:
                for line in f:
                    line_stripped = line.strip()
                    if line_stripped.startswith('port=') and not line_stripped.startswith('#'):
                        try:
                            port = int(line_stripped.split('=')[1].strip())
                            return port
                        except:
                            pass
        except:
            pass
    
    # Если не нашли в конфиге, проверяем через netstat
    try:
        result = subprocess.run(
            ['netstat', '-ulnp'],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            for line in result.stdout.split('\n'):
                if 'dnsmasq' in line and 'udp' in line.lower():
                    # Парсим порт из строки netstat
                    parts = line.split()
                    for part in parts:
                        if ':' in part and part.split(':')[0] in ['127.0.0.1', '0.0.0.0', '*']:
                            try:
                                port = int(part.split(':')[1])
                                return port
                            except:
                                pass
    except:
        pass
    
    # По умолчанию возвращаем 5300 (dnsmasq-full)
    return 5300


def get_dnsmasq_config_file():
    """Получить путь к файлу конфигурации DNSMASQ (проверяем оба варианта)"""
    if os.path.exists(DNSMASQ_CONFIG_FILE):
        return DNSMASQ_CONFIG_FILE
    elif os.path.exists(DNSMASQ_CONFIG_FILE_ALT):
        return DNSMASQ_CONFIG_FILE_ALT
    else:
        # Если ни один не существует, возвращаем основной путь для создания
        return DNSMASQ_CONFIG_FILE


@dnsmasq_api.route('/status', methods=['GET'])
def get_status():
    """Получить статус DNSMASQ full"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        is_running = False
        pid = None
        
        # Проверка через PID файл
        if os.path.exists(DNSMASQ_PID_FILE):
            try:
                with open(DNSMASQ_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        # Проверяем что это действительно dnsmasq с нашим конфигом
                        try:
                            with open(f'/proc/{pid}/cmdline', 'r') as cmd:
                                cmdline = cmd.read()
                                if 'dnsmasq' in cmdline and 'dnsmasq-full.conf' in cmdline:
                                    is_running = True
                        except:
                            pass
            except:
                pass
        
        # Если PID файл не помог, проверяем через ps (любой dnsmasq процесс)
        if not is_running:
            result_list = subprocess.run(
                ['ps', 'w'],
                capture_output=True,
                text=True
            )
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'dnsmasq' in line and 'grep' not in line:
                        parts = line.split()
                        if len(parts) > 0:
                            try:
                                pid = parts[0]
                                if os.path.exists(f'/proc/{pid}'):
                                    # Проверяем что это не системный dnsmasq
                                    try:
                                        with open(f'/proc/{pid}/cmdline', 'r') as cmd:
                                            cmdline = cmd.read()
                                            # Игнорируем системный dnsmasq (обычно без конфига или с системным)
                                            if 'dnsmasq-full.conf' in cmdline or '/opt' in cmdline:
                                                is_running = True
                                                pid = parts[0]
                                                break
                                    except:
                                        # Если не можем прочитать cmdline, но процесс есть - считаем что запущен
                                        is_running = True
                                        pid = parts[0]
                                        break
                            except:
                                pass
        
        # Определяем реальный порт
        ports = get_dnsmasq_ports()
        actual_port = int(ports.get('effective_port') or get_dnsmasq_port())
        
        # Проверка порта (UDP для DNS)
        port_open = check_port(actual_port, 'udp')
        
        # Проверка логирования (смотрим в конфиг)
        logging_enabled = False
        config_file = get_dnsmasq_config_file()
        if os.path.exists(config_file):
            try:
                with open(config_file, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if line.startswith('log-queries') and not line.startswith('#'):
                            logging_enabled = True
                            break
            except:
                pass
        
        return jsonify({
            'running': is_running,
            'port_open': port_open,
            'pid': pid,
            # backward-compat field
            'port': actual_port,
            'config_port': ports.get('config_port'),
            'active_port': ports.get('active_port'),
            'effective_port': ports.get('effective_port'),
            'mismatch': ports.get('mismatch'),
            'logging_enabled': logging_enabled,
            'log_file': DNSMASQ_LOG_FILE,
            'status': 'running' if is_running else 'stopped'
        })
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/start', methods=['POST'])
def start():
    """Запустить DNSMASQ full"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Проверяем что не запущен
        is_running_check = False
        if os.path.exists(DNSMASQ_PID_FILE):
            try:
                with open(DNSMASQ_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        is_running_check = True
            except:
                pass
        
        if not is_running_check:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'dnsmasq' in line and 'grep' not in line:
                        # Проверяем что это наш dnsmasq (с конфигом или из /opt)
                        if 'dnsmasq-full.conf' in line or '/opt' in line:
                            is_running_check = True
                            break
        
        if is_running_check:
            return jsonify({
                'success': False,
                'message': 'DNSMASQ full already running'
            }), 400
        
        # Запуск
        result = subprocess.run(
            [DNSMASQ_INIT_SCRIPT, 'start'],
            capture_output=True,
            text=True
        )
        
        import time
        time.sleep(2)
        
        # Проверяем что запустился
        is_running = False
        pid = None
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
                            parts = line.split()
                            if len(parts) > 0:
                                try:
                                    pid = parts[0]
                                    if os.path.exists(f'/proc/{pid}'):
                                        is_running = True
                                        break
                                except:
                                    pass
        
        ports = get_dnsmasq_ports()
        actual_port = int(ports.get('effective_port') or get_dnsmasq_port())
        port_open = check_port(actual_port, 'udp') if is_running else False
        
        if result.returncode == 0 and is_running:
            return jsonify({
                'success': True,
                'message': 'DNSMASQ full started successfully',
                'is_running': is_running,
                'port_open': port_open,
                'pid': pid
            })
        else:
            return jsonify({
                'success': False,
                'error': result.stderr or 'Failed to start',
                'is_running': is_running,
                'port_open': port_open
            }), 500
            
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/stop', methods=['POST'])
def stop():
    """Остановить DNSMASQ full"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Проверяем что запущен
        was_running = False
        if os.path.exists(DNSMASQ_PID_FILE):
            try:
                with open(DNSMASQ_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        was_running = True
            except:
                pass
        
        if not was_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'dnsmasq' in line and 'dnsmasq-full.conf' in line and 'grep' not in line:
                        was_running = True
                        break
        
        if not was_running:
            return jsonify({
                'success': False,
                'message': 'DNSMASQ full is not running'
            }), 400
        
        # Остановка
        subprocess.run([DNSMASQ_INIT_SCRIPT, 'stop'], check=False, capture_output=True)
        
        import time
        time.sleep(2)
        
        # Проверяем что остановился
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
        
        # Если все еще запущен, убиваем принудительно
        if is_running:
            result_pid = subprocess.run(['pgrep', '-f', 'dnsmasq.*dnsmasq-full.conf'], capture_output=True, text=True)
            if result_pid.returncode == 0:
                pids = result_pid.stdout.strip().split('\n')
                for pid in pids:
                    if pid.strip():
                        try:
                            subprocess.run(['kill', '-9', pid.strip()], check=False, capture_output=True)
                        except:
                            pass
            
            time.sleep(1)
            result_final = subprocess.run(['pgrep', '-f', 'dnsmasq.*dnsmasq-full.conf'], capture_output=True)
            is_running = result_final.returncode == 0
        
        if not is_running:
            return jsonify({
                'success': True,
                'message': 'DNSMASQ full stopped successfully',
                'was_running': was_running,
                'is_running': is_running
            })
        else:
            return jsonify({
                'success': False,
                'error': 'Failed to stop DNSMASQ full process',
                'was_running': was_running,
                'is_running': is_running
            }), 500
            
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/restart', methods=['POST'])
def restart():
    """Перезапустить DNSMASQ full"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Получаем статус до перезапуска
        was_running = False
        if os.path.exists(DNSMASQ_PID_FILE):
            try:
                with open(DNSMASQ_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                    if pid and os.path.exists(f'/proc/{pid}'):
                        was_running = True
            except:
                pass
        
        if not was_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'dnsmasq' in line and 'grep' not in line:
                        if 'dnsmasq-full.conf' in line or '/opt' in line:
                            was_running = True
                            break
        
        # Остановка
        subprocess.run([DNSMASQ_INIT_SCRIPT, 'stop'], check=False)
        
        import time
        time.sleep(2)
        
        # Запуск
        result = subprocess.run(
            [DNSMASQ_INIT_SCRIPT, 'start'],
            capture_output=True,
            text=True
        )
        
        time.sleep(2)
        
        # Проверяем что запустился
        is_running = False
        pid = None
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
                            parts = line.split()
                            if len(parts) > 0:
                                try:
                                    pid = parts[0]
                                    if os.path.exists(f'/proc/{pid}'):
                                        is_running = True
                                        break
                                except:
                                    pass
        
        ports = get_dnsmasq_ports()
        actual_port = int(ports.get('effective_port') or get_dnsmasq_port())
        port_open = check_port(actual_port, 'udp') if is_running else False
        
        if result.returncode == 0 and is_running:
            return jsonify({
                'success': True, 
                'message': 'DNSMASQ full restarted successfully',
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
        return handle_api_error(e)


@dnsmasq_api.route('/config', methods=['GET'])
def get_config():
    """Получить текущую конфигурацию DNSMASQ full"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Определяем правильный путь к конфигурации
        config_file = get_dnsmasq_config_file()
        
        # Если файл не существует, возвращаем пустую конфигурацию
        if not os.path.exists(config_file):
            return jsonify({
                'editable': {
                    'cache-size': '10000',
                    'min-cache-ttl': '300',
                    'max-cache-ttl': '3600'
                },
                'full_config': [],
                'config_file': config_file
            })
        
        # Читаем конфигурацию (INI-подобный формат)
        config_data = {}
        full_config = []
        
        with open(config_file, 'r') as f:
            for line in f:
                full_config.append(line.rstrip('\n'))
                line_stripped = line.strip()
                # Пропускаем комментарии и пустые строки
                if not line_stripped or line_stripped.startswith('#'):
                    continue
                
                # Парсим параметры
                if '=' in line_stripped:
                    parts = line_stripped.split('=', 1)
                    if len(parts) == 2:
                        key = parts[0].strip()
                        value = parts[1].strip()
                        config_data[key] = value
        
        # Проверяем, включено ли логирование
        logging_enabled = False
        for line in full_config:
            line_stripped = line.strip()
            if line_stripped.startswith('log-queries') and not line_stripped.startswith('#'):
                logging_enabled = True
                break
        
        # Возвращаем только редактируемые параметры и полную конфигурацию для чтения
        editable = {
            'cache-size': config_data.get('cache-size', '10000'),
            'max-cache-ttl': config_data.get('max-cache-ttl', '3600'),
            'min-cache-ttl': config_data.get('min-cache-ttl', '300'),
            'logging': logging_enabled
        }
        
        return jsonify({
            'editable': editable,
            'full_config': full_config,
            'logging_enabled': logging_enabled
        })
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/config', methods=['POST'])
def save_config():
    """Сохранить конфигурацию DNSMASQ full (только редактируемые параметры или полная конфигурация)"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Определяем правильный путь к конфигурации
        config_file = get_dnsmasq_config_file()
        
        # Если файл не существует, создаем директорию и файл
        if not os.path.exists(config_file):
            config_dir = os.path.dirname(config_file)
            if not os.path.exists(config_dir):
                os.makedirs(config_dir, exist_ok=True)
            # Создаем файл с базовой конфигурацией
            with open(config_file, 'w') as f:
                f.write('# DNSMASQ full configuration\n')
                f.write('port=5353\n')
                f.write('listen-address=127.0.0.1\n')
                f.write('cache-size=10000\n')
                f.write('min-cache-ttl=300\n')
                f.write('max-cache-ttl=3600\n')
        
        # Получаем данные из запроса
        request_data = request.get_json()
        if not request_data:
            return jsonify({'error': 'No configuration data provided'}), 400
        
        # Сохраняем старое состояние логирования для сравнения
        old_logging_enabled = False
        if os.path.exists(config_file):
            try:
                with open(config_file, 'r') as f:
                    for line in f:
                        line_stripped = line.strip()
                        if line_stripped.startswith('log-queries') and not line_stripped.startswith('#'):
                            old_logging_enabled = True
                            break
            except:
                pass
        
        # Инициализируем переменные для логирования
        logging_enabled = None
        new_logging_enabled = False
        
        # Проверяем, это полная конфигурация или только редактируемые параметры
        if 'full_config' in request_data:
            # Полная конфигурация - сохраняем как есть
            full_config = request_data['full_config']
            if isinstance(full_config, list):
                config_content = '\n'.join(full_config) + '\n'
            else:
                config_content = full_config
                if not config_content.endswith('\n'):
                    config_content += '\n'
            
            with open(config_file, 'w') as f:
                f.write(config_content)
            
            # Определяем новое состояние логирования из полной конфигурации
            for line in full_config if isinstance(full_config, list) else full_config.split('\n'):
                line_stripped = line.strip()
                if line_stripped.startswith('log-queries') and not line_stripped.startswith('#'):
                    new_logging_enabled = True
                    break
        else:
            # Только редактируемые параметры
            new_config = request_data
            allowed_keys = {'cache-size', 'max-cache-ttl', 'min-cache-ttl', 'logging'}
            filtered_config = {k: v for k, v in new_config.items() if k in allowed_keys}
            
            # Обрабатываем логирование отдельно
            logging_enabled = filtered_config.pop('logging', None)
            if logging_enabled is not None:
                logging_enabled = bool(logging_enabled)
            
            if not filtered_config and logging_enabled is None:
                return jsonify({'error': 'No editable parameters provided'}), 400
            
            # Читаем текущую конфигурацию (сохраняем комментарии и структуру)
            lines = []
            with open(config_file, 'r') as f:
                for line in f:
                    lines.append(line)
            
            # Обновляем только разрешенные параметры
            updated_lines = []
            updated_keys = set()
            log_queries_found = False
            log_facility_found = False
            
            for line in lines:
                line_stripped = line.strip()
                
                # Обрабатываем логирование
                if line_stripped.startswith('log-queries'):
                    log_queries_found = True
                    if logging_enabled is not None:
                        if logging_enabled:
                            updated_lines.append('log-queries\n')
                        else:
                            updated_lines.append('# log-queries\n')
                    else:
                        updated_lines.append(line)
                    continue
                
                if line_stripped.startswith('log-facility'):
                    log_facility_found = True
                    if logging_enabled is not None:
                        if logging_enabled:
                            updated_lines.append(f'log-facility={DNSMASQ_LOG_FILE}\n')
                        else:
                            updated_lines.append(f'# log-facility={DNSMASQ_LOG_FILE}\n')
                    else:
                        updated_lines.append(line)
                    continue
                
                if line_stripped and not line_stripped.startswith('#'):
                    if '=' in line_stripped:
                        parts = line_stripped.split('=', 1)
                        if len(parts) == 2:
                            key = parts[0].strip()
                            if key in filtered_config:
                                # Заменяем значение
                                updated_lines.append(f"{key}={filtered_config[key]}\n")
                                updated_keys.add(key)
                                continue
                
                updated_lines.append(line)
            
            # Если логирование не найдено, но нужно включить/выключить
            if logging_enabled is not None:
                if not log_queries_found and logging_enabled:
                    updated_lines.append('log-queries\n')
                if not log_facility_found and logging_enabled:
                    updated_lines.append(f'log-facility={DNSMASQ_LOG_FILE}\n')
            
            # Сохраняем конфигурацию
            with open(config_file, 'w') as f:
                f.writelines(updated_lines)
            
            # Определяем новое состояние логирования
            if logging_enabled is not None:
                new_logging_enabled = logging_enabled
            else:
                # Проверяем текущее состояние
                for line in updated_lines:
                    line_stripped = line.strip()
                    if line_stripped.startswith('log-queries') and not line_stripped.startswith('#'):
                        new_logging_enabled = True
                        break
        
        # Проверяем синтаксис (dnsmasq --test)
        result = subprocess.run(
            ['dnsmasq', '--test', '-C', config_file],
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            return jsonify({
                'success': False,
                'error': result.stderr,
                'message': 'Configuration has errors'
            }), 400
        
        # Проверяем, изменилось ли логирование
        logging_changed = (old_logging_enabled != new_logging_enabled)
        
        # Если логирование изменилось, перезапускаем dnsmasq
        if logging_changed:
            try:
                # Проверяем, запущен ли dnsmasq
                is_running = False
                if os.path.exists(DNSMASQ_PID_FILE):
                    try:
                        with open(DNSMASQ_PID_FILE, 'r') as f:
                            pid = f.read().strip()
                            if pid and os.path.exists(f'/proc/{pid}'):
                                is_running = True
                    except:
                        pass
                
                if is_running:
                    subprocess.run([DNSMASQ_INIT_SCRIPT, 'restart'], check=False, capture_output=True)
                    return jsonify({
                        'success': True,
                        'message': 'Configuration saved and dnsmasq restarted',
                        'restarted': True
                    })
            except:
                # Если не удалось перезапустить, продолжаем без ошибки
                pass
        
        return jsonify({
            'success': True,
            'message': 'Configuration saved and validated'
        })
            
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/logs', methods=['GET'])
def get_logs():
    """Получить логи DNSMASQ full"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        lines = request.args.get('lines', default=100, type=int)
        
        # Проверяем, включено ли логирование
        logging_enabled = False
        config_file = get_dnsmasq_config_file()
        if os.path.exists(config_file):
            try:
                with open(config_file, 'r') as f:
                    for line in f:
                        line_stripped = line.strip()
                        if line_stripped.startswith('log-queries') and not line_stripped.startswith('#'):
                            logging_enabled = True
                            break
            except:
                pass
        
        # Читаем логи, даже если логирование выключено (показываем старые логи)
        if not os.path.exists(DNSMASQ_LOG_FILE):
            return jsonify({
                'logs': [],
                'message': 'Файл логов не существует',
                'logging_enabled': logging_enabled,
                'warning': 'Логирование выключено. Включите логирование в настройках конфигурации для записи новых логов.' if not logging_enabled else None
            })
        
        # Читаем последние N строк
        result = subprocess.run(
            ['tail', '-n', str(lines), DNSMASQ_LOG_FILE],
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0:
            log_lines = result.stdout.split('\n')
            # Фильтруем пустые строки
            log_lines = [line for line in log_lines if line.strip()]
            
            warning = None
            if not logging_enabled:
                warning = 'Логирование выключено. Показаны старые логи. Включите логирование в настройках конфигурации для записи новых логов.'
            
            return jsonify({
                'logs': log_lines,
                'total_lines': len(log_lines),
                'logging_enabled': logging_enabled,
                'warning': warning
            })
        else:
            return jsonify({
                'logs': [],
                'error': 'Failed to read log file',
                'logging_enabled': True
            }), 500
            
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/logging', methods=['POST'])
def toggle_logging():
    """Включить/выключить логирование DNSMASQ full"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        data = request.get_json()
        if not data or 'enabled' not in data:
            return jsonify({'error': 'No enabled parameter provided'}), 400
        
        enabled = data['enabled']
        
        # Определяем правильный путь к конфигурации
        config_file = get_dnsmasq_config_file()
        
        # Если файл не существует, создаем его
        if not os.path.exists(config_file):
            config_dir = os.path.dirname(config_file)
            if not os.path.exists(config_dir):
                os.makedirs(config_dir, exist_ok=True)
            with open(config_file, 'w') as f:
                f.write('# DNSMASQ full configuration\n')
        
        # Читаем текущую конфигурацию
        lines = []
        with open(config_file, 'r') as f:
            lines = f.readlines()
        
        # Обновляем параметры логирования
        updated_lines = []
        log_queries_found = False
        log_facility_found = False
        
        for line in lines:
            line_stripped = line.strip()
            
            # Пропускаем комментарии и пустые строки
            if not line_stripped or line_stripped.startswith('#'):
                updated_lines.append(line)
                continue
            
            # Обрабатываем log-queries
            if line_stripped.startswith('log-queries'):
                log_queries_found = True
                if enabled:
                    # Убираем комментарий, если есть
                    updated_lines.append('log-queries\n')
                else:
                    # Комментируем
                    updated_lines.append('# log-queries\n')
                continue
            
            # Обрабатываем log-facility
            if line_stripped.startswith('log-facility'):
                log_facility_found = True
                if enabled:
                    updated_lines.append(f'log-facility={DNSMASQ_LOG_FILE}\n')
                else:
                    updated_lines.append(f'# log-facility={DNSMASQ_LOG_FILE}\n')
                continue
            
            updated_lines.append(line)
        
        # Если параметры не найдены, добавляем их
        if enabled:
            if not log_queries_found:
                updated_lines.append('log-queries\n')
            if not log_facility_found:
                updated_lines.append(f'log-facility={DNSMASQ_LOG_FILE}\n')
        
        # Сохраняем конфигурацию
        with open(config_file, 'w') as f:
            f.writelines(updated_lines)
        
        # Проверяем синтаксис
        result = subprocess.run(
            ['dnsmasq', '--test', '-C', config_file],
            capture_output=True,
            text=True
        )
        
        if result.returncode == 0:
            # Если DNSMASQ запущен, перезапускаем его
            if os.path.exists(DNSMASQ_PID_FILE):
                try:
                    with open(DNSMASQ_PID_FILE, 'r') as f:
                        pid = f.read().strip()
                        if pid and os.path.exists(f'/proc/{pid}'):
                            # Перезапускаем
                            subprocess.run([DNSMASQ_INIT_SCRIPT, 'restart'], check=False, capture_output=True)
                except:
                    pass
            
            return jsonify({
                'success': True,
                'message': f'Logging {"enabled" if enabled else "disabled"}',
                'enabled': enabled
            })
        else:
            return jsonify({
                'success': False,
                'error': result.stderr,
                'message': 'Configuration has errors'
            }), 400
            
    except Exception as e:
        return handle_api_error(e)

@dnsmasq_api.route('/logs/size', methods=['GET'])
def get_logs_size():
    """Получить размер файла логов DNSMASQ"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        if not os.path.exists(DNSMASQ_LOG_FILE):
            return jsonify({'size': 0, 'size_formatted': '0 B'})
        
        size = os.path.getsize(DNSMASQ_LOG_FILE)
        
        # Форматируем размер
        if size < 1024:
            size_formatted = f'{size} B'
        elif size < 1024 * 1024:
            size_formatted = f'{size / 1024:.2f} KB'
        else:
            size_formatted = f'{size / (1024 * 1024):.2f} MB'
        
        return jsonify({
            'size': size,
            'size_formatted': size_formatted
        })
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/logs/clear', methods=['POST'])
def clear_logs():
    """Очистить логи DNSMASQ"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        if not os.path.exists(DNSMASQ_LOG_FILE):
            return jsonify({
                'success': True,
                'message': 'Log file does not exist'
            })
        
        # Очищаем файл
        with open(DNSMASQ_LOG_FILE, 'w') as f:
            f.write('')
        
        return jsonify({
            'success': True,
            'message': 'Logs cleared successfully'
        })
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/config/full', methods=['GET'])
def get_full_config():
    """Получить полный конфигурационный файл DNSMASQ для редактирования"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        config_file = get_dnsmasq_config_file()
        if not os.path.exists(config_file):
            # Если файл не существует, возвращаем пустой конфиг с путем
            return jsonify({
                'config': [],
                'file_path': config_file
            })
        
        with open(config_file, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        
        return jsonify({
            'config': lines,
            'file_path': config_file
        })
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_api.route('/config/full', methods=['POST'])
def save_full_config():
    """Сохранить полный конфигурационный файл DNSMASQ"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        config_file = get_dnsmasq_config_file()
        data = request.get_json()
        if not data or 'config' not in data:
            return jsonify({'error': 'No configuration data provided'}), 400

        config_text = data['config']

        # Если пришла строка, разбиваем на строки
        if isinstance(config_text, str):
            lines = config_text.split('\n')
        else:
            lines = config_text

        # Пишем в промежуточный файл для проверки синтаксиса
        import shutil
        
        tmp_config_file = config_file + '.tmp'
        backup_file = config_file + '.backup'

        # Создаём резервную копию
        try:
            if os.path.exists(config_file):
                shutil.copy2(config_file, backup_file)
        except Exception as e:
            pass

        # Сохраняем во временный файл
        with open(tmp_config_file, 'w', encoding='utf-8') as f:
            for line in lines:
                # Убираем лишние символы в конце строки
                line_clean = line.replace('\r', '').rstrip('\n')
                f.write(line_clean + '\n')

        # Проверяем синтаксис
        result = subprocess.run(
            ['dnsmasq', '--test', '-C', tmp_config_file],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            # Удаляем временный файл
            try:
                os.remove(tmp_config_file)
            except:
                pass
            return jsonify({
                'success': False,
                'error': result.stderr,
                'message': 'Configuration has errors'
            }), 400

        # Если синтаксис правильный, заменяем оригинальный файл
        shutil.move(tmp_config_file, config_file)

        # Сохраняем старое состояние логирования
        old_logging_enabled = False
        try:
            with open(config_file, 'r') as f:
                for line in f:
                    line_stripped = line.strip()
                    if line_stripped.startswith('log-queries') and not line_stripped.startswith('#'):
                        old_logging_enabled = True
                        break
        except:
            pass

        # Определяем новое состояние логирования
        new_logging_enabled = False
        for line in lines:
            line_stripped = line.strip()
            if line_stripped.startswith('log-queries') and not line_stripped.startswith('#'):
                new_logging_enabled = True
                break

        # Если логирование изменилось, перезапускаем
        if old_logging_enabled != new_logging_enabled:
            try:
                is_running = False
                if os.path.exists(DNSMASQ_PID_FILE):
                    try:
                        with open(DNSMASQ_PID_FILE, 'r') as f:
                            pid = f.read().strip()
                            if pid and os.path.exists(f'/proc/{pid}'):
                                is_running = True
                    except:
                        pass
                
                if is_running:
                    subprocess.run([DNSMASQ_INIT_SCRIPT, 'restart'], check=False, capture_output=True)
                    return jsonify({
                        'success': True,
                        'message': 'Configuration saved and dnsmasq restarted',
                        'restarted': True
                    })
            except:
                pass

        return jsonify({
            'success': True,
            'message': 'Configuration saved and validated'
        })
    except Exception as e:
        return handle_api_error(e)

