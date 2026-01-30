#!/bin/sh
# Синхронизация папки lists/ с GitHub:
# 1. Скачивает списки из itdoginfo
# 2. Коммитит и пушит изменения (только lists/)
#
# Запуск: из корня репо — ./lists/sync-to-github.sh
#         или из lists/ — ./sync-to-github.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Проверка: мы в git-репо
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Ошибка: $REPO_ROOT не является git-репозиторием"
    exit 1
fi

# Настройки git (если ещё не заданы)
git config user.name >/dev/null 2>&1 || git config user.name "allow-sync"
git config user.email >/dev/null 2>&1 || git config user.email "sync@localhost"

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

echo "=== Синхронизация lists/ ==="
echo "Репозиторий: $REPO_ROOT"
echo ""

# 0. Обновить локальную копию
git pull --rebase origin "$BRANCH" 2>/dev/null || true

# 1. Скачать списки из itdoginfo
if [ -x "$SCRIPT_DIR/download-raw.sh" ]; then
    "$SCRIPT_DIR/download-raw.sh"
else
    echo "Ошибка: не найден или не исполняем download-raw.sh"
    exit 1
fi

# 2. Добавить все изменения в lists/
git add lists/

# 3. Есть ли изменения?
if git diff --staged --quiet; then
    echo ""
    echo "Изменений нет, push не требуется"
    exit 0
fi

# 4. Коммит и push
echo ""
echo "Отправка в GitHub..."
git commit -m "sync: обновление lists из itdoginfo $(date +%Y-%m-%d)"
git push origin "$BRANCH"

echo ""
echo "Готово."
