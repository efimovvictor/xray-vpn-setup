# VPN на своём сервере + Claude Code через Xray

Одна инструкция: сервер с нуля, клиент на Windows и macOS, ежедневное использование,
что делать если сломалось. Личных данных здесь нет — IP, ссылка и пароли подставляются по ходу.

```
Claude Code / opencode → 127.0.0.1:12345 (Xray на компьютере) → <SERVER_IP>:443 (VPS, VLESS+Reality) → интернет
```

- Прокси слушает **только 127.0.0.1** — в локальную сеть ничего не открыто.
- Маршруты, системный прокси и фаервол Windows/macOS **не меняются**: офисный VPN
  (split tunneling) продолжает работать как обычно.
- Через сервер ходит только то, что явно направлено: Claude Code, opencode и, при желании, браузер.

---

## 1. Сервер

Нужен VPS с Ubuntu 22.04/24.04 и root-доступом. Домен для маскировки покупать не обязательно —
подойдёт любой крупный сайт с TLS 1.3 (в примерах `www.example.com`, замени на свой).

### 1.1 Установка панели 3x-ui

```bash
apt update && apt upgrade -y
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

Скрипт спросит логин, пароль и порт панели — запиши их.

### 1.2 Инбаунд

Панель → Inbounds → Add Inbound:

| Поле | Значение |
|---|---|
| Protocol / Port | `vless` / `443` |
| Transmission | `tcp` |
| Security | `reality` |
| Dest / Target | `www.example.com:443` |
| SNI / ServerNames | `www.example.com` |
| uTLS | `chrome` |
| Private/Public Key | Generate |
| ShortIds | Generate |
| Flow у клиента | `xtls-rprx-vision` |

Проверка: `ss -ltnp | grep ':443'` должен показать `LISTEN`.
Пустой SNI — самая частая причина, что Xray не стартует (`empty "serverNames"`).

### 1.3 Фаервол

```bash
ufw default deny incoming
ufw allow 22/tcp              # сначала SSH, потом enable
ufw allow 443/tcp
ufw deny <PANEL_PORT>/tcp
ufw deny <SUB_PORT>/tcp
ufw enable && ufw status numbered
```

### 1.4 Доступ к панели

Наружу панель не открываем, ходим через SSH-туннель:

```bash
ssh -N -L <PANEL_PORT>:127.0.0.1:<PANEL_PORT> root@<SERVER_IP>
```

Браузер: `https://127.0.0.1:<PANEL_PORT>/<BASE_PATH>/` (сертификат самоподписанный — это норма).
Base path забыл — `x-ui setting -show`, пароль — `x-ui setting -password Новый`.

> **Важно.** Ссылку `vless://...` панель собирает из адреса, по которому ты её открыл. Через
> туннель это `localhost` — в ссылке окажется `localhost` вместо IP. Всегда заменяй хост на
> реальный IP перед использованием.

### 1.5 Бэкап

```bash
tar czf /root/x-ui-backup-$(date +%F).tar.gz /etc/x-ui /usr/local/x-ui/bin/config.json
scp root@<SERVER_IP>:/root/x-ui-backup-*.tar.gz .
```

Восстановление: `systemctl stop x-ui` → `tar xzf <архив> -C /` → `systemctl start x-ui`.

---

## 2. Клиент

### 2.1 Ссылка

Панель → Inbounds → 443 → **QR / Export** → скопировать `vless://...` → заменить `localhost`
на IP сервера. Дальше её нужно вставить в скрипт (или положить в менеджер паролей).

### 2.2 Windows

Права администратора не нужны.

```powershell
.\setup-windows.ps1 -Link "vless://...." -Claude
```

Если PowerShell блокирует скрипт:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-windows.ps1 -Link "vless://...." -Claude
```

Скрипт скачивает Xray-core, собирает конфиг, ставит автозапуск, запускает и проверяет
туннель. Приложения настраиваются флагами `-Claude` / `-OpenCode` (раздел 3).

### 2.3 macOS

```bash
chmod +x setup-macos.sh
./setup-macos.sh --link "vless://...." --claude
```

То же самое, но автозапуск через LaunchAgent (`~/Library/LaunchAgents/local.xray.plist`):
стартует при входе и перезапускается при падении.

### 2.4 Флаги скриптов

| Windows / macOS | Что делает |
|---|---|
| `-Link` / `--link` | ссылка; без неё скрипт спросит или оставит текущий конфиг |
| `-Port` / `--port` | локальный порт, по умолчанию `12345` |
| `-NoAutostart` / `--no-autostart` | не ставить автозапуск |
| `-Claude` / `--claude` | прописать прокси в `~/.claude/settings.json` |
| `-OpenCode` / `--opencode` | прописать прокси в окружение фонового сервиса opencode |
| `-Update` / `--update` | перекачать ядро (конфиг сохраняется) |
| `-Uninstall` / `--uninstall` | удалить всё, что поставил скрипт |

Без этих флагов скрипт настраивает только Xray. `-Uninstall` чистит обе интеграции сам,
но убирает лишь значения, совпадающие с локальным прокси. `settings.json` правится
аккуратно: три ключа в `env`, остальные настройки на месте, перед изменением — копия `.bak`.

Если флаг не передан, а у приложения уже стоят чужие (другой порт) настройки локального
прокси, скрипт предупредит: `claude code still points at ... / opencode still points at ...`,
и подсказать заново запустить с нужным флагом.

### 2.5 Проверка

```powershell
# Windows
curl.exe -s -x http://127.0.0.1:12345 https://api.ipify.org
```

```bash
# macOS
curl -s -x http://127.0.0.1:12345 https://api.ipify.org
```

Должен вернуться IP сервера. Если да — прокси работает, дальше ищем причину только в приложении.

---

## 3. Claude Code и opencode

### 3.1 Claude Code

Установка (Windows, нужен Node.js 18+):

```powershell
npm install -g @anthropic-ai/claude-code
```

macOS: `curl -fsSL https://claude.ai/install.sh | bash` (если `claude.ai` недоступен —
сначала `export HTTPS_PROXY=http://127.0.0.1:12345`).

