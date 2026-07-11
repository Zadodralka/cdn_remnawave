# Настройка XHTTP + CDN (МТС mwscdn) для Remnawave

Инструкция описывает рабочую схему проксирования VLESS/XHTTP-трафика через CDN-провайдера МТС (`mwscdn.ru`), протестированную и подтверждённую на боевом сервере.

## Архитектура

```
Клиент (happ)
    │  TLS SNI = домен CDN
    ▼
CDN МТС (edge, например spb-fed-edge02)
    │  HTTPS, Host = домен CDN
    │  origin: https://IP_сервера:10087
    ▼
Xray inbound "XHTTP_mws" (порт 10087, слушает 0.0.0.0)
    │  TLS терминируется здесь напрямую (сертификат Let's Encrypt)
    │  БЕЗ прохождения через nginx
    ▼
VLESS + XHTTP → обработка запроса, туннелирование трафика
```

Ключевая особенность: инбаунд для CDN-профиля работает **напрямую**, минуя nginx и минуя Reality-инбаунд на 443. Это отдельный, самостоятельный слушатель на отдельном порту.

---

## 1. Предварительные требования

- Домен, на который уже выпущен сертификат Let's Encrypt (в этом гайде используется `nl.unlockless.com`).
- Свободный порт на сервере, не занятый и не проксируемый через что-либо (в этом гайде — `10087`).
- Аккаунт в личном кабинете МТС ID с доступной квотой на создание CDN-ресурсов.

---

## 2. Выпуск/проброс сертификата для нового инбаунда

Если сертификат для домена уже есть (например, используется в nginx), пробросьте его в контейнер ноды `remnanode`.

### 2.1. Certbot (если сертификата ещё нет)

```bash
mkdir -p /opt/certbot && cd /opt/certbot
cat <<'EOF' > docker-compose.yml
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
EOF

docker run --rm \
  -v $(pwd)/certs:/etc/letsencrypt \
  -v $(pwd)/var-lib-letsencrypt:/var/lib/letsencrypt \
  --network host \
  certbot/certbot certonly --standalone \
  --non-interactive --agree-tos \
  --email ваш@email.com \
  -d ваш_домен
```

### 2.2. Проброс сертификата в remnanode

В `docker-compose.yml` ноды (`/opt/remnanode/docker-compose.yml`) добавьте volume:

```yaml
services:
  remnanode:
    ...
    volumes:
      - /dev/shm:/dev/shm:rw
      - /opt/certbot/certs:/etc/letsencrypt:ro   # ← добавить эту строку
```

Перезапустите:

```bash
cd /opt/remnanode && docker compose down && docker compose up -d
```

Проверьте, что сертификат виден внутри контейнера:

```bash
docker exec remnanode ls -la /etc/letsencrypt/live/ваш_домен/
```

---

## 3. Конфиг инбаунда ноды (Remnawave → Config Profiles / Inbounds)

Добавьте новый inbound `XHTTP_mws` в конфиг ноды. Полный конфиг (со всеми остальными инбаундами) выглядит так:

```json
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      {
        "address": "https://dns.google/dns-query",
        "skipFallback": false
      }
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "XHTTP_mws",
      "port": 10087,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "fallbacks": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "minVersion": "1.2",
          "certificates": [
            {
              "keyFile": "/etc/letsencrypt/live/ваш_домен/privkey.pem",
              "certificateFile": "/etc/letsencrypt/live/ваш_домен/fullchain.pem"
            }
          ]
        },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "/xhttppath"
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private"], "type": "field", "outboundTag": "BLOCK" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
```

### ⚠️ Критично важно

- `"mode": "packet-up"` в инбаунде `XHTTP_mws` — **обязательно жёстко прописан**, а не `"auto"`. Именно отсюда host в панели наследует значение `mode` для клиентской ссылки. Если оставить `"auto"`, поле Mode в форме host невозможно переключить на `packet-up` через UI.
- В `xhttpSettings` инбаунда `XHTTP_mws` **не добавляйте** блок `extra` с `seqKey`/`sessionKey`/`xPaddingKey` и т.п. — это ломает работу связки с данным CDN-провайдером (см. раздел «Почему без сложной обфускации» ниже).
- Порт `10087` должен быть открыт в файрволе:
  ```bash
  ufw allow 10087/tcp
  ```

