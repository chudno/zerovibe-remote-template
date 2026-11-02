#!/bin/sh
set -eu

mode=${1:---dry-run}
case "$mode" in
  --dry-run|--apply) ;;
  *) echo 'Использование: ./deploy.sh [--dry-run|--apply]' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo 'Лишние параметры' >&2; exit 2; }
cd "$(dirname "$0")"

facts=$(remote-info)
target=$(printf '%s' "$facts" | python3 -c '
import json, posixpath, sys
p = json.load(sys.stdin)["path"]
if not p.startswith("/") or p == "/" or posixpath.normpath(p) != p or "\n" in p or "\r" in p:
    sys.exit("Некорректная папка сайта")
print(p)
')
encoded=$(printf '%s' "$target" | base64 | tr -d '\n')

check_site() {
  current_facts=$(remote-info)
  live=$(printf '%s' "$current_facts" | python3 -c '
import json, sys
live = json.load(sys.stdin)["live"]
if not isinstance(live, bool):
    sys.exit("Некорректное состояние сайта")
print("true" if live else "false")
')
  if [ "$live" = false ]; then
    site_url=$(printf '%s' "$current_facts" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
    headers=$(curl --silent --show-error --location --max-redirs 3 --max-time 15 \
      --proto '=http,https' --proto-redir '=http,https' -D - -o /dev/null -- "$site_url") || {
        echo 'Не удалось проверить защиту сайта по его адресу' >&2; exit 1;
      }
    status=$(printf '%s\n' "$headers" | awk '/^HTTP\// { status=$2 } END { print status }')
    [ "$status" = 401 ] && printf '%s\n' "$headers" | tr -d '\r' | grep -qi '^WWW-Authenticate:[[:space:]]*Basic' || {
      echo 'Сначала закройте сайт паролем и проверьте защиту' >&2; exit 1;
    }
  fi
}

if [ "$mode" = "--apply" ]; then
  check_site
  initial_live=$live
  ssh server "sh -s -- '$encoded'" <<'REMOTE'
set -eu
umask 077
target=$(printf '%s' "$1" | base64 -d)
[ -d "$target" ] || { echo 'Папка сайта не найдена' >&2; exit 1; }
actual=$(cd "$target" && pwd -P)
[ "$actual" = "$target" ] || { echo 'Путь содержит ссылку: укажите настоящий путь к папке' >&2; exit 1; }
home_dir=$(cd "$HOME" && pwd -P)
case "$home_dir/zv-backups/" in "$target/"*) echo 'Папка резервных копий находится внутри сайта' >&2; exit 1;; esac
[ ! -L "$home_dir/zv-backups" ] || { echo 'Папка резервных копий не должна быть ссылкой' >&2; exit 1; }
mkdir -p "$home_dir/zv-backups"
backup_dir=$(cd "$home_dir/zv-backups" && pwd -P)
[ "$backup_dir" = "$home_dir/zv-backups" ] || { echo 'Небезопасная папка резервных копий' >&2; exit 1; }
backup="$backup_dir/$(date -u +%Y%m%dT%H%M%SZ)-$$.tgz"
tar -C "$target" -czf "$backup" .
echo "Резервная копия создана: $backup"
REMOTE
fi

sync() {
  rsync -azs "$@" \
    --exclude='.git/' --exclude='.claude/' --exclude='.zerovibe/' \
    --exclude='/deploy.sh' --exclude='/README.md' --exclude='/.gitignore' \
    --exclude='.env' --exclude='.env.*' --exclude='.htaccess' --exclude='.htpasswd' \
    --exclude='vendor/' --exclude='node_modules/' --exclude='uploads/' \
    --exclude='storage/' --exclude='.well-known/' --exclude='*.log' \
    ./ "server:$target/"
}

echo 'Проверяем изменения перед выкладкой:'
if [ "$mode" = "--apply" ]; then
  sync --delete --dry-run --itemize-changes
  check_site
  [ "$live" = "$initial_live" ] || { echo 'Состояние сайта изменилось. Проверьте настройки и повторите выкладку' >&2; exit 1; }
  echo 'Выкладываем сайт:'
  sync --delete --itemize-changes
else
  sync --dry-run --itemize-changes
fi
