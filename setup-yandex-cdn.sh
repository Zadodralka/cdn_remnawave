#!/usr/bin/env bash
#
# setup-yandex-cdn.sh
#
# Автоматическая настройка чистой ноды Remnawave для работы через Yandex Cloud CDN:
#   - выпуск сертификата (certbot, RSA + ISRG Root X1, DNS-01 через хуки)
#   - разбивка сертификата на leaf/chain для загрузки в Yandex Certificate Manager
#   - настройка nginx (location для xhttp-инбаунда)
#   - установка cron-задачи автопродления сертификата
#   - диагностика всей цепочки (порт -> nginx -> CDN -> TLS -> HTTP/2)
#   - вывод готового JSON для инбаунда Xray и настроек Host в Remnawave
#
# ПРЕДПОЛАГАЕТСЯ: CDN-ресурс в Yandex Cloud уже создан (домен раздачи,
# источник, SNI, протокол HTTPS к источнику и т.д. настроены в консоли).
#
# Запуск: sudo bash setup-yandex-cdn.sh
#
set -euo pipefail

# ============================================================
# Пути и константы
# ============================================================
CONFIG_DIR="/etc/yandex-cdn-vpn"
CONFIG_FILE="${CONFIG_DIR}/config.env"
HOOK_DIR="${CONFIG_DIR}/hooks"
BIN_DIR="${CONFIG_DIR}/bin"
CERTS_OUT_DIR="${CONFIG_DIR}/certs-for-yandex"
LOG_DIR="/var/log/yandex-cdn-vpn"

# ============================================================
# Цвета и вывод
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; GRAY='\033[0;90m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ОШИБКА]${NC} $*" >&2; }
hr()   { echo -e "${GRAY}────────────────────────────────────────────────────────────────${NC}"; }

# Пауза между блоками вывода, чтобы текст не проскакивал мимо глаз.
# Настраивается: PAUSE_SECONDS=0 sudo -E bash setup-yandex-cdn.sh - отключить,
# PAUSE_SECONDS=4 - сделать длиннее. По умолчанию 2 секунды.
PAUSE_SECONDS="${PAUSE_SECONDS:-2}"
beat() {
  local secs="${1:-$PAUSE_SECONDS}"
  [ "$secs" = "0" ] && return 0
  sleep "$secs"
}

STEP_TOTAL=9
STEP_CUR=0
step() {
  STEP_CUR=$((STEP_CUR + 1))
  echo
  echo -e "${MAGENTA}${BOLD}▶ [${STEP_CUR}/${STEP_TOTAL}]${NC} ${CYAN}${BOLD}$*${NC}"
}

