#!/bin/sh
# Bootstrap: установка Allow напрямую с GitHub.
# Одна команда (выполнять на роутере по SSH):
#   curl -sL https://raw.githubusercontent.com/Vovanp70/Allow/main/install.sh | sh
# Или:
#   curl -O https://raw.githubusercontent.com/Vovanp70/Allow/main/install.sh && sh install.sh

set -e
REPO_URL="https://github.com/Vovanp70/Allow"
RAW_URL="https://raw.githubusercontent.com/Vovanp70/Allow/main"
WORK_DIR="/opt/tmp"

echo "[ALLOW] Bootstrap: скачивание репозитория с GitHub..."

if ! command -v curl >/dev/null 2>&1; then
    echo "[ALLOW] Ошибка: нужен curl. Установите: opkg install curl" >&2
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "[ALLOW] Ошибка: нужен tar." >&2
    exit 1
fi

cd "$WORK_DIR" || { echo "[ALLOW] Ошибка: нет доступа к $WORK_DIR" >&2; exit 1; }
rm -rf allow Allow-main

if ! curl -sL "${REPO_URL}/archive/refs/heads/main.tar.gz" | tar xz; then
    echo "[ALLOW] Ошибка: не удалось скачать или распаковать архив." >&2
    exit 1
fi

mv Allow-main allow
cd allow || exit 1

echo "[ALLOW] Запуск установщика..."
exec sh install_all.sh install
