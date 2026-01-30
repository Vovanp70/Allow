# -*- coding: utf-8 -*-

"""
Централизованное управление путями к файлам и директориям
Упрощает портирование на другие ОС
"""

import os

# ============================================================================
# БАЗОВЫЕ ПУТИ (можно изменить для другой ОС)
# ============================================================================

# Базовый префикс для установки (по умолчанию /opt для OpenWrt/Keenetic)
# Для других ОС можно изменить на /usr/local, /opt, /etc и т.д.
BASE_PREFIX = os.environ.get('MONITOR_BASE_PREFIX', '/opt')

# Альтернативные префиксы для разных ОС
# Можно переопределить через переменную окружения MONITOR_BASE_PREFIX
# Например: export MONITOR_BASE_PREFIX=/usr/local

# ============================================================================
# ПУТИ ПРИЛОЖЕНИЯ
# ============================================================================

# Директория приложения
APP_DIR = f'{BASE_PREFIX}/etc/allow/monitor'
CONFIG_DIR = f'{BASE_PREFIX}/etc/allow/monitor'

# Файлы токенов и ключей
TOKEN_FILE = f'{CONFIG_DIR}/auth_token.txt'
SECRET_KEY_FILE = f'{CONFIG_DIR}/secret_key.txt'

# ============================================================================
# ПУТИ СИСТЕМНЫХ ДИРЕКТОРИЙ
# ============================================================================

# Системные директории
ETC_DIR = f'{BASE_PREFIX}/etc'
VAR_DIR = f'{BASE_PREFIX}/var'
VAR_LOG_DIR = f'{VAR_DIR}/log'
VAR_RUN_DIR = f'{VAR_DIR}/run'
INIT_DIR = f'{ETC_DIR}/init.d'

# ============================================================================
# Хелперы: динамические порты/пути (под Entware/Keenetic)
# ============================================================================

def _read_port_file(path: str, default: int) -> int:
    try:
        if os.path.exists(path):
            with open(path, 'r') as f:
                raw = f.read().strip()
            if raw:
                val = int(raw)
                if val > 0:
                    return val
    except Exception:
        pass
    return default

def _prefer_allow_init(name: str) -> str:
    """
    На роутере компоненты часто ставятся в /opt/etc/allow/init.d/.
    Если файл там есть — используем его, иначе fallback на /opt/etc/init.d/.
    """
    allow_path = f'{ETC_DIR}/allow/init.d/{name}'
    if os.path.exists(allow_path):
        return allow_path
    return f'{INIT_DIR}/{name}'

# ============================================================================
# ПУТИ КОМПОНЕНТОВ: Stubby
# ============================================================================

STUBBY_INIT_SCRIPT = _prefer_allow_init('S97stubby')
STUBBY_CONFIG_FILE = f'{ETC_DIR}/allow/stubby/stubby.yml'
STUBBY_PID_FILE = f'{VAR_RUN_DIR}/stubby.pid'

# ============================================================================
# ПУТИ КОМПОНЕНТОВ: Stubby Family
# ============================================================================

STUBBY_FAMILY_INIT_SCRIPT = _prefer_allow_init('S97stubby-family')
STUBBY_FAMILY_CONFIG_FILE = f'{ETC_DIR}/allow/stubby/stubby-family.yml'
STUBBY_FAMILY_PID_FILE = f'{VAR_RUN_DIR}/stubby-family.pid'

# ============================================================================
# ПУТИ КОМПОНЕНТОВ: DNSMASQ
# ============================================================================

DNSMASQ_INIT_SCRIPT = _prefer_allow_init('S98dnsmasq-full')
DNSMASQ_CONFIG_FILE = f'{ETC_DIR}/allow/dnsmasq-full/dnsmasq.conf'
DNSMASQ_CONFIG_FILE_ALT = f'{ETC_DIR}/dnsmasq-full.conf'
DNSMASQ_LOG_FILE = f'{VAR_LOG_DIR}/allow/dnsmasq.log'
DNSMASQ_PID_FILE = f'{VAR_RUN_DIR}/dnsmasq.pid'

# ============================================================================
# ПУТИ КОМПОНЕНТОВ: DNSMASQ Family
# ============================================================================

DNSMASQ_FAMILY_INIT_SCRIPT = _prefer_allow_init('S98dnsmasq-family')
DNSMASQ_FAMILY_CONFIG_FILE = f'{ETC_DIR}/allow/dnsmasq-full/dnsmasq-family.conf'
DNSMASQ_FAMILY_LOG_FILE = f'{VAR_LOG_DIR}/allow/dnsmasq-family.log'
DNSMASQ_FAMILY_PID_FILE = f'{VAR_RUN_DIR}/dnsmasq-family.pid'

# ============================================================================
# ПУТИ КОМПОНЕНТОВ: Routing (Маршрутизация)
# ============================================================================

ROUTING_IPSETS_DIR = f'{ETC_DIR}/allow/dnsmasq-full/ipsets'
ROUTING_NONBYPASS_FILE = f'{ROUTING_IPSETS_DIR}/nonbypass.txt'
ROUTING_ZAPRET_FILE = f'{ROUTING_IPSETS_DIR}/zapret.txt'
ROUTING_BYPASS_FILE = f'{ROUTING_IPSETS_DIR}/bypass.txt'

# ============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================

def get_dnsmasq_config_file():
    """
    Получить путь к файлу конфигурации DNSMASQ (проверяет оба варианта)
    """
    if os.path.exists(DNSMASQ_CONFIG_FILE):
        return DNSMASQ_CONFIG_FILE
    elif os.path.exists(DNSMASQ_CONFIG_FILE_ALT):
        return DNSMASQ_CONFIG_FILE_ALT
    else:
        # Если ни один не существует, возвращаем основной путь для создания
        return DNSMASQ_CONFIG_FILE


def ensure_dirs():
    """
    Создать необходимые директории, если они не существуют
    """
    dirs_to_create = [
        CONFIG_DIR,
        APP_DIR,
        VAR_LOG_DIR,
        f'{VAR_LOG_DIR}/allow',
        f'{VAR_LOG_DIR}/allow/monitor',
        VAR_RUN_DIR,
        f'{ETC_DIR}/allow/stubby',
        f'{ETC_DIR}/allow/dnsmasq-full',
        f'{ETC_DIR}/allow/dnsmasq-full/ipsets',
    ]
    
    for dir_path in dirs_to_create:
        os.makedirs(dir_path, exist_ok=True)

