# Настройка XHTTP + Yandex Cloud CDN для Remnawave

Инструкция описывает рабочую схему проксирования VLESS/XHTTP-трафика через Yandex Cloud CDN, с прохождением через **nginx** (в отличие от схемы с МТС mwscdn, где nginx пришлось обойти из-за блокировки методов POST/PUT на их CDN).

## Архитектура

```
Клиент (happ/v2rayNG/xray)
    │  TLS SNI = домен раздачи CDN (cdn.example.com)
    │  ALPN = h2 (обязательно! Yandex CDN всегда отвечает HTTP/2)
    ▼
Yandex Cloud CDN (edge, anycast, множество нод по всему миру)
    │  HTTPS, Host = origin-домен (nl.example.com)
    │  SNI к источнику = origin-домен
    │  origin: https://nl.example.com:443
    ▼
nginx (на вашем сервере, слушает 443, сертификат Let's Encrypt на origin-домен)
    │  location /yourpath → proxy_pass на unix-сокет / 127.0.0.1:port
    ▼
Xray inbound (VLESS + xhttp, mode packet-up, security: none — TLS терминирован в nginx)
```

Ключевое отличие от схемы с МТС: здесь nginx остаётся в цепочке как обычный reverse-proxy, потому что Yandex CDN по умолчанию не блокирует нужные HTTP-методы так, как это делает МТС.

---

## 1. Предварительные требования

- Домен-**источник** (origin), на который уже выпущен сертификат Let's Encrypt и настроен nginx как reverse-proxy к Xray-инбаунду (в этом гайде — `nl.example.com`).
- **Отдельный** домен/поддомен для **раздачи CDN** (в этом гайде — `cdn.example.com`) — не может совпадать с origin-доменом.
- Аккаунт в Yandex Cloud с доступом к Cloud CDN и Certificate Manager.
- `certbot`, установленный на сервере.

---

## 2. Создание CDN-ресурса в Yandex Cloud

В консоли Yandex Cloud → Cloud CDN → «Создать ресурс»:

| Поле | Значение |
|---|---|
| Доступ к контенту | Включить |
| Запрос контента | С одного источника |
| Тип источника | Собственный сервер / по доменному имени |
| Доменное имя источника | `nl.example.com` (ваш origin) |
| Протокол для источников | **HTTPS** |
| Задать SNI вручную | Включить, значение `nl.example.com` |
| Заголовок Host | Своё значение → `nl.example.com` |
| Доменное имя (раздача) | `cdn.example.com` (**отдельный** от origin домен!) |

### Кэширование — всё выключить

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
| Разрешённые методы | GET, HEAD, OPTIONS (доступный набор в UI — этого достаточно для WS-handshake и xhttp GET-режима) |
| CORS | Не использовать |

После создания ресурса Yandex выдаст CNAME-цель вида `xxxxxxxxxxxxxxxx.a.yccdn.cloud.yandex.net` — пропишите её в DNS для домена раздачи:
```
Тип:      CNAME
Имя:      cdn
Значение: xxxxxxxxxxxxxxxx.a.yccdn.cloud.yandex.net.
```

---

## 3. Выпуск сертификата для домена раздачи CDN

### ⚠️ Критично важно

Yandex Certificate Manager умеет выпускать сертификаты автоматически, но:
- Если ваш DNS-провайдер использует несколько NS-серверов (например, `orderbox-dns.com` у reg.ru-подобных хостеров), проверка домена может проходить нестабильно, если NS-сервера не полностью синхронизированы между собой в момент проверки.
- **Дефолтный тип ключа Let's Encrypt (ECDSA) сейчас выдаёт цепочку через новые корневые сертификаты (`Root YE`), которые ещё не входят во все системные доверенные хранилища.** Строгие TLS-клиенты (включая `curl`) будут ругаться на `unable to get local issuer certificate`.

**Решение — выпустить сертификат вручную через certbot, с RSA-ключом и явным запросом старой, повсеместно доверенной цепочки:**

```bash
certbot certonly --manual --preferred-challenges dns \
  -d cdn.example.com \
  --email ваш@email.com --agree-tos \
  --key-type rsa \
  --preferred-chain "ISRG Root X1"
```

Certbot покажет TXT-запись вида:
```
_acme-challenge.cdn.example.com.  →  <токен>
```

**Перед тем как нажать Enter в certbot** — добавьте эту TXT-запись в DNS-панели, и в **отдельном** терминале дождитесь, пока она полностью разойдётся:
```bash
dig TXT _acme-challenge.cdn.example.com +short
```
Если у DNS-провайдера несколько авторитетных NS — проверьте по каждому из них отдельно:
```bash
dig NS example.com +short
# для каждого полученного NS:
dig TXT _acme-challenge.cdn.example.com @<ns-сервер> +short
```
Только когда **все** NS отдают одинаковое и правильное значение — возвращайтесь в certbot и жмите Enter.

### Проверка полученной цепочки

```bash
openssl crl2pkcs7 -nocrl -certfile /etc/letsencrypt/live/cdn.example.com/fullchain.pem | openssl pkcs7 -print_certs -noout
```
В конце цепочки должен быть **`ISRG Root X1`** (не `Root YE`/`Root YR`).