Сохраните конфиг в панели и проверьте, что порт поднялся:

```bash
ss -tlnp | grep 10087
```

---

## 4. Настройка Host в Remnawave

Создайте (или отредактируйте) host, привязанный к inbound `XHTTP_mws`, со следующими параметрами:

| Поле | Значение |
|---|---|
| Адрес (Address) | домен CDN, порт **443** (⚠️ не 10087 — см. примечание ниже) |
| SNI | домен CDN |
| Host | домен CDN |
| Path | `/xhttppath` |
| Транспорт (Security) | `tls` |
| ALPN | `h2,http/1.1` |
| Fingerprint | `chrome` |

**Extra:**
```json
{
  "uplinkHTTPMethod": "GET"
}
```

### ⚠️ Важно про порт в адресе host

Порт в адресе host — это порт, на который **подключается клиент**, то есть порт самого CDN (`443`), а не порт вашего origin-инбаунда (`10087`). CDN сам, на своей стороне, проксирует запрос на реальный `10087` вашего сервера — это настраивается отдельно в личном кабинете CDN (см. раздел 6).

Итоговая клиентская ссылка выглядит так:

```
vless://UUID@домен_cdn:443?encryption=none&type=xhttp&path=%2Fxhttppath&host=домен_cdn&mode=packet-up&extra=%7B%22uplinkHTTPMethod%22%3A%22GET%22%7D&security=tls&sni=домен_cdn&fp=chrome&alpn=h2%2Chttp%2F1.1#XHTTP_CDN
```

---

## 5. Конфиг nginx (для справки — обычный профиль без CDN)

Этот блок nginx обслуживает **обычные** (не-CDN) XHTTP-подключения напрямую по Reality на 443, а также резервный catch-all location. К CDN-профилю (порт 10087) nginx отношения не имеет — тот инбаунд слушает напрямую, в обход nginx.

```nginx
server {
    server_name ваш_домен;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;
    ssl_certificate "/etc/nginx/ssl/ваш_домен/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/ваш_домен/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/ваш_домен/fullchain.pem";
    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

    location /xhttppath/ {
        client_max_body_size 0;
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_http_version 1.1;
        client_body_timeout 5m;
        proxy_read_timeout 315s;
        proxy_send_timeout 5m;
        proxy_pass http://unix:/dev/shm/xrxh.socket;
    }

    location / {
        client_max_body_size 0;
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        client_body_timeout 5m;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:10085;
    }
}
```

> Не забудьте про `map $http_upgrade $connection_upgrade { ... }` и общие `ssl_*` директивы в основном конфиге — они должны быть объявлены один раз на уровне выше (см. основной `default.conf`).

---

## 6. Настройка CDN-ресурса в личном кабинете МТС

1. Зарегистрируйтесь / войдите в МТС ID, проверьте наличие гранта на балансе (при необходимости пополните через окно гранта).
2. Создайте новый CDN-ресурс:
   - **Источник**: `https://IP_вашего_сервера:10087`
   - **Заголовок Host**: ваш исходный домен (например `exemle.domain.com`) — **без** `https://` и без порта
   - **WebSocket** и все прочие опции (кэширование, редиректы, изменение SNI) — **выключить**
3. Сохраните, скопируйте выданный CDN-домен (вида `topXXXXXXXXXX.mwscdn.ru`).
4. В Remnawave создайте host (см. раздел 4), используя этот CDN-домен как Address/SNI/Host.

### Если выбило лимит квот на создание CDN-ресурсов

Напишите в техподдержку МТС:

> Здравствуйте! У меня возникла проблема, у меня лимит на квоты по созданию CDN серверов. Повысьте их пожалуйста.

На уточняющий вопрос о причине ответьте:

> CDN сервера мне необходимы для: оптимизации подключения клиентов к сайту, понижения нагрузки на мой хостинг, повышения скорости прогрузки сайта.

