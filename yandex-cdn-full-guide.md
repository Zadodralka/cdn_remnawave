# VLESS + XHTTP через Yandex Cloud CDN (nginx) для Remnawave

Схема проксирования VLESS/XHTTP-трафика через Yandex CDN с прохождением через **nginx** и усиленной обфускацией трафика. В отличие от схемы с МТС CDN (mwscdn.ru), здесь nginx остаётся в цепочке как обычный reverse-proxy, потому что Yandex CDN по умолчанию не блокирует нужные HTTP-методы так жёстко, как МТС.

## Архитектура

```
Клиент (happ/v2rayNG/xray)
    │  TLS SNI = домен раздачи CDN (cdn.example.com)
    │  ALPN = h2 (ОБЯЗАТЕЛЬНО — Yandex CDN всегда отвечает HTTP/2)
    ▼
Yandex Cloud CDN (edge, anycast, множество нод по всему миру)
    │  HTTPS, Host = origin-домен (nl.example.com)
    │  SNI к источнику = origin-домен
    │  origin: https://nl.example.com:443
    ▼
nginx (на вашем сервере, слушает 443, сертификат Let's Encrypt на origin-домен)
    │  location /yourpath → proxy_pass на 127.0.0.1:порт
    ▼
Xray inbound (VLESS + xhttp, mode packet-up, security: none — TLS терминирован в nginx)
```

---

## 1. Предварительные требования

- Домен-**источник** (origin) с уже выпущенным сертификатом Let's Encrypt и настроенным nginx как reverse-proxy к Xray (в гайде — `nl.example.com`).
- **Отдельный** домен/поддомен для раздачи CDN (в гайде — `cdn.example.com`) — не может совпадать с origin-доменом.
- Аккаунт в Yandex Cloud с доступом к Cloud CDN и Certificate Manager.
- `certbot`, установленный на сервере.
- Remnawave с уже работающей нодой (`remnanode`) и nginx-контейнером (`remnawave-nginx`).

---

## 2. Создание CDN-ресурса в Yandex Cloud

Консоль Yandex Cloud → Cloud CDN → «Создать ресурс»:

| Поле | Значение |
|---|---|
| Доступ к контенту | Включить |
| Запрос контента | С одного источника |
| Тип источника | Собственный сервер / по доменному имени |
| Доменное имя источника | `nl.example.com` |
| Протокол для источников | **HTTPS** |
| Задать SNI вручную | Включить, значение `nl.example.com` |
| Заголовок Host | Своё значение → `nl.example.com` |
| Доменное имя (раздача) | `cdn.example.com` (**отдельный** от origin домен) |

### Кэширование — выключить всё

| Поле | Значение |
|---|---|
| Время жизни кеша по умолчанию | 0 / не кэшировать |
| Кеширование в браузере | Выключено |
| Кеширование query-параметров | Игнорировать все |
| Игнорировать файлы cookie | Включить |
| gzip-сжатие | Выключено |
| Сегментация больших файлов | Выключено |

### Прочие настройки

| Поле | Значение |
|---|---|
| Перенаправление запросов | Не использовать |
| Следование перенаправлениям от источника | Выключено |
| Переадресация клиентов | Не использовать |
| Доступ по защищённому токену | Выключено |
| Доступ по IP-адресам | Выключено (без ограничений) |
| Разрешённые методы | GET, HEAD, OPTIONS |
| CORS | Не использовать |

После создания Yandex выдаст CNAME-цель вида `xxxxxxxxxxxxxxxx.a.yccdn.cloud.yandex.net`:
```
Тип:      CNAME
Имя:      cdn
Значение: xxxxxxxxxxxxxxxx.a.yccdn.cloud.yandex.net.
```
Пропишите в DNS для домена раздачи.

---

## 3. Сертификат для домена раздачи CDN

### ⚠️ Критично важно

- Дефолтный ECDSA-сертификат Let's Encrypt сейчас выдаёт цепочку через новые корни (`Root YE`), которые ещё не входят во все системные доверенные хранилища → строгие клиенты дают `unable to get local issuer certificate`.
- **Решение — RSA-ключ с явным запросом старой, повсеместно доверенной цепочки до `ISRG Root X1`.**