# Баннер ZADODRALKA CDN
banner() {
  local box_width=68
  local title="Z A D O D R A L K A   C D N"
  local title_len=${#title}
  local pad_left=$(( (box_width - title_len) / 2 ))
  local pad_right=$(( box_width - title_len - pad_left ))

  local top; top="╔$(printf '═%.0s' $(seq 1 "$box_width"))╗"
  local bottom; bottom="╚$(printf '═%.0s' $(seq 1 "$box_width"))╝"
  local mid; mid="║$(printf ' %.0s' $(seq 1 "$pad_left"))${title}$(printf ' %.0s' $(seq 1 "$pad_right"))║"

  echo
  echo -e "${CYAN}${BOLD}  ${top}${NC}"
  echo -e "${CYAN}${BOLD}  ${mid}${NC}"
  echo -e "${CYAN}${BOLD}  ${bottom}${NC}"
  echo -e "${GRAY}          Yandex Cloud CDN  ×  Remnawave  ×  Xray XHTTP автоматизация${NC}"
  hr
}

# Спиннер для долгих тихих операций (apt install и т.п.)
# Использование: run_with_spinner "Текст" command arg1 arg2 ...
run_with_spinner() {
  local msg="$1"; shift
  local logfile; logfile=$(mktemp)
  ("$@" >"$logfile" 2>&1) &
  local pid=$!
  local frames='|/-\'
  local i=0
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    i=$(((i + 1) % ${#frames}))
    printf "\r${CYAN}%s${NC} %s" "${frames:$i:1}" "$msg"
    sleep 0.1
  done
  tput cnorm 2>/dev/null || true
  wait "$pid"
  local rc=$?
  if [ $rc -eq 0 ]; then
    printf "\r${GREEN}[OK]${NC} %s\n" "$msg"
  else
    printf "\r${RED}[ОШИБКА]${NC} %s\n" "$msg"
    cat "$logfile" >&2
  fi
  rm -f "$logfile"
  return $rc
}

# ============================================================
# 0. Проверки окружения
# ============================================================
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Запусти скрипт от root: sudo bash $0"
    exit 1
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  else
    echo "unknown"
  fi
}

check_prereqs() {
  log "Проверка зависимостей..."
  local pm; pm=$(detect_pkg_manager)
  local missing=()

  command -v docker  >/dev/null 2>&1 || { err "Docker не найден. Установи Remnawave/Docker перед запуском."; exit 1; }
  command -v certbot >/dev/null 2>&1 || missing+=("certbot")
  command -v dig      >/dev/null 2>&1 || missing+=("dnsutils")
  command -v openssl >/dev/null 2>&1 || missing+=("openssl")
  command -v curl     >/dev/null 2>&1 || missing+=("curl")

  if [ "${#missing[@]}" -gt 0 ]; then
    if [ "$pm" = "apt" ]; then
      run_with_spinner "Обновление списка пакетов..." apt-get update -qq
      run_with_spinner "Устанавливаю: ${missing[*]}" apt-get install -y -qq "${missing[@]}"
    else
      err "Не найдены пакеты: ${missing[*]}. Установи вручную и перезапусти скрипт."
      exit 1
    fi
  fi
  ok "Все зависимости на месте"
}

# ============================================================
# 1. Автообнаружение контейнеров nginx / ноды
# ============================================================

# Выбор из нескольких кандидатов: если ровно один - берём его,
# если есть точное совпадение по предпочитаемому имени - берём его,
# если несколько разных - спрашиваем пользователя.
_pick_container() {
  local preferred_name="$1"; shift
  local candidates=("$@")
  local count=${#candidates[@]}

  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -eq 1 ]; then
    echo "${candidates[0]}"
    return 0
  fi
  for c in "${candidates[@]}"; do
    if [ "$c" = "$preferred_name" ]; then
      echo "$c"
      return 0
    fi
  done
  warn "Найдено несколько подходящих контейнеров:" >&2
  local i=1
  for c in "${candidates[@]}"; do echo "  $i) $c" >&2; i=$((i+1)); done
  local idx
  read -rp "Выбери номер: " idx
  echo "${candidates[$((idx-1))]}"
}

detect_nginx_container() {
  local names
  mapfile -t names < <(docker ps --format '{{.Names}}\t{{.Image}}' | awk 'tolower($0) ~ /nginx/ {print $1}')
  if [ "${#names[@]}" -eq 0 ]; then
    err "Не найден ни один запущенный контейнер, похожий на nginx (docker ps)."
    err "Убедись, что Remnawave/nginx уже запущены, и перезапусти скрипт."
    exit 1
  fi
  _pick_container "remnawave-nginx" "${names[@]}"
}

detect_node_container() {
  local names
  mapfile -t names < <(docker ps --format '{{.Names}}\t{{.Image}}' | awk 'tolower($0) ~ /remnanode/ || tolower($0) ~ /remnawave\/node/ {print $1}')
  if [ "${#names[@]}" -eq 0 ]; then
    err "Не найден ни один запущенный контейнер ноды Remnawave (docker ps)."
    err "Убедись, что remnanode уже запущен, и перезапусти скрипт."
    exit 1
  fi
  _pick_container "remnanode" "${names[@]}"
}

# Находит РЕАЛЬНЫЙ путь конфиг-файла внутри контейнера nginx, где описан
# server_name == ORIGIN_DOMAIN. Работает через `nginx -T`, который печатает
# полный эффективный конфиг с маркерами "# configuration file <путь>:" перед
# каждым включённым файлом - так мы не гадаем, что это default.conf, а берём
# реальный файл, где бы он ни лежал (conf.d/, sites-enabled/, и т.д.).
detect_nginx_conf_file() {
  local dump
  dump=$(docker exec "$NGINX_CONTAINER" nginx -T 2>/dev/null) || {
    err "Не удалось выполнить 'nginx -T' в контейнере ${NGINX_CONTAINER}"
    return 1
  }

  local found_path
  found_path=$(echo "$dump" | awk -v origin="$ORIGIN_DOMAIN" '
    /^# configuration file/ {
      line=$0
      sub(/^# configuration file /, "", line)
      sub(/:$/, "", line)
      current=line
    }
    /server_name/ && index($0, origin) > 0 { print current; found=1; exit }
    END { if (!found) exit 1 }
  ')

  if [ -z "$found_path" ]; then
    return 1
  fi
  echo "$found_path"
}

# Находит РЕАЛЬНЫЙ путь файла конфига на ХОСТЕ (не внутри контейнера) -
# через docker inspect mounts. Это нужно, потому что конфиг часто
# монтируется в контейнер как read-only bind-mount (типично для
# remnawave-nginx docker-compose), и писать напрямую в файл ВНУТРИ
# контейнера тогда невозможно ("Read-only file system") - редактировать
# нужно исходник на хосте, а контейнер потом перезапустить, чтобы он
# подхватил изменения.
#
# Работает независимо от того, где именно на хосте лежит конфиг
# (/opt/remnanode/, /opt/remnawave/ или что-то ещё) - находит это
# автоматически по сопоставлению Destination-путей монтирования с
# NGINX_CONF_PATH (внутриконтейнерным путём, найденным в detect_nginx_conf_file).
detect_host_nginx_conf_path() {
  local mounts_raw
  mounts_raw=$(docker inspect -f '{{range .Mounts}}{{.Source}}|||{{.Destination}}{{"\n"}}{{end}}' "$NGINX_CONTAINER" 2>/dev/null) || return 1

  local best_dest="" best_src="" best_len=-1
  local line src dest
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    src="${line%%|||*}"
    dest="${line##*|||}"
    case "$NGINX_CONF_PATH" in
      "$dest"|"$dest"/*)
        if [ "${#dest}" -gt "$best_len" ]; then
          best_len=${#dest}
          best_dest="$dest"
          best_src="$src"
        fi
        ;;
    esac
  done <<< "$mounts_raw"

  if [ -z "$best_src" ]; then
    return 1
  fi

  local suffix="${NGINX_CONF_PATH#"$best_dest"}"
  echo "${best_src}${suffix}"
}

# ============================================================
# 2. Конфигурация (первый запуск — интерактивно, дальше — из файла)
# ============================================================
load_or_ask_config() {
  mkdir -p "$CONFIG_DIR" "$HOOK_DIR" "$BIN_DIR" "$CERTS_OUT_DIR" "$LOG_DIR"

  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    # Миграция: если конфиг сохранён до появления NGINX_HOST_CONF_PATH
    # (более старая версия скрипта) - переменной не будет, и set -u
    # упадёт при первом же обращении. Доопределяем и пересохраняем.
    if [ -z "${NGINX_HOST_CONF_PATH:-}" ]; then
      warn "В конфиге нет NGINX_HOST_CONF_PATH (старая версия конфига) - определяю..."
      ensure_containers
      if NGINX_HOST_CONF_PATH=$(detect_host_nginx_conf_path); then
        ok "Найден путь на хосте: ${NGINX_HOST_CONF_PATH}"
      else
        read -rp "Укажи путь к файлу ${NGINX_CONF_PATH} на ХОСТЕ вручную: " NGINX_HOST_CONF_PATH
        [ -z "$NGINX_HOST_CONF_PATH" ] && { err "Путь к конфигу nginx на хосте обязателен"; exit 1; }
      fi
      echo "NGINX_HOST_CONF_PATH=\"$NGINX_HOST_CONF_PATH\"" >> "$CONFIG_FILE"
      ok "Конфиг дополнен и сохранён"
    fi

    ok "Конфиг загружен из $CONFIG_FILE"
    log "  ORIGIN_DOMAIN=$ORIGIN_DOMAIN  CDN_DOMAIN=$CDN_DOMAIN  PATH=$XRAY_PATH  PORT=$XRAY_PORT"
    log "  NGINX_CONTAINER=$NGINX_CONTAINER  NODE_CONTAINER=$NODE_CONTAINER"
    log "  NGINX_CONF_PATH=$NGINX_CONF_PATH (host: $NGINX_HOST_CONF_PATH)"
    read -rp "Использовать этот конфиг? [Y/n]: " use_existing
    if [[ "${use_existing:-Y}" =~ ^[Nn] ]]; then
      rm -f "$CONFIG_FILE"
    else
      # Контейнеры могли пересоздаться под теми же именами - просто
      # проверяем, что они всё ещё существуют и запущены.
      ensure_containers
      return
    fi
  fi

  hr
  echo -e "${BOLD}Первичная настройка${NC}"
  hr

  log "Ищу контейнер nginx..."
  NGINX_CONTAINER=$(detect_nginx_container)
  ok "Контейнер nginx: ${NGINX_CONTAINER}"

  log "Ищу контейнер ноды Remnawave..."
  NODE_CONTAINER=$(detect_node_container)
  ok "Контейнер ноды: ${NODE_CONTAINER}"

  # Дефолты - без вопросов, как и попросили. При необходимости можно
  # переопределить переменными окружения перед запуском скрипта:
  #   XRAY_PATH=/mypath XRAY_PORT=20000 INBOUND_TAG=MY_TAG sudo -E bash setup-yandex-cdn.sh
  XRAY_PATH="${XRAY_PATH:-/yandexpath}"
  XRAY_PORT="${XRAY_PORT:-10088}"
  INBOUND_TAG="${INBOUND_TAG:-VLESS_XHTTP_YANDEX}"
  ok "Путь xhttp-инбаунда: ${XRAY_PATH}"
  ok "Порт xhttp-инбаунда: ${XRAY_PORT}"
  ok "Тег инбаунда: ${INBOUND_TAG}"

  read -rp "Домен-источник (origin, там уже стоит nginx+сертификат) [nl.example.com]: " ORIGIN_DOMAIN
  read -rp "Домен раздачи Yandex CDN (CNAME на *.yccdn.cloud.yandex.net) [cdn.example.com]: " CDN_DOMAIN
  read -rp "Email для Let's Encrypt: " LE_EMAIL

  [ -z "$ORIGIN_DOMAIN" ] && { err "Домен-источник не может быть пустым"; exit 1; }
  [ -z "$CDN_DOMAIN" ] && { err "Домен CDN не может быть пустым"; exit 1; }
  [ -z "$LE_EMAIL" ] && { err "Email обязателен для Let's Encrypt"; exit 1; }

  log "Ищу существующий конфиг nginx с server_name ${ORIGIN_DOMAIN}..."
  if NGINX_CONF_PATH=$(detect_nginx_conf_file); then
    ok "Найден конфиг (внутри контейнера): ${NGINX_CONF_PATH}"
  else
    warn "Не удалось автоматически найти файл с server_name ${ORIGIN_DOMAIN}."
    echo "Список всех конфиг-файлов, которые видит nginx в контейнере:"
    docker exec "$NGINX_CONTAINER" nginx -T 2>/dev/null | grep "^# configuration file" | sed 's/^/  /'
    read -rp "Укажи путь к нужному файлу внутри контейнера вручную: " NGINX_CONF_PATH
    [ -z "$NGINX_CONF_PATH" ] && { err "Путь к конфигу nginx обязателен"; exit 1; }
  fi

  log "Ищу реальный путь этого файла на хосте (через docker inspect mounts)..."
  if NGINX_HOST_CONF_PATH=$(detect_host_nginx_conf_path); then
    ok "Найден путь на хосте: ${NGINX_HOST_CONF_PATH}"
  else
    warn "Не удалось автоматически сопоставить путь на хосте (нет подходящего bind-mount)."
    read -rp "Укажи путь к этому же файлу на ХОСТЕ вручную: " NGINX_HOST_CONF_PATH
    [ -z "$NGINX_HOST_CONF_PATH" ] && { err "Путь к конфигу nginx на хосте обязателен"; exit 1; }
  fi
  if [ ! -f "$NGINX_HOST_CONF_PATH" ]; then
    err "Файл ${NGINX_HOST_CONF_PATH} не найден на хосте. Проверь путь и перезапусти скрипт."
    exit 1
  fi

  cat > "$CONFIG_FILE" <<EOF
ORIGIN_DOMAIN="$ORIGIN_DOMAIN"
CDN_DOMAIN="$CDN_DOMAIN"
XRAY_PATH="$XRAY_PATH"
XRAY_PORT="$XRAY_PORT"
LE_EMAIL="$LE_EMAIL"
NGINX_CONTAINER="$NGINX_CONTAINER"
NODE_CONTAINER="$NODE_CONTAINER"
NGINX_CONF_PATH="$NGINX_CONF_PATH"
NGINX_HOST_CONF_PATH="$NGINX_HOST_CONF_PATH"
INBOUND_TAG="$INBOUND_TAG"
STAGING="${STAGING:-false}"
EOF
  ok "Конфиг сохранён в $CONFIG_FILE"
}

ensure_containers() {
  log "Проверка Docker-контейнеров..."
  for c in "$NGINX_CONTAINER" "$NODE_CONTAINER"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      err "Контейнер '$c' не найден среди запущенных (docker ps)."
      err "Удали $CONFIG_FILE и перезапусти скрипт для повторного автообнаружения,"
      err "либо поправь NGINX_CONTAINER/NODE_CONTAINER в $CONFIG_FILE вручную."
      exit 1
    fi
  done
  ok "Контейнеры $NGINX_CONTAINER и $NODE_CONTAINER запущены"
}

# ============================================================
# 2. Хуки certbot для DNS-01 (без интерактивного certbot,
#    подходит и для ручного запуска, и для cron)
# ============================================================
write_certbot_hooks() {
  cat > "${HOOK_DIR}/dns-auth-hook.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
RECORD_NAME="_acme-challenge.${CERTBOT_DOMAIN}"
LOG="/var/log/yandex-cdn-vpn/certbot-hook.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

echo "===================================================================="
echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') — требуется DNS TXT запись"
echo "  Имя:      ${RECORD_NAME}"
echo "  Значение: ${CERTBOT_VALIDATION}"
echo "===================================================================="

# Дублируем в stderr, чтобы было видно и в интерактивном запуске
{
  echo ""
  echo ">>> Добавь в DNS TXT-запись:"
  echo ">>>   Имя:      ${RECORD_NAME}"
  echo ">>>   Значение: ${CERTBOT_VALIDATION}"
  echo ">>> Жду до 30 минут, пока запись распространится по DNS..."
} 1>&2

MAX_WAIT=1800
INTERVAL=15
ELAPSED=0
RESOLVERS=("8.8.8.8" "1.1.1.1" "9.9.9.9")

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  all_ok=true
  for r in "${RESOLVERS[@]}"; do
    val=$(dig +short TXT "${RECORD_NAME}" "@${r}" 2>/dev/null | tr -d '"' | head -n1)
    if [ "$val" != "${CERTBOT_VALIDATION}" ]; then
      all_ok=false
      break
    fi
  done
  if [ "$all_ok" = true ]; then
    echo "Запись подтверждена всеми резолверами (${RESOLVERS[*]}). Пауза 20с для стабильности." 1>&2
    echo "Запись подтверждена, продолжаю." >> "$LOG"
    sleep 20
    exit 0
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  echo "  ...жду DNS ($ELAPSED/${MAX_WAIT}s)" 1>&2
done

echo "ОШИБКА: TXT-запись не распространилась за отведённое время." 1>&2
echo "ОШИБКА: таймаут ожидания DNS" >> "$LOG"
exit 1
HOOK

  cat > "${HOOK_DIR}/dns-cleanup-hook.sh" <<'HOOK'
#!/usr/bin/env bash
# Запись можно оставить в DNS - она не мешает, certbot просто перезапишет
# значение при следующем продлении. Хук оставлен для совместимости с
# --manual-cleanup-hook и на случай, если захочешь чистить запись сам.
exit 0
HOOK

  chmod +x "${HOOK_DIR}/dns-auth-hook.sh" "${HOOK_DIR}/dns-cleanup-hook.sh"
  ok "Хуки certbot записаны в $HOOK_DIR"
}

# ============================================================
# 3. Разбивка сертификата на leaf/chain (для Yandex Certificate Manager)
# ============================================================
write_split_cert_script() {
  cat > "${BIN_DIR}/split-cert.sh" <<'SPLIT'
#!/usr/bin/env bash
set -euo pipefail
source /etc/yandex-cdn-vpn/config.env

SRC="/etc/letsencrypt/live/${CDN_DOMAIN}/fullchain.pem"
OUT_DIR="/etc/yandex-cdn-vpn/certs-for-yandex"
mkdir -p "$OUT_DIR"

if [ ! -f "$SRC" ]; then
  echo "Сертификат не найден: $SRC" >&2
  exit 1
fi

awk '/BEGIN CERTIFICATE/{n++} n==1' "$SRC" > "${OUT_DIR}/leaf_only.pem"
awk '/BEGIN CERTIFICATE/{n++} n>1'  "$SRC" > "${OUT_DIR}/chain_combined.pem"
cp "/etc/letsencrypt/live/${CDN_DOMAIN}/privkey.pem" "${OUT_DIR}/privkey.pem"

echo "Готово. Файлы для загрузки в Yandex Certificate Manager:"
echo "  Сертификат (leaf):     ${OUT_DIR}/leaf_only.pem"
echo "  Цепочка (chain):       ${OUT_DIR}/chain_combined.pem"
echo "  Приватный ключ:        ${OUT_DIR}/privkey.pem"
SPLIT
  chmod +x "${BIN_DIR}/split-cert.sh"
}

# ============================================================
# 4. Выпуск сертификата (если ещё нет / истекает)
# ============================================================
ensure_certificate() {
  local cert_file="/etc/letsencrypt/live/${CDN_DOMAIN}/fullchain.pem"

  if [ -f "$cert_file" ] && openssl x509 -checkend 1209600 -noout -in "$cert_file" >/dev/null 2>&1; then
    ok "Сертификат для ${CDN_DOMAIN} уже есть и действителен ещё больше 14 дней — пропускаю выпуск"
    "${BIN_DIR}/split-cert.sh"
    return
  fi

  hr
  log "Выпуск сертификата для ${CDN_DOMAIN} (RSA, цепочка до ISRG Root X1)"
  if [ "${STAGING:-false}" = "true" ]; then
    warn "РЕЖИМ STAGING — сертификат будет тестовым (недоверенным), не тратит лимиты Let's Encrypt"
  fi
  warn "Сейчас потребуется добавить DNS TXT-запись вручную — следи за выводом."
  hr

  local staging_flag=""
  [ "${STAGING:-false}" = "true" ] && staging_flag="--staging"

  if certbot certonly \
      --manual \
      --manual-auth-hook "${HOOK_DIR}/dns-auth-hook.sh" \
      --manual-cleanup-hook "${HOOK_DIR}/dns-cleanup-hook.sh" \
      --preferred-challenges dns \
      -d "${CDN_DOMAIN}" \
      --email "${LE_EMAIL}" --agree-tos \
      --key-type rsa \
      --preferred-chain "ISRG Root X1" \
      --non-interactive \
      ${staging_flag} \
      --force-renewal 2>&1 | tee -a "${LOG_DIR}/certbot.log"; then
    ok "Сертификат выпущен"
  else
    err "Не удалось выпустить сертификат. Смотри ${LOG_DIR}/certbot.log и /var/log/letsencrypt/letsencrypt.log"
    exit 1
  fi

  if [ "${STAGING:-false}" = "true" ]; then
    warn "Это STAGING-сертификат — он не будет валидным в браузерах/клиентах."
    warn "Проверять им ALPN/nginx/CDN-цепочку можно, но не для реального использования."
  else
    # Проверка что цепочка ведёт к ISRG Root X1 (только для боевых сертификатов)
    if openssl crl2pkcs7 -nocrl -certfile "$cert_file" 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null | grep -q "ISRG Root X1"; then
      ok "Цепочка ведёт к ISRG Root X1 (повсеместно доверенный корень)"
    else
      warn "Цепочка не содержит ISRG Root X1 — проверь вручную, возможен конфликт с доверием у части клиентов"
    fi
  fi

  "${BIN_DIR}/split-cert.sh"
}

print_yandex_upload_instructions() {
  hr
  echo -e "${BOLD}Загрузка сертификата в Yandex Certificate Manager${NC}"
  hr
  cat <<EOF
Открой в консоли Yandex Cloud:
  Certificate Manager -> Создать сертификат -> Загруженный

Дальше пройдём по трём полям формы пошагово — каждое покажу отдельно,
скопируешь и вставишь, потом жмёшь Enter здесь, чтобы идти дальше.

ВАЖНО: если сертификат для этого домена уже есть в Certificate Manager
(например, при продлении) — создавай НОВЫЙ объект, а не редактируй
старый. Редактирование существующего Imported-сертификата в Yandex CDN
на практике часто не подхватывается на edge-нодах.
EOF
  read -rp "Нажми Enter, когда откроешь форму создания сертификата... " _

  # --- Шаг 1: leaf ---
  hr
  echo -e "${BOLD}Шаг 1 из 3 — поле «Сертификат»${NC}"
  hr
  echo "Скопируй всё целиком (включая BEGIN/END CERTIFICATE) и вставь в поле «Сертификат»:"
  echo
  cat "${CERTS_OUT_DIR}/leaf_only.pem"
  echo
  read -rp "Вставил в поле «Сертификат»? Нажми Enter для продолжения... " _

  # --- Шаг 2: chain ---
  hr
  echo -e "${BOLD}Шаг 2 из 3 — поле «Цепочка»${NC}"
  hr
  echo "Скопируй всё целиком и вставь в поле «Цепочка»:"
  echo
  cat "${CERTS_OUT_DIR}/chain_combined.pem"
  echo
  read -rp "Вставил в поле «Цепочка»? Нажми Enter для продолжения... " _

  # --- Шаг 3: privkey ---
  hr
  echo -e "${BOLD}Шаг 3 из 3 — поле «Приватный ключ»${NC}"
  hr
  warn "Дальше на экран будет выведен приватный ключ. Убедись, что рядом"
  warn "никто не подглядывает и терминал не логируется в общий чат/скринкаст."
  read -rp "Показать приватный ключ? [Y/n]: " show_key
  if [[ "${show_key:-Y}" =~ ^[Nn] ]]; then
    log "Пропущено. Возьми ключ из файла вручную: ${CERTS_OUT_DIR}/privkey.pem"
  else
    echo "Скопируй всё целиком и вставь в поле «Приватный ключ»:"
    echo
    cat "${CERTS_OUT_DIR}/privkey.pem"
    echo
  fi
  read -rp "Вставил в поле «Приватный ключ»? Нажми Enter для продолжения... " _

  # --- Шаг 4: сохранение сертификата ---
  hr
  echo -e "${BOLD}Шаг 4 — сохранение${NC}"
  hr
  echo "Нажми «Создать» в форме Certificate Manager и дождись статуса Issued."
  read -rp "Сертификат создан и в статусе Issued? Нажми Enter для продолжения... " _

  # --- Шаг 5: привязка к CDN-ресурсу ---
  hr
  echo -e "${BOLD}Шаг 5 — привязка к CDN-ресурсу${NC}"
  hr
  cat <<EOF
Теперь в настройках CDN-ресурса:
  "Тип сертификата" -> Certificate Manager -> выбери только что созданный
  сертификат -> Сохрани.

Учти: раскатка на edge-ноды CDN не мгновенная, может занять от 10 минут
до часа. После этого шага скрипт прогонит диагностику автоматически —
если увидишь 502 или ошибку сертификата, это может быть просто ещё не
завершённая раскатка, не обязательно ошибка настройки.
EOF
  read -rp "Привязал сертификат к CDN-ресурсу и сохранил? Нажми Enter для продолжения... " _

  ok "Все шаги загрузки сертификата пройдены"
  log "Файлы также остаются здесь: ${CERTS_OUT_DIR}/"
}

# ============================================================
# 5. Настройка nginx
# ============================================================
configure_nginx() {
  hr
  log "Настройка nginx: location ${XRAY_PATH} -> 127.0.0.1:${XRAY_PORT}"
  log "Файл конфига на хосте: ${NGINX_HOST_CONF_PATH}"
  log "(внутри контейнера ${NGINX_CONTAINER} виден как: ${NGINX_CONF_PATH})"
  hr

  if [ ! -f "$NGINX_HOST_CONF_PATH" ]; then
    err "Файл ${NGINX_HOST_CONF_PATH} не найден на хосте."
    err "Проверь NGINX_HOST_CONF_PATH в $CONFIG_FILE и перезапусти скрипт."
    exit 1
  fi

  if grep -qF "location ${XRAY_PATH}" "$NGINX_HOST_CONF_PATH"; then
    warn "location ${XRAY_PATH} уже есть в конфиге nginx — пропускаю добавление"
    return
  fi

  # Бэкап оригинального файла перед любыми правками - на случай отката
  local backup_dir="${CONFIG_DIR}/backups"
  mkdir -p "$backup_dir"
  local backup_file="${backup_dir}/$(basename "$NGINX_HOST_CONF_PATH").$(date +%Y%m%d%H%M%S).bak"
  cp "$NGINX_HOST_CONF_PATH" "$backup_file"
  ok "Бэкап оригинального конфига сохранён: $backup_file"

  local new_conf
  new_conf=$(mktemp)
  awk -v path="$XRAY_PATH" -v port="$XRAY_PORT" -v origin="$ORIGIN_DOMAIN" '
    BEGIN { in_block=0; inserted=0 }
    {
      if ($0 ~ /server_name/ && index($0, origin) > 0) { in_block=1 }
      if (in_block && $0 ~ /^}/ && !inserted) {
        print "    location " path " {"
        print "        proxy_pass http://127.0.0.1:" port ";"
        print "        proxy_http_version 1.1;"
        print "        proxy_set_header Host $host;"
        print "        proxy_set_header X-Real-IP $remote_addr;"
        print "        proxy_read_timeout 3600s;"
        print "        proxy_send_timeout 3600s;"
        print "    }"
        inserted=1
        in_block=0
      }
      print
    }
  ' "$NGINX_HOST_CONF_PATH" > "$new_conf"

  if ! grep -qF "location ${XRAY_PATH}" "$new_conf"; then
    err "Не удалось автоматически найти server-блок для ${ORIGIN_DOMAIN} в конфиге nginx."
    err "Добавь location вручную в ${NGINX_HOST_CONF_PATH} (пример ниже) и перезапусти скрипт (он пропустит этот шаг)."
    cat <<EOF
    location ${XRAY_PATH} {
        proxy_pass http://127.0.0.1:${XRAY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
EOF
    rm -f "$new_conf"
    return
  fi

  echo "Планируемые изменения (diff):"
  diff -u "$NGINX_HOST_CONF_PATH" "$new_conf" || true
  read -rp "Применить эти изменения к ${NGINX_HOST_CONF_PATH} и перезапустить ${NGINX_CONTAINER}? [Y/n]: " apply
  if [[ "${apply:-Y}" =~ ^[Nn] ]]; then
    warn "Изменения nginx отменены пользователем"
    rm -f "$new_conf"
    return
  fi

  # Редактируем файл ПРЯМО НА ХОСТЕ (не через docker cp/exec в контейнер) -
  # конфиг обычно смонтирован в контейнер как read-only bind-mount, писать
  # в него изнутри контейнера нельзя ("Read-only file system"). Меняем
  # исходник на хосте, затем перезапускаем контейнер, чтобы он подхватил
  # новый файл.
  cp "$new_conf" "$NGINX_HOST_CONF_PATH"
  rm -f "$new_conf"

  log "Проверка синтаксиса перед перезапуском (nginx -t)..."
  if docker exec "$NGINX_CONTAINER" nginx -t; then
    run_with_spinner "Перезапуск контейнера ${NGINX_CONTAINER}..." docker restart "$NGINX_CONTAINER"
    sleep 1
    if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
      ok "nginx настроен, контейнер перезапущен и работает"
    else
      err "Контейнер ${NGINX_CONTAINER} не поднялся после перезапуска — откатываю конфиг"
      cp "$backup_file" "$NGINX_HOST_CONF_PATH"
      docker restart "$NGINX_CONTAINER" >/dev/null 2>&1 || true
      err "Конфиг откачен. Разбирайся вручную: docker logs ${NGINX_CONTAINER}"
      exit 1
    fi
  else
    err "nginx -t вернул ошибку синтаксиса — откатываю конфиг из бэкапа (контейнер не трогаю)"
    cp "$backup_file" "$NGINX_HOST_CONF_PATH"
    if docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1; then
      warn "Конфиг откачен к оригиналу, контейнер продолжает работать со старым конфигом (не перезапускался)"
      err "Правки не применились. Файл для ручного разбора: $backup_file"
    else
      err "КРИТИЧНО: даже оригинальный (откаченный) конфиг не проходит nginx -t."
      err "Возможно, backup тоже повреждён. Разбирайся вручную: $backup_file"
    fi
    exit 1
  fi
}

# ============================================================
# 6. Cron-задача автопродления
# ============================================================
write_renew_script() {
  cat > "${BIN_DIR}/renew-cert.sh" <<'RENEW'
#!/usr/bin/env bash
set -euo pipefail
source /etc/yandex-cdn-vpn/config.env
LOG="/var/log/yandex-cdn-vpn/renew.log"
exec >> "$LOG" 2>&1

echo "=== $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="

CERT_FILE="/etc/letsencrypt/live/${CDN_DOMAIN}/fullchain.pem"
if [ ! -f "$CERT_FILE" ]; then
  echo "Сертификат не найден ($CERT_FILE) - похоже, первичная настройка не завершена."
  exit 0
fi

if openssl x509 -checkend 1209600 -noout -in "$CERT_FILE"; then
  echo "Сертификат действителен ещё более 14 дней - продление не требуется."
  exit 0
fi

echo "До истечения сертификата осталось <14 дней. Запускаю продление..."

staging_flag=""
[ "${STAGING:-false}" = "true" ] && staging_flag="--staging"

if certbot certonly \
    --manual \
    --manual-auth-hook /etc/yandex-cdn-vpn/hooks/dns-auth-hook.sh \
    --manual-cleanup-hook /etc/yandex-cdn-vpn/hooks/dns-cleanup-hook.sh \
    --preferred-challenges dns \
    -d "${CDN_DOMAIN}" \
    --email "${LE_EMAIL}" --agree-tos \
    --key-type rsa \
    --preferred-chain "ISRG Root X1" \
    --non-interactive \
    ${staging_flag} \
    --force-renewal; then
  echo "Сертификат успешно продлён."
  /etc/yandex-cdn-vpn/bin/split-cert.sh
  echo "!!! НЕ ЗАБУДЬ вручную загрузить НОВЫЙ сертификат в Yandex Certificate Manager"
  echo "!!! и привязать его к CDN-ресурсу (создай НОВЫЙ объект, не редактируй старый)."
  echo "!!! Файлы лежат в /etc/yandex-cdn-vpn/certs-for-yandex/"
else
  echo "ОШИБКА при продлении сертификата. Смотри /var/log/letsencrypt/letsencrypt.log"
  exit 1
fi
RENEW
  chmod +x "${BIN_DIR}/renew-cert.sh"
}

setup_cron() {
  hr
  log "Установка cron-задачи автопродления (ежедневная проверка в 04:00 UTC)"
  local cron_cmd="${BIN_DIR}/renew-cert.sh"
  local cron_line="0 4 * * * ${cron_cmd} >> ${LOG_DIR}/cron.log 2>&1"

  if crontab -l 2>/dev/null | grep -qF "$cron_cmd"; then
    warn "Cron-задача уже установлена, пропускаю"
  else
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    ok "Cron-задача добавлена: $cron_line"
  fi

  warn "ВАЖНО: certbot использует ручной DNS-01 challenge. Cron-задача сама"
  warn "проверит срок действия и попытается продлить, но ей всё равно нужно,"
  warn "чтобы кто-то добавил новую TXT-запись в DNS в течение 30 минут после"
  warn "запуска — иначе продление уходит в таймаут. Проверяй ${LOG_DIR}/renew.log"
  warn "не реже раза в 2 недели, начиная примерно за месяц до истечения."
}

# ============================================================
# 7. Вывод конфигов для Remnawave (инбаунд + host)
# ============================================================
print_xray_inbound() {
  local out_file="${CONFIG_DIR}/xray-inbound-${INBOUND_TAG}.json"
  cat > "$out_file" <<EOF
{
  "tag": "${INBOUND_TAG}",
  "listen": "0.0.0.0",
  "port": ${XRAY_PORT},
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": {
      "mode": "packet-up",
      "path": "${XRAY_PATH}",
      "extra": {
        "headers": {
          "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        },
        "uplinkHTTPMethod": "GET",
        "xPaddingBytes": "100-1000",
        "xPaddingObfsMode": true,
        "xPaddingMethod": "tokenish",
        "XPaddingKey": "trace_id",
        "XPaddingHeader": "X-Trace-Id",
        "XPaddingPlacement": "queryInHeader",
        "noSSEHeader": true,
        "xmux": {
          "maxConcurrency": "16-32",
          "cMaxReuseTimes": "64-128",
          "hMaxRequestTimes": "600-900",
          "hMaxReusableSecs": "1800-3000",
          "hKeepAlivePeriod": 0
        }
      }
    }
  }
}
EOF
  hr
  echo -e "${BOLD}Конфиг инбаунда Xray -> Remnawave / Config Profiles / Inbounds${NC}"
  hr
  cat "$out_file"
  echo
  log "Сохранено в: $out_file"
  echo
  warn "После вставки этого JSON в Config Profile — этого НЕДОСТАТОЧНО."
  warn "Нужно ещё зайти в Nodes -> твоя нода -> ВКЛЮЧИТЬ этот инбаунд"
  warn "отдельным переключателем прямо на самой ноде, и только потом Restart Node."
}

print_remnawave_host() {
  local out_file="${CONFIG_DIR}/remnawave-host-extra.json"
  cat > "$out_file" <<EOF
{
  "headers": {
    "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
  },
  "uplinkHTTPMethod": "GET",
  "xPaddingBytes": "100-1000",
  "xPaddingObfsMode": true,
  "xPaddingMethod": "tokenish",
  "XPaddingKey": "trace_id",
  "XPaddingHeader": "X-Trace-Id",
  "XPaddingPlacement": "queryInHeader",
  "noSSEHeader": true,
  "xmux": {
    "maxConcurrency": "16-32",
    "cMaxReuseTimes": "64-128",
    "hMaxRequestTimes": "600-900",
    "hMaxReusableSecs": "1800-3000",
    "hKeepAlivePeriod": 0
  }
}
EOF
  hr
  echo -e "${BOLD}Настройки Host в Remnawave (Nodes/Hosts -> Add Host)${NC}"
  hr
  cat <<EOF
  Address     : ${CDN_DOMAIN}
  Port        : 443
  SNI         : ${CDN_DOMAIN}
  Host        : ${CDN_DOMAIN}
  Path        : ${XRAY_PATH}
  Network     : xhttp
  Mode        : packet-up
  Security    : tls
  ALPN        : h2      <-- ОБЯЗАТЕЛЬНО h2, не http/1.1! Yandex CDN всегда
                           отвечает по HTTP/2, иначе клиент не сможет
                           распарсить ответ и туннель не заработает.
  Fingerprint : chrome
  Extra       : см. файл ниже
EOF
  echo
  cat "$out_file"
  echo
  log "Сохранено в: $out_file"
}

# ============================================================
# 8. Диагностика
# ============================================================
run_diagnostics() {
  hr
  echo -e "${BOLD}ДИАГНОСТИКА${NC}"
  hr

  log "1) Слушает ли инбаунд порт ${XRAY_PORT} на хосте"
  if ss -tlnp 2>/dev/null | grep -q ":${XRAY_PORT}"; then
    ok "Порт ${XRAY_PORT} слушается"
  else
    err "Порт ${XRAY_PORT} НЕ слушается. Проверь, что инбаунд ${INBOUND_TAG}"
    err "добавлен в Config Profile, ВКЛЮЧЁН на самой ноде, и сделан Restart Node."
  fi
  beat 1

  log "2) Прямой запрос к инбаунду (127.0.0.1:${XRAY_PORT})"
  code=$(curl -s -o /dev/null -w "%{http_code}" --http1.1 --max-time 5 "http://127.0.0.1:${XRAY_PORT}${XRAY_PATH}" 2>/dev/null)
  [ -z "$code" ] && code="000"
  if [ "$code" = "404" ]; then ok "Код ответа: 404 (ожидаемо для Xray без валидной сессии)"; else warn "Код ответа: $code (ожидался 404)"; fi
  beat 1

  log "3) Через nginx, в обход CDN (https://${ORIGIN_DOMAIN}${XRAY_PATH})"
  code=$(curl -s -o /dev/null -w "%{http_code}" --http1.1 --max-time 5 "https://${ORIGIN_DOMAIN}${XRAY_PATH}" 2>/dev/null)
  [ -z "$code" ] && code="000"
  if [ "$code" = "404" ]; then ok "Код ответа: 404"; else warn "Код ответа: $code — проверь nginx location и сертификат origin"; fi
  beat 1

  log "4) Через Yandex CDN (https://${CDN_DOMAIN}${XRAY_PATH})"
  code=$(curl -s -o /dev/null -w "%{http_code}" --http1.1 --max-time 5 "https://${CDN_DOMAIN}${XRAY_PATH}" 2>/dev/null)
  [ -z "$code" ] && code="000"
  case "$code" in
    404) ok "Код ответа: 404" ;;
    502) warn "Код ответа: 502 — возможно, раскатка настроек CDN на edge-нодах ещё не завершена (может занять до часа)" ;;
    000) warn "Нет ответа/таймаут — проверь DNS (CNAME на CDN) и доступность" ;;
    *)   warn "Код ответа: $code" ;;
  esac
  beat 1

  log "5) HTTP/2 на CDN (обязательно для ALPN=h2 на клиенте)"
  if curl -s --http2-prior-knowledge --max-time 5 -o /dev/null "https://${CDN_DOMAIN}${XRAY_PATH}" 2>/dev/null; then
    ok "CDN отвечает по HTTP/2"
  else
    warn "Не удалось подтвердить HTTP/2 (может быть нормально, если сеть недоступна из этой точки)"
  fi
  beat 1

  log "6) Цепочка TLS-сертификата на CDN"
  verify=$(openssl s_client -connect "${CDN_DOMAIN}:443" -servername "${CDN_DOMAIN}" </dev/null 2>&1 | grep "Verify return code" || true)
  echo "   $verify"
  if echo "$verify" | grep -q "0 (ok)"; then
    ok "Сертификат валиден, цепочка полная"
  else
    warn "Проблема с цепочкой сертификата. Частые причины:"
    warn "  - сертификат ещё не раскатился по всем edge-нодам (подожди и проверь снова)"
    warn "  - цепочка собрана неправильно (leaf/chain перепутаны местами)"
  fi
  beat 1

  log "7) Docker-контейнеры"
  docker ps --filter "name=${NGINX_CONTAINER}" --format "   {{.Names}}: {{.Status}}"
  docker ps --filter "name=${NODE_CONTAINER}" --format "   {{.Names}}: {{.Status}}"
  beat 1

  log "8) Срок действия сертификата"
  if [ -f "/etc/letsencrypt/live/${CDN_DOMAIN}/fullchain.pem" ]; then
    enddate=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${CDN_DOMAIN}/fullchain.pem" | cut -d= -f2)
    echo "   Действителен до: $enddate"
  else
    warn "   Сертификат не найден локально"
  fi

  hr
  log "Для сквозного теста реального VLESS-туннеля используй xray run + curl --socks5"
  log "(см. README, раздел 'Полный сквозной тест')"
  hr
}

# ============================================================
# main
# ============================================================
main() {
  require_root
  banner
  beat
  step "Загрузка/запрос конфигурации"
  load_or_ask_config
  beat
  step "Проверка зависимостей и контейнеров"
  check_prereqs
  ensure_containers
  beat
  step "Подготовка хуков и вспомогательных скриптов"
  write_certbot_hooks
  write_split_cert_script
  write_renew_script
  ok "Хуки и вспомогательные скрипты готовы"
  beat
  step "Выпуск сертификата (Let's Encrypt, DNS-01)"
  ensure_certificate
  beat
  step "Загрузка сертификата в Yandex Certificate Manager"
  print_yandex_upload_instructions
  beat
  step "Настройка nginx"
  configure_nginx
  beat
  step "Установка cron-задачи автопродления"
  setup_cron
  beat 3
  step "Конфиги для Remnawave"
  print_xray_inbound
  read -rp "Скопировал JSON инбаунда в Config Profile? Нажми Enter для продолжения... " _
  print_remnawave_host
  read -rp "Заполнил Host по таблице выше? Нажми Enter для продолжения... " _

  hr
  echo -e "${YELLOW}${BOLD}  ⚠ ВАЖНО — последний ручной шаг, без него ничего не заработает${NC}"
  hr
  cat <<'EOF'
  1. В Remnawave -> Nodes -> открой свою ноду.
  2. Убедись, что у ноды ВКЛЮЧЕН (галочка/тумблер) только что добавленный
     инбаунд - одного добавления в Config Profile НЕДОСТАТОЧНО, инбаунд
     нужно отдельно включить именно на самой ноде.
  3. Сделай Restart Node.
  4. Только после этого порт начнёт слушаться и диагностика ниже пройдёт.
EOF
  hr
  read -rp "Включил инбаунд на ноде и сделал Restart Node? Нажми Enter для продолжения... " _
  beat 2

  step "Диагностика"
  run_diagnostics

  echo
  hr
  echo -e "${GREEN}${BOLD}  ✔ ГОТОВО${NC} — ZADODRALKA CDN настроен и проверен"
  hr
  log "Конфиги для Remnawave сохранены в: ${CONFIG_DIR}"
  log "Логи: ${LOG_DIR}"
  log "Повторный запуск диагностики: bash $0 --diagnose-only"
  hr
}

if [ "${1:-}" = "--diagnose-only" ]; then
  require_root
  banner
  load_or_ask_config
  run_diagnostics
elif [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # Запущен напрямую (не через `source`) - выполняем полную настройку.
  main "$@"
else
  # Скрипт подключён через `source setup-yandex-cdn.sh` - main() не
  # запускается автоматически. Это специально для тестирования: можно
  # вызывать отдельные функции руками из интерактивного bash, например:
  #   source setup-yandex-cdn.sh
  #   detect_nginx_container
  #   ORIGIN_DOMAIN=test.example.com NGINX_CONTAINER=test-nginx detect_nginx_conf_file
  :
fi
