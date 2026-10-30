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
| `-Desktop` / `--desktop` | создать ярлык, который запускает приложение Claude Desktop через прокси |
| `-DesktopAutostart` / `--desktop-autostart` | то же + запускать Claude Desktop через прокси при входе в систему |
| `-Update` / `--update` | перекачать ядро (конфиг сохраняется) |
| `-Uninstall` / `--uninstall` | удалить всё, что поставил скрипт |

Без этих флагов скрипт настраивает только Xray. `-Uninstall` чистит все интеграции сам,
но убирает лишь значения, совпадающие с локальным прокси. `settings.json` правится
аккуратно: три ключа в `env`, остальные настройки на месте, перед изменением — копия `.bak`.

Если флаг не передан, а у приложения уже стоят чужие (другой порт) настройки локального
прокси, скрипт предупредит: `claude code still points at ... / opencode still points at ... / claude desktop shortcut still points at ...`,
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

### 2.6 Android (только приложение Claude)

На телефоне скрипты не нужны: сервер тот же, ставится клиент VLESS и в нём указывается,
какие приложения пускать через сервер. Остальные ходят напрямую.

1. Поставь **v2rayNG** (Google Play, GitHub Releases или F-Droid).
2. Возьми ссылку `vless://...` (раздел 2.1, хост уже заменён на IP сервера) и передай её
   на телефон: QR из панели, буфер обмена или менеджер паролей.
3. v2rayNG → **+** → *Import config from clipboard* (или *Scan QR code*). Выбери профиль в списке.
4. Меню (☰) → **Settings** → включи **Per-app proxy** (проксирование по приложениям) и
   отметь **только Claude** (`com.anthropic.claude`). Переключатель *Bypass mode* оставь
   **выключенным**: тогда через сервер идут именно отмеченные приложения, а не все остальные.
5. Нажми кнопку подключения (V) и подтверди запрос Android на VPN.

Проверка: в браузере телефона на «what is my IP» виден **обычный** IP (браузер вне списка),
приложение Claude открывается и отвечает. Если в браузере IP сервера, *Bypass mode* стоит наоборот.
Чтобы убедиться, что туннель работает, добавь на минуту в список Chrome: «what is my IP»
покажет IP сервера. После проверки убери Chrome.

**Если на телефоне стоит AdGuard (или другой блокировщик рекламы на VPN).** Android держит один
VPN одновременно, поэтому они конфликтуют. Рабочая схема: реклама блокируется через системный
**Частный DNS**, а VPN остаётся за v2rayNG.

1. В AdGuard полностью выключи защиту (главный переключатель), чтобы он не держал VPN.
2. Android → Сеть и интернет → **Частный DNS** → имя хоста `dns.adguard-dns.com`.
3. v2rayNG: Settings → **Mode** = **VPN** (не *Proxy only*), Per-app proxy только для Claude, как выше.

Так реклама блокируется по доменам во всех приложениях, а через сервер идёт только Claude.
Косметической фильтрации страниц, как у приложения AdGuard, нет.

Почему не цепочка «v2rayNG в *Proxy only* + SOCKS5 `127.0.0.1:10808` в AdGuard»: AdGuard
отправляет в прокси весь свой трафик, а не отдельные приложения, и через сервер пойдёт весь
телефон.

**Вход в аккаунт.** Вход через Google открывает браузер или окно Google, они вне списка и идут
напрямую. Если вход не проходит, на время входа добавь в список Chrome (и Google Play services),
а после входа убери.

**Чтобы не отваливалось:**
- v2rayNG → Settings: включи автозапуск при загрузке; в настройках Android для приложения
  выставь «Без ограничений» по батарее.
- Android → Сеть → VPN → v2rayNG: можно включить *Постоянная VPN*. Тогда Claude не уйдёт
  в интернет без защиты, если VPN упал.
- Android держит один VPN одновременно: вместе с офисным VPN на этом же телефоне не заработает.

Claude Code на телефоне не запускается, подходит только приложение (и браузер, если добавить его в список).