### Разбивка на части для загрузки в Yandex

Yandex Certificate Manager при импорте ожидает **раздельно**: leaf-сертификат в одно поле, цепочку (всё остальное, кроме самоподписанного root) — в другое.

```bash
awk '/BEGIN CERTIFICATE/{n++} n==1' /etc/letsencrypt/live/cdn.example.com/fullchain.pem > /root/leaf_only.pem
awk '/BEGIN CERTIFICATE/{n++} n>1'  /etc/letsencrypt/live/cdn.example.com/fullchain.pem > /root/chain_combined.pem
```

В Certificate Manager → «Создать сертификат» → **«Загруженный»**:
- Поле «Сертификат» → содержимое `leaf_only.pem`
- Поле «Цепочка» → содержимое `chain_combined.pem`
- Поле «Приватный ключ» → содержимое `privkey.pem`

### ⚠️ Важное наблюдение про редактирование vs создание

Редактирование содержимого **уже существующего** Imported-сертификата не всегда приводит к тому, что CDN-ресурс подхватывает обновлённую цепочку — в наших тестах это стабильно приводило к тому, что edge продолжал отдавать только leaf, без цепочки, сколько ни жди. Рабочим оказалось **создание нового объекта сертификата** с нуля (с новым именем), а не правка старого.

Привяжите новый сертификат в настройках CDN-ресурса: «Тип сертификата» → Certificate Manager → выбрать созданный сертификат.

### Раскатка — наберитесь терпения

Изменения сертификата и настроек источника **не применяются мгновенно и не одновременно** на все edge-ноды Yandex CDN (это anycast-инфраструктура из множества физических серверов). После любого изменения ожидайте от 10 минут до часа, и мониторьте статус, а не полагайтесь на единичный тест:

```bash
for i in $(seq 1 30); do
  N=$(openssl s_client -connect cdn.example.com:443 -servername cdn.example.com -showcerts </dev/null 2>/dev/null | grep -c "BEGIN CERTIFICATE")
  echo "$(date '+%H:%M:%S')  сертификатов в цепочке: $N"
  sleep 5
done
```
Дожидайтесь стабильных `2`+ (не `1`) на протяжении нескольких минут подряд, прежде чем считать раскатку завершённой.

Финальная проверка доверия:
```bash
openssl s_client -connect cdn.example.com:443 -servername cdn.example.com </dev/null 2>&1 | grep "Verify return code"
```
Ожидаем `Verify return code: 0 (ok)`.

---

## 4. Конфиг инбаунда Xray (xhttp)

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
      "path": "/yourpath"
    }
  }
}
```

TLS здесь **не** нужен (`"security": "none"`) — шифрование терминируется в nginx, до Xray доходит уже расшифрованный трафик.

Не забудьте открыть порт в файрволе, если Xray слушает `0.0.0.0` напрямую (в данной схеме не обязательно, если между Xray и внешним миром всегда стоит nginx, но полезно на случай прямой диагностики):
```bash
ufw allow 10088/tcp
```

---

## 5. Конфиг nginx

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

Если nginx у вас в Docker-контейнере в режиме `host` network (как в стандартной поставке Remnawave-ноды) — `127.0.0.1:10088` сработает без проблем, так как контейнер использует сетевой стек хоста.

Перезагрузите nginx:
```bash
docker exec remnawave-nginx nginx -t
docker exec remnawave-nginx nginx -s reload
```

---

## 6. Настройка Host в Remnawave

| Поле | Значение |
|---|---|
| Address | `cdn.example.com` |
| Port | **443** (не 10088! Клиент подключается к CDN, а не напрямую к вашему серверу) |
| SNI | `cdn.example.com` |
| Host | `cdn.example.com` |
| Path | `/yourpath` |
| Network | xhttp |
| Mode | packet-up |
| Security | tls |
| **ALPN** | **`h2`** (только h2! См. критичный момент ниже) |
| Fingerprint | chrome |
| Extra | `{"uplinkHTTPMethod": "GET"}` |

### ⚠️ Критично важно — ALPN должен быть `h2`, не `http/1.1`

Это была финальная и самая незаметная причина проблем в нашей отладке: **Yandex Cloud CDN всегда отвечает клиенту по HTTP/2**, независимо от того, что клиент предлагает через ALPN. Если в клиентском TLS выставлен только `http/1.1` (или `h2,http/1.1` в порядке приоритета не в пользу h2), Xray-клиент пытается парсить HTTP/2-бинарный поток как HTTP/1.1 и получает ошибку вида:
```
malformed HTTP response "\x00\x00\x12\x04\x00\x00\x00\x00\x00\x00\x03..."
```
Итоговая ссылка выглядит так:
```
vless://UUID@cdn.example.com:443?encryption=none&type=xhttp&path=%2Fyourpath&host=cdn.example.com&mode=packet-up&extra=%7B%22uplinkHTTPMethod%22%3A%22GET%22%7D&security=tls&sni=cdn.example.com&fp=chrome&alpn=h2#Yandex_CDN
```

---

## 7. Проверка работоспособности

### 7.1. Напрямую на инбаунд, в обход nginx

```bash
curl -v --http1.1 http://127.0.0.1:10088/yourpath
```
Ожидаем `404 Not Found` — нормальная реакция Xray на транспортном уровне без валидной аутентификации.

### 7.2. Через nginx, в обход CDN

```bash
curl -v --http1.1 https://nl.example.com/yourpath
```
Ожидаем тот же `404`.

### 7.3. Через сам Yandex CDN

```bash
curl -v --http1.1 https://cdn.example.com/yourpath
```
Ожидаем `404` с заголовками `server: nginx`, `cache-host: yccdn-...` — подтверждает, что CDN корректно проксирует на origin.

Если видите `502 Bad Gateway` вперемешку с `404` при повторных запросах — это нормально во время раскатки настроек по edge-нодам (см. раздел про терпение выше). Мониторьте долю:
```bash
for i in $(seq 1 20); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --http1.1 https://cdn.example.com/yourpath)
  echo "$(date '+%H:%M:%S')  код: $CODE"
  sleep 5