Прокси скрипт прописал в `~/.claude/settings.json` (`%USERPROFILE%\.claude\settings.json`),
если запускался с `--claude` / `-Claude`:

```json
{ "env": { "HTTPS_PROXY": "http://127.0.0.1:12345",
           "HTTP_PROXY":  "http://127.0.0.1:12345",
           "NO_PROXY":    "localhost,127.0.0.1,::1" } }
```

Проверка: `claude -p "сколько будет 2+2"` — ответ означает, что и авторизация, и прокси в порядке.
Менял порт в Xray — поменяй и здесь, потом перезапусти `claude` (переменные читаются при старте).

**Браузер** нужен только для страницы логина. Firefox + FoxyProxy Standard: прокси HTTP
`127.0.0.1:12345`, шаблоны `*claude.ai*` и `*anthropic.com*`, режим «by patterns». Через сервер
ходят только эти домены, остальное — напрямую.

### 3.2 opencode

opencode — клиент-сервер: запросы делает фоновый сервис, и он читает `HTTP_PROXY` /
`HTTPS_PROXY` из своего окружения, а не из `settings.json`. Поэтому скрипту нужен отдельный
флаг:

```powershell
.\setup-windows.ps1 -Link "vless://...." -OpenCode
```

```bash
./setup-macos.sh --link "vless://...." --opencode
```

То же самое руками:

```bash
opencode service set env HTTP_PROXY  http://127.0.0.1:12345
opencode service set env HTTPS_PROXY http://127.0.0.1:12345
opencode service set env NO_PROXY    localhost,127.0.0.1,::1
opencode service start
```

`NO_PROXY` обязателен: CLI соединяется со своим сервисом по loopback, и прокси на `localhost`
рвёт эту связь. Смена переменных перезапускает сервис — текущая сессия оборвётся, история
сессий сохранится. Если opencode не установлен, скрипт предупредит и ничего не сломает.

Проверка: `opencode service get env` показывает три переменные, обычный запрос в opencode
проходит через сервер. Откат: `opencode service unset env HTTPS_PROXY` (и так же для
`HTTP_PROXY`, `NO_PROXY`), затем `opencode service start`. `--uninstall` делает это сам.

---

## 4. Ежедневно

Ничего делать не нужно: прокси поднимается при входе в систему сам.

```powershell
Get-Process xray -ErrorAction SilentlyContinue        # запущен?
Start-Process wscript.exe -ArgumentList '"<путь>\start-xray.vbs"'   # запустить
Get-Process xray | Stop-Process                       # остановить
```

```bash
launchctl list | grep local.xray                      # macOS: запущен?
launchctl kickstart -k gui/$(id -u)/local.xray        # перезапустить
launchctl bootout gui/$(id -u)/local.xray             # остановить
```

| Что случилось | Что делать |
|---|---|
| сменился IP сервера, ключи, SNI, клиент | взять свежую ссылку и снова запустить скрипт с `-Link` |
| нужна новая версия ядра | `-Update` / `--update` |
| сменить локальный порт | `-Port` / `--port`, повторить запуск с флагом интеграции, перезапустить приложения |
| хочу видеть ошибки Xray | добавить в `config.json` `"log": { "loglevel": "warning", "error": "<путь>" }` |

Проверка сервера одной строкой:

```bash
ssh root@<SERVER_IP> 'systemctl is-active x-ui; ss -ltnp | grep ":443"; ufw status | head -3'
```

---

## 5. Если не работает

| Симптом | Причина | Что делать |
|---|---|---|
| `Failed to connect to 127.0.0.1:12345` | прокси не запущен | проверить процесс, запустить |
| `An existing connection was forcibly closed` | в конфиге `localhost` вместо IP | заменить `address` в `config.json` |
| `reality verification failed` | чужое ядро (Hiddify и подобные) | использовать Xray-core |
| `connection reset` | сервер не отвечает на 443 | на сервере: `ss -ltnp \| grep ':443'` |
| `claude` висит, curl работает | порт в `settings.json` ≠ порт Xray | сверить, перезапустить `claude` |
| opencode не видит прокси | сервис запущен со старым окружением | `opencode service get env`, затем `opencode service start` |
| панель отдаёт 404 | неверный base path / `http` вместо `https` | `https://127.0.0.1:<PORT>/<BASE_PATH>/` |
| Xray не стартует: `empty "serverNames"` | пустой SNI | заполнить SNI = домен из Dest |
| всё зелёное, но доступа нет | аккаунт/регион | см. раздел 6 |

**Сервер или клиент?** Подними на самом сервере тестовый клиент с теми же параметрами и прогони
через него `curl`. Работает — виноват клиент; не работает — сервер или ключи.

---

## 6. Безопасность

- **Панель** — только через SSH-туннель, сильный пароль, случайный base path.
- **SSH** — вход по ключу; пароль root наружу лучше отключить (`PasswordAuthentication no`),
  но только после проверки, что ключ работает, и держа под рукой консоль хостера.
- **`config.json` и ссылка `vless://`** = учётные данные (UUID клиента внутри). Утёк —
  удалить клиента в панели, создать нового, переустановить конфиг.
- **Регион.** Доступ из неподдерживаемой страны нарушает Usage Policy Anthropic. Прокси снижает
  риск блокировки, но не делает использование «правильным»: надёжный путь — аккаунт и оплата
  в поддерживаемой стране либо Claude через AWS Bedrock / Google Vertex.
