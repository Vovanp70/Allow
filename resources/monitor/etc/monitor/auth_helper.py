#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Auth helper for monitor: credentials (admin/salt/hash), sessions (tokens).
CLI for use from api.cgi/config.cgi (shell):
  verify_session <token>     -> exit 0 if valid, 1 otherwise
  login <login> <password>   -> stdout token on success, exit 1 on failure
  destroy_session <token>   -> exit 0
  change_password <current> <new> -> exit 0 on success, 1 on failure (user from credentials)
"""

import hashlib
import os
import secrets
import sys

# CONFIG_DIR: каталог с credentials/sessions, без зависимости от paths.py
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if os.path.basename(_SCRIPT_DIR) == 'cgi-bin':
    CONFIG_DIR = os.path.dirname(_SCRIPT_DIR)
else:
    CONFIG_DIR = _SCRIPT_DIR
# Можно переопределить через переменную окружения (как в api.cgi)
CONFIG_DIR = os.environ.get('CONFIG_DIR', CONFIG_DIR)

CREDENTIALS_FILE = os.path.join(CONFIG_DIR, 'credentials')
SESSIONS_FILE = os.path.join(CONFIG_DIR, 'sessions')
DEFAULT_LOGIN = 'admin'
DEFAULT_PASSWORD = 'admin'


def _ensure_config_dir():
    os.makedirs(CONFIG_DIR, exist_ok=True)


def _hash_password(salt: str, password: str) -> str:
    return hashlib.sha256((salt + password).encode('utf-8')).hexdigest()


def get_or_create_credentials():
    """Create credentials file with admin/admin if missing."""
    _ensure_config_dir()
    if os.path.exists(CREDENTIALS_FILE):
        return
    salt = secrets.token_hex(16)
    h = _hash_password(salt, DEFAULT_PASSWORD)
    line = f'{DEFAULT_LOGIN}:{salt}:{h}\n'
    with open(CREDENTIALS_FILE, 'w') as f:
        f.write(line)
    try:
        os.chmod(CREDENTIALS_FILE, 0o600)
    except OSError:
        pass


def verify(login: str, password: str) -> bool:
    """Check login/password against credentials file."""
    get_or_create_credentials()
    if not os.path.exists(CREDENTIALS_FILE):
        return False
    with open(CREDENTIALS_FILE, 'r') as f:
        line = f.read().strip()
    parts = line.split(':')
    if len(parts) != 3:
        return False
    user, salt, stored_hash = parts
    if user != login:
        return False
    return _hash_password(salt, password) == stored_hash


def _get_username():
    """Return first (and only) username from credentials file."""
    get_or_create_credentials()
    if not os.path.exists(CREDENTIALS_FILE):
        return DEFAULT_LOGIN
    with open(CREDENTIALS_FILE, 'r') as f:
        line = f.read().strip()
    parts = line.split(':', 1)
    return parts[0] if parts else DEFAULT_LOGIN


def change_password(current_password: str, new_password: str) -> bool:
    """Change password for the stored user (admin). Returns True on success."""
    login = _get_username()
    if not verify(login, current_password):
        return False
    get_or_create_credentials()
    with open(CREDENTIALS_FILE, 'r') as f:
        line = f.read().strip()
    parts = line.split(':', 2)
    if len(parts) != 3:
        return False
    user, salt, _ = parts
    new_salt = secrets.token_hex(16)
    new_hash = _hash_password(new_salt, new_password)
    new_line = f'{user}:{new_salt}:{new_hash}\n'
    with open(CREDENTIALS_FILE, 'w') as f:
        f.write(new_line)
    try:
        os.chmod(CREDENTIALS_FILE, 0o600)
    except OSError:
        pass
    return True


def create_session() -> str:
    """Create a new session token and append to sessions file. Returns token."""
    _ensure_config_dir()
    token = secrets.token_urlsafe(32)
    with open(SESSIONS_FILE, 'a') as f:
        f.write(token + '\n')
    try:
        os.chmod(SESSIONS_FILE, 0o600)
    except OSError:
        pass
    return token


def verify_session(token: str) -> bool:
    """Check if token exists in sessions file."""
    if not token or not os.path.exists(SESSIONS_FILE):
        return False
    with open(SESSIONS_FILE, 'r') as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    return token in lines


def destroy_session(token: str):
    """Remove token from sessions file."""
    if not os.path.exists(SESSIONS_FILE):
        return
    with open(SESSIONS_FILE, 'r') as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    lines = [t for t in lines if t != token]
    with open(SESSIONS_FILE, 'w') as f:
        f.write('\n'.join(lines) + ('\n' if lines else ''))
    try:
        os.chmod(SESSIONS_FILE, 0o600)
    except OSError:
        pass


def main():
    if len(sys.argv) < 2:
        sys.exit(1)
    cmd = sys.argv[1].lower()
    if cmd == 'verify_session':
        if len(sys.argv) < 3:
            sys.exit(1)
        token = sys.argv[2]
        sys.exit(0 if verify_session(token) else 1)
    if cmd == 'login':
        if len(sys.argv) < 4:
            sys.exit(1)
        login, password = sys.argv[2], sys.argv[3]
        if verify(login, password):
            token = create_session()
            print(token)
            sys.exit(0)
        sys.exit(1)
    if cmd == 'destroy_session':
        if len(sys.argv) < 3:
            sys.exit(0)
        destroy_session(sys.argv[2])
        sys.exit(0)
    if cmd == 'change_password':
        if len(sys.argv) < 4:
            sys.exit(1)
        current, new = sys.argv[2], sys.argv[3]
        sys.exit(0 if change_password(current, new) else 1)
    sys.exit(1)


if __name__ == '__main__':
    main()