done
```
Дожидайтесь стабильных `404` без единого `502`.

### 7.4. Полный сквозной тест (реальный VLESS-туннель)

Установите `xray` локально на сервере для теста:
```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

Тестовый клиентский конфиг:
```bash
cat <<'EOF' > /root/test-client.json
{
  "log": { "loglevel": "debug" },
  "inbounds": [
    {
      "port": 10800,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "cdn.example.com",
            "port": 443,
            "users": [
              { "id": "UUID_пользователя", "encryption": "none" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "cdn.example.com",
          "alpn": ["h2"]
        },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "/yourpath",
          "extra": { "uplinkHTTPMethod": "GET" }
        }
      }
    }
  ]
}
EOF

xray run -c /root/test-client.json
```

В соседнем терминале:
```bash
curl -v --socks5 127.0.0.1:10800 https://2ip.ru --max-time 15
```

Если в ответе видите **IP вашего сервера** — туннель полностью рабочий, end-to-end.

Не забудьте удалить временный xray после тестов:
```bash
pkill -f "xray run"
```

---

## 8. Продление сертификата

Certbot с флагом `--manual` **не продлевается автоматически**. Перед истечением срока (в этом примере — 90 дней от выпуска) повторите:

```bash
certbot certonly --manual --preferred-challenges dns \
  -d cdn.example.com \
  --email ваш@email.com --agree-tos \
  --key-type rsa \
  --preferred-chain "ISRG Root X1" \
  --force-renewal
```

Затем заново разбейте на leaf/chain и создайте **новый** объект сертификата в Certificate Manager (по опыту — не редактируйте существующий, создавайте заново), привяжите к ресурсу, дождитесь раскатки.

---

## 9. Чек-лист быстрой диагностики при проблемах

1. `ss -tlnp | grep 10088` — жив ли инбаунд на сервере.
2. `curl -v --http1.1 http://127.0.0.1:10088/yourpath` — доступен ли порт напрямую.
3. `curl -v --http1.1 https://nl.example.com/yourpath` — работает ли nginx + сертификат origin.
4. `curl -v --http1.1 https://cdn.example.com/yourpath` — правильно ли CDN проксирует (сравнить с п.3). Если `502` — проверить SNI/протокол/Host в настройках источника CDN-ресурса, и подождать раскатку.
5. `openssl s_client -connect cdn.example.com:443 -servername cdn.example.com -showcerts` — проверить полноту цепочки сертификата (ищем `Verify return code: 0 (ok)`).
6. `curl -v --http2-prior-knowledge https://cdn.example.com/yourpath` — проверить, что CDN действительно отвечает по h2 (обычно да), и убедиться, что ALPN в клиентском конфиге/хосте выставлен именно `h2`.
7. Сквозной тест через локальный `xray run` + `curl --socks5` (см. раздел 7.4) — самый надёжный способ проверить, что именно рвётся: сервер, CDN, сертификат или клиент.
8. `docker logs -f remnanode 2>&1 | strings` — логи ноды в реальном времени во время попытки подключения.

---

## 10. Итоги — ключевые отличия от схемы с МТС CDN

| | МТС (mwscdn.ru) | Yandex Cloud CDN |
|---|---|---|
| nginx в цепочке | Нет, обход напрямую на отдельный порт | **Да**, обычный reverse-proxy |
| Разрешённые методы | Только GET/HEAD (POST/PUT → 405) | GET/HEAD/OPTIONS в UI, WS/xhttp работают |
| Транспорт | xhttp, packet-up, uplinkHTTPMethod=GET | xhttp, packet-up, uplinkHTTPMethod=GET (WS теоретически возможен, но не проверялся глубоко) |
| ALPN к клиенту | http/1.1 | **h2** (CDN всегда отвечает HTTP/2!) |
| Сертификат для домена раздачи | Через МТС автоматически | Через Yandex Certificate Manager, вручную RSA + ISRG Root X1 chain |
| Порт в клиентской ссылке | 443 (CDN), origin слушает отдельный порт напрямую | 443 (CDN), origin слушает через nginx |
