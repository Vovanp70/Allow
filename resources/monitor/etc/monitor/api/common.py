# -*- coding: utf-8 -*-

"""
Общие утилиты и хелперы для API
"""

from flask import request, jsonify
import config
import socket
import subprocess
import os
import time

def run_init_status_kv(init_script_path, timeout=3):
    """
    Запускает init-скрипт в режиме: `status --kv` и парсит KEY=VALUE.
    Возвращает dict (может быть пустым при ошибке).
    """
    if not init_script_path:
        return {}
    try:
        # На роутере init-скрипты обычно sh-совместимые.
        res = subprocess.run(
            ['sh', init_script_path, 'status', '--kv'],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        if res.returncode not in (0, 1):
            # status может возвращать 1 для notrunning — это не ошибка.
            return {}
        data = {}
        for raw_line in (res.stdout or '').splitlines():
            line = raw_line.strip()
            if not line or '=' not in line:
                continue
            k, v = line.split('=', 1)
            k = k.strip()
            v = v.strip()
            if k:
                data[k] = v
        return data
    except Exception:
        return {}

def _to_int_or_none(val):
    try:
        if val is None:
            return None
        s = ''.join(ch for ch in str(val) if ch.isdigit())
        return int(s) if s else None
    except Exception:
        return None

def get_ports_from_status_kv(kv, default_port=None):
    """
    Нормализует порты из status --kv (policy 1).
    Возвращает: (config_port, active_port, effective_port, mismatch_bool, status_str)
    """
    status = (kv.get('STATUS') or '').strip() or None
    config_port = _to_int_or_none(kv.get('CONFIG_PORT'))
    active_port = _to_int_or_none(kv.get('ACTIVE_PORT'))
    effective_port = _to_int_or_none(kv.get('EFFECTIVE_PORT'))
    mismatch = (kv.get('MISMATCH') or '').strip().lower() == 'yes'

    if effective_port is None:
        # policy 1 fallback
        if status == 'running' and active_port:
            effective_port = active_port
        elif config_port:
            effective_port = config_port
        else:
            effective_port = default_port

    return config_port, active_port, effective_port, mismatch, status

def check_auth():
    """Проверка аутентификации через токен"""
    token = request.headers.get('X-Auth-Token')
    if token != config.AUTH_TOKEN:
        return False
    return True

def handle_api_error(e, status_code=500, message="Internal server error"):
    """Единая функция для обработки ошибок API"""
    print(f"API Error: {e}")  # Логируем ошибку для отладки
    return jsonify({'error': str(e), 'message': message}), status_code

def check_port(port, host='127.0.0.1', protocol='tcp', timeout=1):
    """Проверка открытости порта"""
    try:
        if protocol == 'udp':
            # Для UDP проверяем через netstat
            result = subprocess.run(
                ['netstat', '-ulnp'],
                capture_output=True,
                text=True,
                timeout=timeout
            )
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if f':{port} ' in line and 'LISTEN' in line:  # 'LISTEN' для UDP может быть не всегда, но для dnsmasq часто есть
                        return True
            return False
        else:
            # TCP проверка
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            result = sock.connect_ex((host, port))
            sock.close()
            return result == 0
    except Exception as e:
        print(f"Error checking port {port} ({protocol}): {e}")
        return False

def check_process_running(process_name, pid_file=None, cmdline_keyword=None):
    """
    Проверка, запущен ли процесс.
    Использует PID файл, если указан, затем ps w.
    cmdline_keyword используется для более точной идентификации процесса по его командной строке.
    """
    is_running = False
    pid = None

    # 1. Проверка через PID файл
    if pid_file and os.path.exists(pid_file):
        try:
            with open(pid_file, 'r') as f:
                pid = f.read().strip()
                if pid and os.path.exists(f'/proc/{pid}'):
                    # Дополнительная проверка по cmdline, если указан keyword
                    if cmdline_keyword:
                        try:
                            with open(f'/proc/{pid}/cmdline', 'r') as cmd:
                                cmdline = cmd.read()
                                if cmdline_keyword in cmdline:
                                    is_running = True
                        except:
                            pass
                    else:
                        is_running = True
        except Exception as e:
            print(f"Error reading PID file {pid_file}: {e}")
            pass  # Продолжаем проверку через ps

    # 2. Проверка через ps w, если не найдено через PID файл или нужна дополнительная проверка
    if not is_running:
        try:
            result_list = subprocess.run(
                ['ps', 'w'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    # Ищем процесс по имени и ключевому слову в командной строке
                    if process_name in line and 'grep' not in line:
                        if cmdline_keyword:
                            if cmdline_keyword in line:
                                is_running = True
                                break
                        else:
                            is_running = True
                            break
        except Exception as e:
            print(f"Error checking process with ps w for {process_name}: {e}")
            pass

    return is_running, pid

def require_auth(f):
    """
    Декоратор для автоматической проверки аутентификации
    
    Usage:
        @require_auth
        def my_endpoint():
            return jsonify({'success': True})
    """
    def wrapper(*args, **kwargs):
        if not check_auth():
            return jsonify({'error': 'Unauthorized'}), 401
        return f(*args, **kwargs)
    wrapper.__name__ = f.__name__
    return wrapper

def success_response(data=None, message=None):
    """Стандартизированный успешный ответ API"""
    response = {'success': True}
    if data is not None:
        response.update(data)
    if message:
        response['message'] = message
    return jsonify(response)




