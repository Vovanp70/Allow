# -*- coding: utf-8 -*-

"""
API для общей информации о системе
"""

from flask import Blueprint, jsonify
import subprocess
import socket
import urllib.request
import urllib.error
import ipaddress
import sys
import os

# Добавляем родительскую директорию в путь для импорта config
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

system_api = Blueprint('system_api', __name__)


def check_auth():
    """Проверка аутентификации через токен"""
    from flask import request
    import config as cfg
    
    token = request.headers.get('X-Auth-Token')
    if token != cfg.AUTH_TOKEN:
        return False
    return True


@system_api.route('/info', methods=['GET'])
def get_system_info():
    """Получить общую информацию о системе"""
    if not check_auth():
        return jsonify({'error': 'Unauthorized'}), 401
    
    try:
        # Проверка интернета
        internet_status = check_internet()
        
        # Получение внешнего IP
        external_ip = get_external_ip() if internet_status else None
        
        return jsonify({
            'internet': {
                'status': internet_status,
                'connected': internet_status
            },
            'external_ip': external_ip
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


def check_internet():
    """Проверка наличия интернета"""
    # ICMP/ping может быть запрещён политиками/провайдером/iptables, поэтому
    # используем несколько способов: ping (если есть) и HTTP (как более надёжный).
    try:
        # Пинг Google DNS (Linux/busybox). Если опции не поддерживаются — упадём в fallback.
        result = subprocess.run(
            ['ping', '-c', '1', '-W', '2', '8.8.8.8'],
            capture_output=True,
            timeout=3
        )
        if result.returncode == 0:
            return True
    except Exception:
        pass

    # Fallback: HTTP connectivity-check (работает даже если ICMP отключён)
    try:
        # generate_204 — лёгкий эндпоинт, не тянет страницу
        req = urllib.request.Request(
            'http://connectivitycheck.gstatic.com/generate_204',
            headers={'User-Agent': 'allow-monitor/1.0'}
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            # 204 ожидаемо, но иногда отдаёт 200 через captive portal
            return resp.status in (200, 204)
    except Exception:
        return False


def get_external_ip():
    """Получение внешнего IP адреса"""
    try:
        # Использовать несколько сервисов для надежности.
        # На роутере возможен split-routing: часть сайтов идёт через VPN, часть — напрямую через WAN.
        # Поэтому порядок важен: сначала те источники, которые обычно возвращают "правильный" WAN IP
        # в вашей схеме, а ipify оставляем как запасной вариант в конце.
        services = [
            # HTTP (без TLS) — на роутерах может не быть CA/SSL
            'http://ifconfig.me/ip',
            'http://icanhazip.com',
            'https://ifconfig.me/ip',
            'https://icanhazip.com',
            # запасные (могут возвращать VPN IP при split-routing)
            'http://api.ipify.org',
            'https://api.ipify.org',
        ]
        
        for service in services:
            try:
                req = urllib.request.Request(
                    service,
                    headers={'User-Agent': 'allow-monitor/1.0'}
                )
                with urllib.request.urlopen(req, timeout=3) as response:
                    ip = response.read().decode('utf-8', errors='ignore').strip()
                    # Валидация: берём первый токен и проверяем как IPv4/IPv6
                    ip = ip.split()[0] if ip else ''
                    if not ip:
                        continue
                    try:
                        return str(ipaddress.ip_address(ip))
                    except Exception:
                        continue
            except Exception:
                continue
        
        return None
    except Exception:
        return None

