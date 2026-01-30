# -*- coding: utf-8 -*-

"""
API для управления DNSMASQ family
"""

from flask import Blueprint, jsonify, request
import subprocess
import os
import sys
import shutil

# Добавляем родительскую директорию в путь для импорта
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import config

from api.common import (
    check_auth,
    check_port,
    check_process_running,
    handle_api_error,
    run_init_status_kv,
    get_ports_from_status_kv,
)

dnsmasq_family_api = Blueprint('dnsmasq_family_api', __name__)

import paths

DNSMASQ_INIT_SCRIPT = paths.DNSMASQ_FAMILY_INIT_SCRIPT
DNSMASQ_CONFIG_FILE = paths.DNSMASQ_FAMILY_CONFIG_FILE
DNSMASQ_PID_FILE = paths.DNSMASQ_FAMILY_PID_FILE
DNSMASQ_LOG_FILE = paths.DNSMASQ_FAMILY_LOG_FILE


def _parse_config_port():
    try:
        if not os.path.exists(DNSMASQ_CONFIG_FILE):
            return None
        with open(DNSMASQ_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                s = line.strip()
                if not s or s.startswith('#'):
                    continue
                if s.startswith('port='):
                    try:
                        return int(s.split('=', 1)[1].strip())
                    except Exception:
                        return None
    except Exception:
        return None
    return None


def get_dnsmasq_family_ports():
    """
    Возвращает порты dnsmasq-family по policy 1 (active если running, иначе config).
    """
    kv = run_init_status_kv(DNSMASQ_INIT_SCRIPT)
    config_port, active_port, effective_port, mismatch, status = get_ports_from_status_kv(
        kv,
        default_port=5301
    )
    return {
        'status_kv': kv,
        'status': status,
        'config_port': config_port,
        'active_port': active_port,
        'effective_port': effective_port,
        'mismatch': mismatch,
    }


@dnsmasq_family_api.route('/status', methods=['GET'])
def get_status():
    """Получить статус DNSMASQ family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        is_running, pid = check_process_running(
            'dnsmasq',
            pid_file=DNSMASQ_PID_FILE,
            cmdline_keyword='dnsmasq-family.conf'
        )

        ports = get_dnsmasq_family_ports()
        actual_port = ports.get('effective_port') or _parse_config_port() or 5301
        actual_port = int(actual_port)

        # UDP check
        port_open = check_port(actual_port, protocol='udp')

        # Logging enabled if log-queries present and not commented
        logging_enabled = False
        if os.path.exists(DNSMASQ_CONFIG_FILE):
            try:
                with open(DNSMASQ_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
                    for line in f:
                        s = line.strip()
                        if s.startswith('log-queries') and not s.startswith('#'):
                            logging_enabled = True
                            break
            except Exception:
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


@dnsmasq_family_api.route('/restart', methods=['POST'])
def restart():
    """Перезапустить DNSMASQ family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        result = subprocess.run(
            [DNSMASQ_INIT_SCRIPT, 'restart'],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            return jsonify({'success': True, 'message': 'DNSMASQ family restarted'})
        return jsonify({'success': False, 'error': result.stderr or result.stdout or 'Failed to restart'}), 500
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_family_api.route('/config', methods=['GET'])
def get_config():
    """Получить текущую конфигурацию DNSMASQ family (редактируемые параметры + полный конфиг для чтения)"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        if not os.path.exists(DNSMASQ_CONFIG_FILE):
            return jsonify({
                'editable': {
                    'cache-size': '1536',
                    'min-cache-ttl': '0',
                    'max-cache-ttl': '0',
                    'logging': False
                },
                'full_config': [],
                'config_file': DNSMASQ_CONFIG_FILE
            })

        config_data = {}
        full_config = []
        with open(DNSMASQ_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
            for line in f:
                full_config.append(line.rstrip('\n'))
                s = line.strip()
                if not s or s.startswith('#'):
                    continue
                if '=' in s:
                    k, v = s.split('=', 1)
                    config_data[k.strip()] = v.strip()

        logging_enabled = any(
            line.strip().startswith('log-queries') and not line.strip().startswith('#')
            for line in full_config
        )

        editable = {
            'cache-size': config_data.get('cache-size', '1536'),
            'max-cache-ttl': config_data.get('max-cache-ttl', '0'),
            'min-cache-ttl': config_data.get('min-cache-ttl', '0'),
            'logging': logging_enabled
        }

        return jsonify({
            'editable': editable,
            'full_config': full_config,
            'logging_enabled': logging_enabled
        })
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_family_api.route('/config', methods=['POST'])
def save_config():
    """Сохранить конфигурацию DNSMASQ family (редактируемые параметры)"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        os.makedirs(os.path.dirname(DNSMASQ_CONFIG_FILE), exist_ok=True)
        if not os.path.exists(DNSMASQ_CONFIG_FILE):
            with open(DNSMASQ_CONFIG_FILE, 'w', encoding='utf-8') as f:
                f.write('# DNSMASQ family configuration\n')

        request_data = request.get_json()
        if not request_data:
            return jsonify({'error': 'No configuration data provided'}), 400

        allowed_keys = {'cache-size', 'max-cache-ttl', 'min-cache-ttl', 'logging'}
        filtered_config = {k: v for k, v in request_data.items() if k in allowed_keys}

        logging_enabled = filtered_config.pop('logging', None)
        if logging_enabled is not None:
            logging_enabled = bool(logging_enabled)

        # Old logging state
        old_logging_enabled = False
        try:
            with open(DNSMASQ_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    s = line.strip()
                    if s.startswith('log-queries') and not s.startswith('#'):
                        old_logging_enabled = True
                        break
        except Exception:
            pass

        # Read current
        with open(DNSMASQ_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()

        updated_lines = []
        updated_keys = set()
        log_queries_found = False
        log_facility_found = False

        for line in lines:
            s = line.strip()

            # Logging toggles
            if s.startswith('log-queries'):
                log_queries_found = True
                if logging_enabled is not None:
                    updated_lines.append('log-queries\n' if logging_enabled else '# log-queries\n')
                else:
                    updated_lines.append(line)
                continue

            if s.startswith('log-facility'):
                log_facility_found = True
                if logging_enabled is not None:
                    updated_lines.append(
                        f'log-facility={DNSMASQ_LOG_FILE}\n' if logging_enabled else f'# log-facility={DNSMASQ_LOG_FILE}\n'
                    )
                else:
                    updated_lines.append(line)
                continue

            if s and not s.startswith('#') and '=' in s:
                k = s.split('=', 1)[0].strip()
                if k in filtered_config:
                    updated_lines.append(f'{k}={filtered_config[k]}\n')
                    updated_keys.add(k)
                    continue

            updated_lines.append(line)

        # Append missing editable keys (except logging)
        for k, v in filtered_config.items():
            if k not in updated_keys:
                updated_lines.append(f'{k}={v}\n')

        # Add logging directives if enabling and not found
        if logging_enabled:
            if not log_queries_found:
                updated_lines.append('log-queries\n')
            if not log_facility_found:
                updated_lines.append(f'log-facility={DNSMASQ_LOG_FILE}\n')

        with open(DNSMASQ_CONFIG_FILE, 'w', encoding='utf-8') as f:
            f.writelines(updated_lines)

        # Validate syntax
        result = subprocess.run(
            ['dnsmasq', '--test', '-C', DNSMASQ_CONFIG_FILE],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            return jsonify({'success': False, 'error': result.stderr, 'message': 'Configuration has errors'}), 400

        new_logging_enabled = logging_enabled if logging_enabled is not None else old_logging_enabled
        logging_changed = (old_logging_enabled != new_logging_enabled)

        if logging_changed:
            try:
                subprocess.run([DNSMASQ_INIT_SCRIPT, 'restart'], check=False, capture_output=True)
                return jsonify({'success': True, 'message': 'Configuration saved and dnsmasq restarted', 'restarted': True})
            except Exception:
                pass

        return jsonify({'success': True, 'message': 'Configuration saved and validated'})
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_family_api.route('/config/full', methods=['GET'])
def get_full_config():
    """Получить полный конфиг DNSMASQ family для редактора"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        if not os.path.exists(DNSMASQ_CONFIG_FILE):
            return jsonify({'config': [], 'file_path': DNSMASQ_CONFIG_FILE})

        with open(DNSMASQ_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()

        return jsonify({'config': lines, 'file_path': DNSMASQ_CONFIG_FILE})
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_family_api.route('/config/full', methods=['POST'])
def save_full_config():
    """Сохранить полный конфиг DNSMASQ family для редактора (с валидацией)"""
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

        tmp_config_file = DNSMASQ_CONFIG_FILE + '.tmp'
        backup_file = DNSMASQ_CONFIG_FILE + '.backup'

        try:
            if os.path.exists(DNSMASQ_CONFIG_FILE):
                shutil.copy2(DNSMASQ_CONFIG_FILE, backup_file)
        except Exception:
            pass

        os.makedirs(os.path.dirname(DNSMASQ_CONFIG_FILE), exist_ok=True)
        with open(tmp_config_file, 'w', encoding='utf-8') as f:
            for line in lines:
                line_clean = (line if isinstance(line, str) else str(line)).replace('\r', '').rstrip('\n')
                f.write(line_clean + '\n')

        result = subprocess.run(
            ['dnsmasq', '--test', '-C', tmp_config_file],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            try:
                os.remove(tmp_config_file)
            except Exception:
                pass
            return jsonify({'success': False, 'error': result.stderr, 'message': 'Configuration has errors'}), 400

        shutil.move(tmp_config_file, DNSMASQ_CONFIG_FILE)
        return jsonify({'success': True, 'message': 'Configuration saved and validated'})
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_family_api.route('/logs', methods=['GET'])
def get_logs():
    """Получить логи DNSMASQ family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        lines = request.args.get('lines', default=100, type=int)

        # logging enabled?
        logging_enabled = False
        if os.path.exists(DNSMASQ_CONFIG_FILE):
            try:
                with open(DNSMASQ_CONFIG_FILE, 'r', encoding='utf-8', errors='ignore') as f:
                    for line in f:
                        s = line.strip()
                        if s.startswith('log-queries') and not s.startswith('#'):
                            logging_enabled = True
                            break
            except Exception:
                pass

        if not os.path.exists(DNSMASQ_LOG_FILE):
            return jsonify({
                'logs': [],
                'message': 'Файл логов не существует',
                'logging_enabled': logging_enabled,
                'warning': 'Логирование выключено. Включите логирование в настройках конфигурации для записи новых логов.' if not logging_enabled else None
            })

        result = subprocess.run(
            ['tail', '-n', str(lines), DNSMASQ_LOG_FILE],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            log_lines = [line for line in result.stdout.split('\n') if line.strip()]
            warning = None
            if not logging_enabled:
                warning = 'Логирование выключено. Показаны старые логи. Включите логирование в настройках конфигурации для записи новых логов.'
            return jsonify({
                'logs': log_lines,
                'total_lines': len(log_lines),
                'logging_enabled': logging_enabled,
                'warning': warning
            })

        return jsonify({'logs': [], 'error': 'Failed to read log file', 'logging_enabled': logging_enabled}), 500
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_family_api.route('/logs/size', methods=['GET'])
def get_logs_size():
    """Получить размер файла логов DNSMASQ family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        if not os.path.exists(DNSMASQ_LOG_FILE):
            return jsonify({'size': 0, 'size_formatted': '0 B'})

        size = os.path.getsize(DNSMASQ_LOG_FILE)
        if size < 1024:
            size_formatted = f'{size} B'
        elif size < 1024 * 1024:
            size_formatted = f'{size / 1024:.2f} KB'
        else:
            size_formatted = f'{size / (1024 * 1024):.2f} MB'

        return jsonify({'size': size, 'size_formatted': size_formatted})
    except Exception as e:
        return handle_api_error(e)


@dnsmasq_family_api.route('/logs/clear', methods=['POST'])
def clear_logs():
    """Очистить логи DNSMASQ family"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401

    try:
        if not os.path.exists(DNSMASQ_LOG_FILE):
            return jsonify({'success': True, 'message': 'Log file does not exist'})

        with open(DNSMASQ_LOG_FILE, 'w', encoding='utf-8') as f:
            f.write('')

        return jsonify({'success': True, 'message': 'Logs cleared successfully'})
    except Exception as e:
        return handle_api_error(e)

