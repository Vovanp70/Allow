# -*- coding: utf-8 -*-

"""
API для управления Stubby Family
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

stubby_family_api = Blueprint('stubby_family_api', __name__)

# Импортируем пути из централизованного модуля
import paths
from api.common import run_init_status_kv, get_ports_from_status_kv

STUBBY_INIT_SCRIPT = paths.STUBBY_FAMILY_INIT_SCRIPT
STUBBY_CONFIG_FILE = paths.STUBBY_FAMILY_CONFIG_FILE
STUBBY_PID_FILE = paths.STUBBY_FAMILY_PID_FILE


def check_auth():
    """Проверка аутентификации через токен"""
    token = request.headers.get('X-Auth-Token')
    return token == config.AUTH_TOKEN


def check_port(port):
    """Проверка открытости TCP порта"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(1)
        result = sock.connect_ex(('127.0.0.1', port))
        sock.close()
        return result == 0
    except Exception:
        return False


def get_stubby_family_ports():
    """
    Возвращает порты stubby-family по policy 1 (active если running, иначе config).
    """
    kv = run_init_status_kv(STUBBY_INIT_SCRIPT)
    config_port, active_port, effective_port, mismatch, status = get_ports_from_status_kv(
        kv,
        default_port=41501
    )
    return {
        'status_kv': kv,
        'status': status,  # running|notrunning|None
        'config_port': config_port,
        'active_port': active_port,
        'effective_port': effective_port,
        'mismatch': mismatch,
    }


@stubby_family_api.route('/status', methods=['GET'])
def get_status():
    """Получить статус Stubby Family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        is_running = False
        pid = None

        # PID-file check
        if os.path.exists(STUBBY_PID_FILE):
            try:
                with open(STUBBY_PID_FILE, 'r') as f:
                    pid = f.read().strip()
                if pid and os.path.exists(f'/proc/{pid}'):
                    try:
                        with open(f'/proc/{pid}/cmdline', 'r') as cmd:
                            cmdline = cmd.read()
                            if 'stubby' in cmdline and 'stubby-family.yml' in cmdline:
                                is_running = True
                    except Exception:
                        pass
            except Exception:
                pass

        # Fallback: ps w
        if not is_running:
            result_list = subprocess.run(['ps', 'w'], capture_output=True, text=True)
            if result_list.returncode == 0:
                for line in result_list.stdout.split('\n'):
                    if 'stubby' in line and 'stubby-family.yml' in line and 'grep' not in line:
                        parts = line.split()
                        if parts:
                            pid = parts[0]
                            if os.path.exists(f'/proc/{pid}'):
                                is_running = True
                                break

        ports = get_stubby_family_ports()
        effective_port = ports.get('effective_port')

        # Если init status доступен — доверяем ему по running/pid
        if ports.get('status') in ('running', 'notrunning'):
            is_running = (ports.get('status') == 'running')
            kv_pid = ports.get('status_kv', {}).get('PID')
            pid = kv_pid or pid

        port_open = check_port(int(effective_port)) if effective_port else False

        return jsonify({
            'running': is_running,
            'port_open': port_open,
            'pid': pid,
            # backward-compat field
            'port': effective_port,
            'config_port': ports.get('config_port'),
            'active_port': ports.get('active_port'),
            'effective_port': effective_port,
            'mismatch': ports.get('mismatch'),
            'status': 'running' if is_running else 'stopped'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@stubby_family_api.route('/start', methods=['POST'])
def start():
    """Запустить Stubby Family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
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
                'message': 'Stubby Family configuration is invalid'
            }), 400

        result = subprocess.run([STUBBY_INIT_SCRIPT, 'start'], capture_output=True, text=True)
        if result.returncode != 0:
            return jsonify({
                'success': False,
                'error': result.stderr or result.stdout or 'Failed to start'
            }), 500

        return jsonify({'success': True, 'message': 'Stubby Family started'})
    except subprocess.TimeoutExpired:
        return jsonify({'success': False, 'error': 'Start timeout'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@stubby_family_api.route('/stop', methods=['POST'])
def stop():
    """Остановить Stubby Family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        subprocess.run([STUBBY_INIT_SCRIPT, 'stop'], check=False, capture_output=True, text=True)
        return jsonify({'success': True, 'message': 'Stubby Family stopped'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@stubby_family_api.route('/restart', methods=['POST'])
def restart():
    """Перезапустить Stubby Family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        subprocess.run([STUBBY_INIT_SCRIPT, 'restart'], check=False, capture_output=True, text=True)
        return jsonify({'success': True, 'message': 'Stubby Family restarted'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


@stubby_family_api.route('/config/full', methods=['GET'])
def get_full_config():
    """Получить полный конфиг Stubby Family для редактора"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        if not os.path.exists(STUBBY_CONFIG_FILE):
            return jsonify({'config': [], 'file_path': STUBBY_CONFIG_FILE})

        with open(STUBBY_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()

        return jsonify({'config': lines, 'file_path': STUBBY_CONFIG_FILE})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@stubby_family_api.route('/config/full', methods=['POST'])
def save_full_config():
    """Сохранить полный конфиг Stubby Family (с валидацией)"""
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

        try:
            if os.path.exists(STUBBY_CONFIG_FILE):
                shutil.copy2(STUBBY_CONFIG_FILE, backup_file)
        except Exception:
            pass

        os.makedirs(os.path.dirname(STUBBY_CONFIG_FILE), exist_ok=True)
        with open(tmp_file, 'w', encoding='utf-8') as f:
            for line in lines:
                line_clean = (line if isinstance(line, str) else str(line)).replace('\r', '').rstrip('\n')
                f.write(line_clean + '\n')

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

        shutil.move(tmp_file, STUBBY_CONFIG_FILE)
        return jsonify({'success': True, 'message': 'Configuration saved and validated'})
    except subprocess.TimeoutExpired:
        return jsonify({'success': False, 'error': 'Configuration validation timeout'}), 500
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

