# XHTTP + Yandex Cloud CDN — краткая инструкция

## 1. CDN-ресурс в Yandex Cloud

| Поле | Значение |
|---|---|
| Тип источника | Собственный сервер |
| Доменное имя источника | `nl.example.com` |
| Протокол для источников | HTTPS |
| Задать SNI вручную | `nl.example.com` |
| Заголовок Host | `nl.example.com` |
| Доменное имя (раздача) | `cdn.example.com` |
| Кеширование | Выключить всё (TTL=0, gzip выкл, cookie игнор) |
| Перенаправления / CORS / токен / IP-ограничения | Выключить всё |
| Разрешённые методы | GET, HEAD, OPTIONS |

DNS:
```
CNAME cdn → xxxxxxxxxxxxxxxx.a.yccdn.cloud.yandex.net.
```

## 2. Сертификат

```bash
certbot certonly --manual --preferred-challenges dns \
  -d cdn.example.com \
  --email you@email.com --agree-tos \
  --key-type rsa \
  --preferred-chain "ISRG Root X1"
```

Перед Enter в certbot — добавить TXT-запись и дождаться синхронизации по всем NS:
```bash
dig NS example.com +short
dig TXT _acme-challenge.cdn.example.com @<ns> +short
```

Проверка цепочки (должна заканчиваться на ISRG Root X1):
```bash
openssl crl2pkcs7 -nocrl -certfile /etc/letsencrypt/live/cdn.example.com/fullchain.pem | openssl pkcs7 -print_certs -noout
```

Разбивка:
```bash
awk '/BEGIN CERTIFICATE/{n++} n==1' /etc/letsencrypt/live/cdn.example.com/fullchain.pem > /root/leaf_only.pem
awk '/BEGIN CERTIFICATE/{n++} n>1'  /etc/letsencrypt/live/cdn.example.com/fullchain.pem > /root/chain_combined.pem
```

Certificate Manager → Создать сертификат → Загруженный:
- Сертификат = `leaf_only.pem`
- Цепочка = `chain_combined.pem`
- Ключ = `privkey.pem`

Привязать к ресурсу: Тип сертификата → Certificate Manager → выбрать созданный. Создавать новый объект, не редактировать старый.

Ждать раскатку (10-60 мин):
```bash
openssl s_client -connect cdn.example.com:443 -servername cdn.example.com </dev/null 2>&1 | grep "Verify return code"
```
Ждать: `0 (ok)`

## 3. Инбаунд Xray

```json
{
  "tag": "VLESS_XHTTP_YANDEX",
  "listen": "0.0.0.0",
  "port": 10088,
  "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": { "mode": "packet-up", "path": "/yourpath" }
  }
}
```

## 4. nginx

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

```bash
docker exec remnawave-nginx nginx -t
docker exec remnawave-nginx nginx -s reload
```

## 5. Host в Remnawave

| Поле | Значение |
|---|---|
| Address | `cdn.example.com` |
| Port | 443 |
| SNI | `cdn.example.com` |
| Host | `cdn.example.com` |
| Path | `/yourpath` |
| Network | xhttp |
| Mode | packet-up |
| Security | tls |
| ALPN | **h2** |
| Fingerprint | chrome |
| Extra | `{"uplinkHTTPMethod": "GET"}` |

## 6. Проверка

```bash
curl -v --http1.1 http://127.0.0.1:10088/yourpath          # 404
curl -v --http1.1 https://nl.example.com/yourpath           # 404
curl -v --http1.1 https://cdn.example.com/yourpath          # 404 (может мигать 502 во время раскатки)
curl -v --http2-prior-knowledge https://cdn.example.com/yourpath   # подтвердить h2
```

Сквозной тест:
```bash
cat <<'EOF' > /root/test-client.json
{
  "log": { "loglevel": "debug" },
  "inbounds": [{ "port": 10800, "listen": "127.0.0.1", "protocol": "socks", "settings": { "auth": "noauth", "udp": true } }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "cdn.example.com", "port": 443, "users": [{ "id": "UUID", "encryption": "none" }] }] },
    "streamSettings": {
      "network": "xhttp",
      "security": "tls",
      "tlsSettings": { "serverName": "cdn.example.com", "alpn": ["h2"] },
      "xhttpSettings": { "mode": "packet-up", "path": "/yourpath", "extra": { "uplinkHTTPMethod": "GET" } }
    }
  }]
}
EOF
xray run -c /root/test-client.json &
curl -v --socks5 127.0.0.1:10800 https://2ip.ru --max-time 15
pkill -f "xray run"
```

## 7. Продление (каждые 90 дней)

```bash
certbot certonly --manual --preferred-challenges dns \
  -d cdn.example.com --email you@email.com --agree-tos \
  --key-type rsa --preferred-chain "ISRG Root X1" --force-renewal
```
→ пересобрать leaf/chain → новый объект в Certificate Manager → привязать → ждать раскатку.