Обычно квоту повышают в течение 1–2 часов.

---

## 7. Проверка работоспособности

### 7.1. Проверка порта напрямую (минуя CDN)

```bash
curl -v https://IP_вашего_сервера:10087/xhttppath -k --max-time 10
```
Ожидаемый ответ: `HTTP/2 404` с пустым телом (это нормальная реакция Xray на транспортном уровне, аутентификация ещё не пройдена).

### 7.2. Проверка через CDN

```bash
curl -v https://домен_cdn/xhttppath -k --max-time 10
```
Ожидаемый ответ: тот же `HTTP/2 404`, но уже с заголовками `server: Angie`, `x-edge-host`, `x-mwscdn-trace-id` — это подтверждает, что CDN корректно проксирует на ваш origin.

Если вместо `404` видите `301 Moved Permanently` с `server: nginx` в теле — CDN всё ещё стучится в старый источник (порт 443/nginx), проверьте настройки источника в личном кабинете CDN ещё раз.

Если видите `502 Bad Gateway` — CDN не может достучаться до указанного порта на origin (порт закрыт, не слушается, или неверно указан).

### 7.3. Полный сквозной тест (реальный VLESS-туннель)

Установите `xray` локально на сервере для теста:

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

Создайте тестовый клиентский конфиг:

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
            "address": "домен_cdn",
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
          "serverName": "домен_cdn",
          "allowInsecure": false
        },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "/xhttppath",
          "host": "домен_cdn",
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
pkill -f "xray run" 2>/dev/null
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
```

---

## 8. Почему без сложной обфускации

В процессе настройки выяснилось следующее:

- CDN МТС (тип ресурса, использованный в этом гайде) **блокирует методы `POST` и `PUT`** на уровне edge — отдаёт `405 Method Not Allowed`, не пропуская запрос до origin. Пропускается только `GET`/`HEAD`.
  - Именно поэтому режим `mode: packet-up` требует явного `"uplinkHTTPMethod": "GET"` в `extra` — это заставляет Xray слать аплинк через `GET` вместо стандартного `POST`.
  - Режим `stream-one` использует `PUT` для аплинка — тоже блокируется, поэтому не подходит.
  - WebSocket (`Upgrade: websocket`) CDN отклоняет с `403 Forbidden` — тоже не вариант.
- Дополнительная обфускация (`seqKey`, `sessionKey`, `xPaddingKey`, `xPaddingHeader`, `xPaddingObfsMode` и т.п.) в `extra` **ломает** соединение именно в связке с этим CDN — сессия либо не открывается (`400 Bad Request`), либо открывается, но реальные данные не проходят. Причина не выяснена до конца (вероятно, несовместимость реализации между версией Xray-core на сервере и в клиенте, либо особенности буферизации на edge CDN), но многократно воспроизведена.
- Рабочая, стабильная конфигурация — **только** `{"uplinkHTTPMethod": "GET"}` в extra, без дополнительных полей.

Если в будущем понадобится более глубокая маскировка трафика — стоит либо протестировать другого CDN-провайдера с явной поддержкой WebSocket/произвольных методов, либо обратиться в поддержку МТС с запросом на тип ресурса с полноценным reverse-proxy для приложений.

---

## 9. Чек-лист быстрой диагностики при проблемах

1. `ss -tlnp | grep 10087` — жив ли инбаунд на сервере.
2. `curl -v https://IP:10087/xhttppath -k` — доступен ли порт напрямую.
3. `curl -v https://домен_cdn/xhttppath -k` — правильно ли CDN проксирует (сравнить с п.2).
4. `docker logs --tail 100 remnanode 2>&1 | strings | tail -50` — логи ноды (учтите: при `loglevel: warning` обычные подключения не логируются, только ошибки).
5. Сквозной тест через локальный `xray run` + `curl --socks5` (см. раздел 7.3) — самый надёжный способ проверить, что рвётся: сервер, CDN или клиент.
6. Проверить лог самого клиента (happ: Settings → Logs) — там видны конкретные ошибки транспорта (`unexpected status`, `bad status code`, `failed to send upload`).