> В v2rayNG режим (*Mode*: VPN / Proxy only) лежит в Settings, раздел **Mode Settings**, и
> прячется глубоко вниз списка. Названия пунктов зависят от версии.

---

## 3. Claude Code, opencode и Claude Desktop

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

### 3.3 Claude Desktop

Десктопное приложение не читает `settings.json` и без прокси пишет «unavailable in your region».
Флаг `-Desktop` / `--desktop` создаёт запускалку, которая стартует приложение с
`--proxy-server=http://127.0.0.1:12345`: на Windows — ярлык «Claude (Xray proxy)» в меню Пуск
(версия из Microsoft Store), на macOS — `~/Applications/Claude (Xray proxy).app`.

Запускай приложение только из неё (старую иконку Claude на панели задач открепи, закрепи эту:
иначе будут две) и перед этим полностью закрой уже открытое окно Claude
(в том числе в трее): запущенный экземпляр флаг игнорирует. Вход в аккаунт идёт через браузер,
которому тоже нужен прокси. Вручную: `claude.exe --proxy-server=http://127.0.0.1:12345`
(Windows, `app\claude.exe` в `(Get-AppxPackage *Claude*).InstallLocation`) или
`open -a Claude --args --proxy-server=http://127.0.0.1:12345` (macOS). Порт сменился
— запусти скрипт ещё раз с `-Desktop`. Путь в ярлыке содержит версию приложения, поэтому
при входе в Windows маленький скрипт сам обновляет его (и закреплённую иконку) после апдейта Claude;
с `-NoAutostart` этого нет, и после обновления нужно повторить `-Desktop`.

Чтобы Claude сам открывался через прокси при входе, добавь `-DesktopAutostart` /
`--desktop-autostart`: приложение стартует, когда прокси уже отвечает (на Windows скрипт ждёт
порт до 30 с, на macOS — пауза 5 с). Собственный автозапуск Claude (настройки приложения или
«Автозагрузка») при этом выключи, иначе он стартует без прокси. Запуск без этого флага —
`-Desktop` — автозапуск снимает.

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

---

## 7. WireGuard-хаб: телефон ↔ ПК через VPS

Зачем: Android разрешает только один VPN, поэтому «Claude на телефоне» (v2rayNG) и «ADB с ПК на телефон» одновременно невозможны. WG-хаб решает это: телефон сидит в full tunnel до VPS (Claude видит IP VPS), а ПК — пир в той же сети, поэтому `adb install` и RDP работают всегда, без переключений.

```
телефон 10.66.66.2 ─┐
                    ├── VPS 10.66.66.1 (UDP 51821, MASQUERADE)
ПК      10.66.66.3 ─┘
```

Что даёт: Claude (IP VPS), `adb connect 10.66.66.2:5555`, `mstsc 10.66.66.3`. При этом на ПК WG подключён **только для подсети** — default route, интернет и офисный VPN не меняются.

### 7.1 Генерация конфигов

Нужны `wg.exe` (WireGuard for Windows) и `qrcode` (`pip install qrcode pillow`).

```powershell
python wireguard/gen-configs.py --vps <SERVER_IP> --port 51821 --out wireguard/out
```

Появятся:

| Файл | Куда |
|---|---|
| `wg0.conf` | VPS, `/etc/wireguard/wg0.conf` |
| `wg-pc.conf` | ПК, WireGuard (split, только `10.66.66.0/24`) |
| `wg-phone.conf` | телефон, WireGuard (full tunnel) |
| `wg-phone-qr.png` | то же в виде QR |

Скрипт **отказывается перезаписывать** существующие конфиги: новые ключи сломают уже подключённые пиры. Перегенерация — только с `--force` и с повторным импортом на устройствах.

### 7.2 Сервер

```powershell
scp wireguard\setup-wg-server.sh wireguard\out\wg0.conf root@<SERVER_IP>:/root/
ssh root@<SERVER_IP> "bash /root/setup-wg-server.sh /root/wg0.conf"
```