### Выпуск сертификата

```bash
certbot certonly --manual --preferred-challenges dns \
  -d cdn.example.com \
  --email you@email.com --agree-tos \
  --key-type rsa \
  --preferred-chain "ISRG Root X1"
```

Certbot покажет TXT-запись:
```
_acme-challenge.cdn.example.com.  →  <токен>
```

**Перед Enter в certbot** — добавьте TXT-запись в DNS и в отдельном терминале дождитесь полной синхронизации по всем NS вашего DNS-провайдера:
```bash
dig NS example.com +short
# для каждого полученного NS:
dig TXT _acme-challenge.cdn.example.com @<ns-сервер> +short
```
Только когда **все** NS отдают одинаковый и правильный ответ — возвращайтесь и жмите Enter.

### Проверка цепочки

```bash
openssl crl2pkcs7 -nocrl -certfile /etc/letsencrypt/live/cdn.example.com/fullchain.pem | openssl pkcs7 -print_certs -noout
```
В конце цепочки должен быть **`ISRG Root X1`** (не `Root YE`/`Root YR`).

### Разбивка на leaf + chain

Yandex Certificate Manager при импорте ожидает раздельно: leaf в одно поле, цепочку — в другое.

```bash
awk '/BEGIN CERTIFICATE/{n++} n==1' /etc/letsencrypt/live/cdn.example.com/fullchain.pem > /root/leaf_only.pem
awk '/BEGIN CERTIFICATE/{n++} n>1'  /etc/letsencrypt/live/cdn.example.com/fullchain.pem > /root/chain_combined.pem
```

Certificate Manager → «Создать сертификат» → **«Загруженный»**:
- «Сертификат» → содержимое `leaf_only.pem`
- «Цепочка» → содержимое `chain_combined.pem`
- «Приватный ключ» → содержимое `privkey.pem`

### ⚠️ Важное наблюдение

**Редактирование уже существующего Imported-сертификата не всегда приводит к тому, что CDN подхватывает обновлённую цепочку** — в тестах это стабильно приводило к тому, что edge продолжал отдавать только leaf. Рабочий способ — **создавать новый объект сертификата с нуля** (новое имя), а не править старый.

Привяжите сертификат к ресурсу: настройки ресурса → «Тип сертификата» → Certificate Manager → выбрать созданный сертификат.

### Раскатка — наберитесь терпения

Изменения не применяются мгновенно на все edge-ноды (anycast-инфраструктура). После любого изменения ожидайте от 10 минут до часа:

```bash
for i in $(seq 1 30); do
  N=$(openssl s_client -connect cdn.example.com:443 -servername cdn.example.com -showcerts </dev/null 2>/dev/null | grep -c "BEGIN CERTIFICATE")
  echo "$(date '+%H:%M:%S')  сертификатов в цепочке: $N"
  sleep 5
done
```
Дожидайтесь стабильных `2`+ (не `1`) несколько минут подряд.

Финальная проверка:
```bash
openssl s_client -connect cdn.example.com:443 -servername cdn.example.com </dev/null 2>&1 | grep "Verify return code"
```
Ожидаем `Verify return code: 0 (ok)`.

---

## 4. Инбаунд Xray с обфускацией

В Remnawave → Config Profiles → Inbounds:

```json
{
  "tag": "VLESS_XHTTP_YANDEX",
  "listen": "0.0.0.0",
  "port": 10088,
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
      "path": "/yourpath",
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
```

TLS здесь не нужен (`"security": "none"`) — шифрование терминируется в nginx.

### ⚠️ Обязательный параметр обфускации

`"xPaddingObfsMode": true` — **без него** движок игнорирует кастомные `XPaddingKey`/`XPaddingHeader`/`XPaddingPlacement` и продолжает использовать легаси-поведение по умолчанию (`?x_padding=XXXX...X` в URL, видимое в открытом виде в access.log). С этим флагом паддинг переезжает в кастомный заголовок и перестаёт светиться в логах/URL как узнаваемая сигнатура xhttp.

