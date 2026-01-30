# -*- coding: utf-8 -*-

"""
Конфигурация Системного монитора
Автоматическое определение настроек
"""

import os
import socket
import subprocess
import secrets

# Импортируем пути из централизованного модуля
import paths

# Используем пути из paths.py
TOKEN_FILE = paths.TOKEN_FILE
SECRET_KEY_FILE = paths.SECRET_KEY_FILE

# Нестандартный порт
PORT = 8888

# Режим отладки (False для production)
DEBUG = False

def get_lan_ip():
    """Автоматическое определение LAN IP адреса"""
    # Список интерфейсов для проверки (в порядке приоритета)
    interfaces = ['br-lan', 'lan', 'eth0', 'eth1']
    
    # Попытка 1: через ip addr для каждого интерфейса
    for iface in interfaces:
        try:
            result = subprocess.run(
                ['ip', 'addr', 'show', iface],
                capture_output=True,
                text=True,
                timeout=2
            )
            if result.returncode == 0:
                for line in result.stdout.split('\n'):
                    if 'inet ' in line and '127.0.0.1' not in line:
                        parts = line.strip().split()
                        if len(parts) >= 2:
                            ip = parts[1].split('/')[0]
                            # Проверяем что это LAN адрес
                            if (ip.startswith('192.168.') or 
                                ip.startswith('10.') or 
                                (ip.startswith('172.') and int(ip.split('.')[1]) >= 16 and int(ip.split('.')[1]) <= 31)):
                                return ip
        except:
            continue
    
    # Попытка 2: через ip addr show (все интерфейсы)
    try:
        result = subprocess.run(
            ['ip', 'addr', 'show'],
            capture_output=True,
            text=True,
            timeout=2
        )
        if result.returncode == 0:
            for line in result.stdout.split('\n'):
                if 'inet ' in line and '127.0.0.1' not in line and 'scope global' in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        ip = parts[1].split('/')[0]
                        if (ip.startswith('192.168.') or 
                            ip.startswith('10.') or 
                            (ip.startswith('172.') and int(ip.split('.')[1]) >= 16 and int(ip.split('.')[1]) <= 31)):
                            return ip
    except:
        pass
    
    # Попытка 3: через socket (может вернуть внешний IP, поэтому проверяем)
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(('8.8.8.8', 80))
            ip = s.getsockname()[0]
            s.close()
            # Проверяем что это LAN адрес (не внешний)
            if (ip.startswith('192.168.') or 
                ip.startswith('10.') or 
                (ip.startswith('172.') and int(ip.split('.')[1]) >= 16 and int(ip.split('.')[1]) <= 31)):
                return ip
        except:
            s.close()
    except:
        pass
    
    # Если ничего не получилось, используем 127.0.0.1 (только localhost)
    # Это безопаснее чем 0.0.0.0, но доступ будет только с самого роутера
    # В логах будет предупреждение
    print("WARNING: Could not determine LAN IP, using 127.0.0.1 (localhost only)")
    print("Please check network configuration or set HOST manually in config.py")
    return '127.0.0.1'


def get_or_create_token(file_path):
    """Получить существующий токен или создать новый"""
    # Создаем директорию если не существует
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    
    # Пытаемся прочитать существующий токен
    if os.path.exists(file_path):
        try:
            with open(file_path, 'r') as f:
                token = f.read().strip()
                if token:
                    return token
        except:
            pass
    
    # Создаем новый токен
    token = secrets.token_urlsafe(32)
    try:
        with open(file_path, 'w') as f:
            f.write(token)
        os.chmod(file_path, 0o600)  # Только для владельца
    except Exception as e:
        # Если не удалось записать, используем токен в памяти
        pass
    
    return token


# Автоматическое определение настроек
HOST = get_lan_ip()
SECRET_KEY = get_or_create_token(SECRET_KEY_FILE)
AUTH_TOKEN = get_or_create_token(TOKEN_FILE)