Скрипт ставит WireGuard, включает `net.ipv4.ip_forward=1`, кладёт конфиг в `/etc/wireguard/wg0.conf`, открывает UDP-порт в ufw (если активен), включает `wg-quick@wg0`.

Проверка на сервере:

```bash
wg show
ip -4 addr show wg0 | grep inet
```

Важно: правила `PostUp` из конфига разрешают трафик **между пирами** (`-i wg0 -o wg0`) — без них телефон не увидит ПК для RDP.

Если у провайдера VPS есть внешний файрвол (панель хостинга) — там тоже нужно открыть **UDP 51821**.

### 7.3 ПК

Импорт: WireGuard → «Add tunnel» → из файла `wg-pc.conf`. Либо службой:

```powershell
& "C:\Program Files\WireGuard\wireguard.exe" /installtunnelservice "E:\DEV\vpn-wg\wg-pc.conf"
```

RDP по WG: адаптер обычно получает профиль сети **Public**, а правила RDP разрешены только для Private/Domain. Лечится двумя командами от администратора:

```powershell
Set-NetConnectionProfile -InterfaceAlias "wg-pc" -NetworkCategory Private
New-NetFirewallRule -DisplayName "RDP over WireGuard" -Direction Inbound -Protocol TCP -LocalPort 3389 -InterfaceAlias "wg-pc" -Action Allow -Profile Any
```

Проверка: `ping 10.66.66.1`, затем с телефона `mstsc 10.66.66.3`.

### 7.4 Телефон

1. Установить WireGuard из Play Store.
2. «+» → сканировать QR (`wg-phone-qr.png`) либо импортировать `wg-phone.conf`.
3. **Выключить v2rayNG** — активным может быть только один VPN.
4. Включить туннель. Проверка: IP на <https://api.ipify.org> должен быть адресом VPS.
5. Включить «Always-on VPN» для WireGuard, иначе после перезагрузки туннель не поднимется сам.

### 7.5 Проверки

| Где | Команда | Ожидаемо |
|---|---|---|
| ПК | `ping 10.66.66.1` | ответ |
| ПК | `adb connect 10.66.66.2:5555` | `connected to ...` |
| ПК | `adb devices` | `10.66.66.2:5555  device` |
| телефон | `mstsc 10.66.66.3` | вход в Windows (учётка + пароль MSA, не PIN) |
| телефон | <https://api.ipify.org> | IP VPS |

### 7.6 Безопасность

- Приватные ключи лежат только в `wireguard/out/` (в `.gitignore`); QR не публиковать и не пересылать в мессенджерах.
- Наружу открыт один UDP-порт (по умолчанию 51821). Порт лучше держать нестандартным.
- Телефон в full tunnel гонит **весь** трафик через VPS: расход трафика и батареи выше, чем у Xray с per-app прокси.
- WG не умеет per-app: если нужен только Claude — остаётся Xray+Reality.
- Tailscale остаётся резервом (прямое P2P, не зависит от VPS), но на телефоне одновременно с WG не работает.

### 7.7 Ограничения и откат

- Если провайдер начнёт резать UDP/WG — вернуться на Xray+v2rayNG (профиль телефона просто переключить обратно).
- После перезагрузки телефона беспроводная отладка выключается; порт `5555` (режим `adb tcpip`) живёт до ребута — потом ADB снова надо включить вручную.
- Полный откат: выключить туннели на ПК и телефоне, на VPS — `systemctl disable --now wg-quick@wg0`.

| Симптом | Причина / что смотреть |
|---|---|
| хендшейка нет, пакеты уходят | UDP-порт закрыт у провайдера/в файрволе VPS |
| `ping 10.66.66.2` не идёт | телефон не в туннеле или нет `-i wg0 -o wg0` в FORWARD |
| RDP не подключается, ping есть | профиль сети `wg-pc` = Public / нет правила RDP для интерфейса |
| ADB `offline` | на телефоне выключена беспроводная отладка |
| Claude не работает | туннель выключен на телефоне (WG заменяет v2rayNG, а не дополняет) |