`"xPaddingMethod": "tokenish"` — паддинг выглядит как реалистичный токен вместо повторяющихся `X`.

---

## 5. nginx

Добавьте location в существующий server-блок (тот же, где уже настроен сертификат origin-домена):

```nginx
location /yourpath {
    proxy_pass http://127.0.0.1:10088;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

Перезагрузка (если nginx в контейнере Remnawave):
```bash
docker exec remnawave-nginx nginx -t
docker exec remnawave-nginx nginx -s reload
```

---

## 6. Host в Remnawave

| Поле | Значение |
|---|---|
| Address | `cdn.example.com` |
| Port | **443** (не 10088!) |
| SNI | `cdn.example.com` |
| Host | `cdn.example.com` |
| Path | `/yourpath` |
| Network | xhttp |
| Mode | packet-up |
| Security | tls |
| **ALPN** | **`h2`** |
| Fingerprint | chrome |
| Extra | (идентично серверному, см. ниже) |

### Extra в Host — должен точно совпадать с инбаундом

```json
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
```

### ⚠️ Критично важно — ALPN должен быть `h2`

**Yandex Cloud CDN всегда отвечает клиенту по HTTP/2**, независимо от того, что клиент предлагает через ALPN. Если у клиента выставлен только `http/1.1`, Xray-клиент пытается парсить HTTP/2-бинарный поток как HTTP/1.1 и падает с ошибкой:
```
malformed HTTP response "\x00\x00\x12\x04\x00\x00\x00\x00\x00\x00\x03..."
```

---

## 7. Проверка работоспособности

### 7.1. Напрямую на инбаунд, в обход nginx
```bash
curl -v --http1.1 http://127.0.0.1:10088/yourpath
```
Ожидаем `404 Not Found`.

### 7.2. Через nginx, в обход CDN
```bash
curl -v --http1.1 https://nl.example.com/yourpath
```
Ожидаем `404`.

### 7.3. Через сам Yandex CDN
```bash
curl -v --http1.1 https://cdn.example.com/yourpath
```
Ожидаем `404` с заголовками `server: nginx`, `cache-host: yccdn-...`.

Если видите `502` вперемешку с `404` — нормально во время раскатки настроек по edge-нодам. Мониторьте:
```bash
for i in $(seq 1 20); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --http1.1 https://cdn.example.com/yourpath)
  echo "$(date '+%H:%M:%S')  код: $CODE"
  sleep 5
done
```
Дожидайтесь стабильных `404`.

### 7.4. Подтвердить, что CDN отвечает по HTTP/2
```bash
curl -v --http2-prior-knowledge https://cdn.example.com/yourpath
```

### 7.5. Полный сквозной тест (реальный VLESS-туннель)

Установите тестовый xray:
```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

Тестовый клиентский конфиг:
```bash
cat <<'EOF' > /root/test-client.json
{
  "log": { "loglevel": "debug" },
  "inbounds": [
    { "port": 10800, "listen": "127.0.0.1", "protocol": "socks", "settings": { "auth": "noauth", "udp": true } }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "cdn.example.com",
            "port": 443,
            "users": [ { "id": "UUID_пользователя", "encryption": "none" } ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": { "serverName": "cdn.example.com", "alpn": ["h2"] },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "/yourpath",
          "extra": {
            "headers": { "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" },
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
  ]
}
EOF

xray run -c /root/test-client.json &
curl -v --socks5 127.0.0.1:10800 https://2ip.ru --max-time 15
pkill -f "xray run"
```
Если в ответе видите IP вашего сервера — туннель полностью рабочий, end-to-end.

---

## 8. Проверка обфускации в логах

```bash
docker logs -f remnawave-nginx
```

**До настройки обфускации** (легаси, легко детектируется):
```
GET /yandexpath/<UUID> HTTP/1.1" 200 ... "https://cdn.example.com/yandexpath/?x_padding=XXXXXXXX..."
```

**После настройки** (`xPaddingObfsMode: true` + переезд паддинга в заголовок):
```
GET /yandexpath/<UUID>/N HTTP/1.1" 200 0 "-" "Mozilla/5.0 ... Chrome/150.0.0.0 ..."
```
`Referer: "-"` — паддинг больше не виден в URL/Referer, переехал в кастомный заголовок `X-Trace-Id`, который не попадает в стандартный access.log.

⚠️ Если в логах внезапно встречается строка со старым User-Agent (например, `Chrome/144.0.0.0` вместо актуального у вашего клиента) и легаси `x_padding=` в Referer — это не ваш клиент, а либо старая незакрытая сессия, либо сторонний сканер, наткнувшийся на путь. Единичные случаи не критичны; при регулярном появлении — смените path на менее предсказуемый.

---

## 9. Экономика трафика

Yandex Cloud CDN тарифицируется **только по объёму исходящего трафика** (₽/ГБ) — количество HTTP-запросов **не тарифицируется отдельно**. Большое число мелких запросов в логах (следствие `mode: packet-up` + xmux-мультиплексирования) не увеличивает счёт само по себе — важен только суммарный объём переданных байт.

`xPaddingBytes: "100-1000"` добавляет реальный оверхед (100–1000 байт мусора на каждый запрос) — при высокой интенсивности использования это может дать заметный процент лишнего трафика. При необходимости сузьте диапазон (например, `"50-300"`), жертвуя частью маскировки ради экономии.

Смотрите фактический расход в консоли: CDN-ресурс → «Метрики за 30 дней» → «Отправлено клиентам».

---

## 10. Продление сертификата (каждые ~90 дней)

Certbot с `--manual` **не продлевается автоматически**.

```bash
certbot certonly --manual --preferred-challenges dns \
  -d cdn.example.com \
  --email you@email.com --agree-tos \
  --key-type rsa \
  --preferred-chain "ISRG Root X1" \
  --force-renewal
```

Затем заново разбейте на leaf/chain и **создайте новый** объект сертификата в Certificate Manager (не редактируйте существующий), привяжите к ресурсу, дождитесь раскатки (см. раздел 3).

---

## 11. Чек-лист быстрой диагностики

1. `ss -tlnp | grep 10088` — жив ли инбаунд на сервере.
2. `curl -v --http1.1 http://127.0.0.1:10088/yourpath` — доступен ли порт напрямую.
3. `curl -v --http1.1 https://nl.example.com/yourpath` — работает ли nginx + сертификат origin.
4. `curl -v --http1.1 https://cdn.example.com/yourpath` — правильно ли CDN проксирует. Если `502` — проверить SNI/протокол/Host в настройках источника, подождать раскатку.
5. `openssl s_client -connect cdn.example.com:443 -servername cdn.example.com -showcerts` — полнота цепочки сертификата (`Verify return code: 0 (ok)`).
6. `curl -v --http2-prior-knowledge https://cdn.example.com/yourpath` — подтвердить h2, сверить ALPN в клиенте.
7. Сквозной тест через `xray run` + `curl --socks5` (раздел 7.5) — самый надёжный способ понять, что именно рвётся.
8. `docker logs -f remnanode 2>&1 | strings` — логи ноды в реальном времени.
9. `docker logs -f remnawave-nginx` — логи запросов (nginx в официальном образе пишет в `/dev/stdout`, `tail -f` на файл-симлинк не сработает — используйте именно `docker logs`).

---

## 12. Итоговая сводка отличий от схемы с МТС CDN

| | МТС (mwscdn.ru) | Yandex Cloud CDN |
|---|---|---|
| nginx в цепочке | Нет, обход напрямую на порт | **Да**, обычный reverse-proxy |
| Разрешённые методы | Только GET/HEAD (POST/PUT → 405) | GET/HEAD/OPTIONS |
| ALPN к клиенту | http/1.1 | **h2** (CDN всегда отвечает HTTP/2) |
| Сертификат раздачи | Автоматически | Yandex Certificate Manager, вручную RSA + ISRG Root X1 |
| Тарификация | — | Только по ГБ исходящего трафика, запросы бесплатны |
| Обфускация паддинга | Базовая | `xPaddingObfsMode` + `tokenish` + кастомный заголовок вместо query |
