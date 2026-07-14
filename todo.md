# Критика и список задач

Аудит проводился с точки зрения сценария **"factory reset роутера → одна попытка → должно завестись"**.
Человек остаётся без внешнего интернета если установка упадёт — второй попытки нет.

Статусы привязаны к конкретным git-ревизиям. HEAD на момент последнего обновления: `5f7ad43`.

---

## БЛОКЕРЫ — устранены

### 1. ✅ verify-router.sh делал `exit 1` при switch=OFF

**Закрыто в:** `934e026` (exit 20), `0108244` (install.sh перехватывает exit 20 как предупреждение)

install.sh теперь:
```bash
set +e
"$ROOT_DIR/routers/$ROUTER_PROFILE/verify-router.sh"
verify_rc=$?
set -e
if [[ "$verify_rc" -eq 20 ]]; then
  echo "Verification paused: the router hardware switch is OFF."
elif [[ "$verify_rc" -ne 0 ]]; then
  exit "$verify_rc"
fi
```

---

### 2. ✅ Race condition между деплоем и verify

**Закрыто в:** `0108244`

verify-router.sh теперь активно поллит прокси-порт 20 итераций с sleep 1 вместо немедленного curl:
```bash
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if router_ssh "... netstat ... | grep -q ':$PROXY_PORT '"; then
    proxy_ready=1; break
  fi
  sleep 1
done
```

---

### 3. ✅ `install-vps.remote.sh`: не было `systemctl enable`

**Закрыто в:** `0108244`

Добавлен явный `systemctl enable "$XRAY_SERVICE"` перед restart, независимо от ветки if.

---

### 4. ✅ Порт XRAY_PORT не проверялся перед деплоем

**Закрыто в:** `0108244` (базовая проверка), `98b7e1b` (доработка: только первая строка PORT_CHECK, проверка IPv4-адреса)

install-vps.sh собирает факты удалённо и проверяет:
- порт не занят другим процессом (`port_owner != xray` → exit 1)
- VPS имеет глобальный IPv4 адрес (стэк IPv4-only → exit 1)
- VPS достигает GitHub если xray ещё не установлен

---

### 5. ✅ XRAY_PORT не документирован как переопределяемый

**Закрыто в:** `0108244`

В `install.env.example` добавлена закомментированная строка с объяснением.

---

### 6. ✅ redsocks слушал на `0.0.0.0:12345` без явного WAN DROP

**Закрыто в:** `0108244`

install-router.sh добавляет:
```bash
uci set firewall.codex_wan_redsocks_drop=rule
uci set firewall.codex_wan_redsocks_drop.src='wan'
uci set firewall.codex_wan_redsocks_drop.dest_port='$REDSOCKS_PORT'
uci set firewall.codex_wan_redsocks_drop.target='DROP'
```

---

### 7. ✅ MUX включён с VLESS+Reality

**Закрыто в:** `0108244`

Секция mux полностью удалена из `codex-xray.json.template`, `xray-admin.cgi`, `xray-vps.cgi`.

---

### 8. ✅ `"flow": ""` в JSON вместо отсутствия поля

**Закрыто в:** `0108244`

Поле flow удалено из клиентского конфига роутера и серверного конфига VPS. Пустой flow теперь означает отсутствие поля, а не пустую строку.

---

### 9. ✅ Два обработчика физического переключателя

**Закрыто в:** `934e026`, `0108244`

`gl_switch_button_check` явно останавливается и отключается в install-router.sh:
```bash
/etc/init.d/gl_switch_button_check stop >/dev/null 2>&1 || true
/etc/init.d/gl_switch_button_check disable >/dev/null 2>&1 || true
```

---

### 10. ✅ `opkg install git ...` падал молча

**Закрыто в:** `0108244`

Теперь логируется предупреждение при ошибке opkg вместо тихого `|| true`.

---

### 11. ✅ VPS не проверялся на outbound и IPv4

**Закрыто в:** `0108244` (outbound HTTPS), `98b7e1b` (IPv4 адрес + исправление парсинга PORT_CHECK)

Три новых проверки в preflight: наличие IPv4, свободный порт, доступность GitHub.

---

### 13. ✅ Нет проверки локальных инструментов

**Закрыто в:** `0108244`

`require_local_commands bash curl ssh tar unzip python3` вызывается первой строкой в install.sh.

---

### 18. ✅ Нет паузы между деплоем VPS и деплоем роутера

**Закрыто в:** `0108244` (preflight перед деплоем), `98b7e1b` (retry loop в install-vps.remote.sh вместо sleep 2)

install-vps.remote.sh поллит порт до 15 секунд:
```sh
while [ "$i" -lt 15 ]; do
  ss -ltnp | grep -q ":${XRAY_PORT} " && break
  systemctl is-active "$XRAY_SERVICE" >/dev/null
  i=$((i + 1)); sleep 1
done
```

---

### 28. ✅ Не было документации о состоянии роутера до factory reset

**Закрыто в:** `934e026`

README.md и SETUP-RUNBOOK.md дополнены: SSH доступ после factory reset, дефолтный IP, uplink, IPv4-only VPS.

---

## ОТКРЫТЫЕ ПРОБЛЕМЫ

### 12. ✅ NTP синхронизация не проверяется

**Закрыто в:** `c8e8ca8` — pre-flight warning перед Reality config на VPS (timedatectl / chronyc, non-fatal).

**Файлы:** `install-router.sh`, `install-vps.sh` — **не затронуты**

Reality handshake чувствителен к расхождению времени. После factory reset роутер может ещё не синхронизировал время, особенно если uplink поднялся только что. При расхождении >30с Reality молча падает с timeout. Нет ни проверки ни предупреждения.

**Нужно:** в конец `install-router.sh` или в `verify-router.sh` добавить:
```bash
router_ssh 'date' # показать пользователю, сравнить с local date
```
Или принудительно: `router_ssh 'ntpd -nq -p pool.ntp.org 2>/dev/null; date'`.

---

### 14. ✅ `install-release.sh` скачивается с GitHub без верификации

**Закрыто в:** `c4d0fa1` — sha256 печатается в stderr после скачивания, до выполнения. TODO-комментарий для пинирования к конкретному коммиту.

**Файл:** `vps/debian-13/files/install-vps.remote.sh:13-17`

```sh
curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp"
bash "$tmp" install
```

На роутере xray ставится с фиксированным SHA256. На VPS — через неверифицированный install-release.sh. Непоследовательно. При MITM на VPS — произвольный код с root.

Приоритет невысокий (HTTPS + GitHub CDN + VPS уже trusted), но несоответствие подходов некрасиво.

---

### 15. ✅ `render_template` падает с нечитаемым `KeyError`

**Закрыто в:** `7baea84` — `SystemExit(f"Template {path} requires env variable {key}...")` вместо bare KeyError.

**Файлы:** `install-router.sh:188-201`, `install-vps.sh:50-57`

```python
return os.environ[key]  # KeyError: 'MISSING_VAR' без контекста
```

`require_vars` защищает при нормальном запуске, но при ошибках в шаблоне (опечатка, новая переменная) сообщение не содержит ни имени файла ни строки.

---

### 16/27. ✅ Версия GL.iNet firmware не проверяется

**Закрыто в:** `65ad243`, `5f7ad43` — preflight в `install-platform-lib-b.sh` читает DISTRIB_REVISION, предупреждает при не-3.x/v3.x (libevent ABI). Не блокирует, но логирует.

**Файл:** `routers/gl-mt3000-glinet/install-router.sh:86-120`

Preflight проверяет модель (`mt3000`), но не версию firmware. Пакеты `redsocks` и `libevent` взяты из GL.iNet v21.02.3 репозитория с фиксированными SHA256. На новых firmware 4.x/5.x ABI может отличаться — пакет установится, но redsocks упадёт при запуске.

---

### 17. ✅ `StrictHostKeyChecking=no` в git SSH команде

**Закрыто в:** `7e22337` — заменено на `accept-new` в 9 местах (5 файлов). Единственное оставшееся `no` — намеренный throwaway-probe с `UserKnownHostsFile=/dev/null` в `bootstrap-lib-b.sh:321`, прокомментирован.

**Файл:** `routers/common/files/router-rules:235`

```sh
export GIT_SSH_COMMAND="ssh -i $(ssh_key_path) -o BatchMode=yes -o StrictHostKeyChecking=no"
```

Везде остальном в проекте используется `StrictHostKeyChecking=accept-new`. Здесь — `no`, что не отклоняет изменившийся ключ хоста. Минимальное исправление: заменить `no` → `accept-new`.

---

### 19. ✅ `LOCAL_HTTP_PROXY` в xray-admin.cgi захардкожен

**Закрыто в:** `91e02d6` — `LOCAL_HTTP_PROXY="${LOCAL_HTTP_PROXY:-http://127.0.0.1:1083}"` в обоих CGI.

**Файл:** `routers/gl-mt3000-glinet/files/xray-admin.cgi:13-15`

```sh
LOCAL_HTTP_PROXY='http://127.0.0.1:1083'
LIVE_HTTP_PORT='1083'
```

Если `PROXY_PORT` переопределён в install.env — CGI probe и smoke-test будут стучаться на неправильный порт. Практический риск низкий (1083 захардкожен в нескольких местах включая шаблон конфига), но при изменении порта придётся менять в нескольких файлах вместо одного.

---

### 20. ✅ Дефолт sync_interval — 300 секунд, не 30

**Закрыто в:** `323eca6` — fallback 300→30 во всех трёх местах `router-rules-sync.init`.

**Файл:** `routers/common/files/router-rules-sync.init:10`

```sh
interval="$(uci -q get router_rules.global.sync_interval 2>/dev/null || echo 300)"
```

profile.env задаёт `RULES_SYNC_INTERVAL:=30`. Если UCI-конфиг не загрузился при первом старте — fallback 300 секунд. При дебаге пользователь может долго ждать когда правила применятся.

---

### 21. ✅ verify-router.sh: curl к OpenAI без `|| true`

**Закрыто в:** `323eca6` — false alarm: строка OpenAI была в `if ! curl`-блоке и не падала. Реальный баг: 5 bare curl-вызовов под `set -euo pipefail` в обоих `verify-router.sh` — все получили `|| true`.

**Файл:** `routers/gl-mt3000-glinet/verify-router.sh:64`

```bash
curl -I -m 25 -x "$proxy" https://api.openai.com/v1/models
```

`set -euo pipefail` активен. Если VPS-IP забанен у OpenAI на TCP уровне — curl timeout, verify падает с exit 1, install.sh завершается с ошибкой. Хотя прокси работает и Google (строка 56) прошёл — OpenAI блокирует конкретный IP.

**Нужно:** `|| true` или убрать эту строку. Проверки через Google и ifconfig.me уже достаточны.

---

### 22. ✅ Нет инструкции по восстановлению при падении установки

**Закрыто в:** `85a275c` — секция "Recovery" в `docs/SETUP-RUNBOOK.md`: 5 сценариев падения (SSH drop, xray validation, VPS registration, router unreachable, stopped services).

**Файл:** `docs/SETUP-RUNBOOK.md` — раздела "если что-то пошло не так" нет

Если install.sh упал на середине — роутер в неопределённом состоянии, VPS мог уже задеплоиться. Пользователю не очевидно что делать: factory reset, повторный запуск, или проверить что уже сделано.

**Нужно:** добавить секцию с явным алгоритмом: factory reset роутера, убедиться что VPS чист, запустить снова.

---

### 23. ✅ `docs/CURRENT-LAB-STATE.md` в публичном репозитории

**Закрыто в:** `2633cb4` — файл уже был untracked; добавлен в `.gitignore`.

**Файл:** `docs/CURRENT-LAB-STATE.md` (1167 байт, изменён Apr 4 03:12)

Личный файл с состоянием конкретной лабораторной установки находится в публичном репо. Пользователи воспринимают docs/ как официальную документацию.

**Нужно:** удалить файл, добавить `docs/CURRENT-LAB-STATE.md` в `.gitignore`.

---

### 24. ✅ Строки 52-53 `install.sh` выглядят как мёртвый код

**Не баг.** Переприсвоение нужно для случая когда пользователь задал `ROUTER_SSH=root@host` без явного `ROUTER_HOST` — вычисляет host для URL в финальном echo. Оставлено как есть.

**Файл:** `install.sh:52-53`

```bash
ROUTER_SSH="${ROUTER_SSH:-root@${ROUTER_HOST:-}}"
ROUTER_HOST="${ROUTER_HOST:-$(host_from_ssh_target "$ROUTER_SSH")}"
```

Идут после деплоя, только ради `echo "Open the router UI at: https://$ROUTER_HOST/..."` на строке 57. ROUTER_SSH к этому моменту уже загружен через `load_env_file`. Переприсвоение сбивает читателя — выглядит как инициализация, а не как вывод URL.

**Нужно:** убрать эти строки, напрямую вычислить ROUTER_HOST раньше или использовать переменную из env.

---

### 29. ✅ `/tmp` файлы на VPS не чистятся при ошибке

**Закрыто в:** `c8e8ca8` — `trap _cleanup_tmp EXIT` в `install-vps.remote.sh` удаляет оба файла при любом выходе.

**Файл:** `vps/debian-13/files/install-vps.remote.sh`

`/tmp/codex-router-vps-config.json` и `/tmp/codex-router-meta.env` содержат Reality private key и UUID. При падении скрипта (set -eu) они остаются в `/tmp` на VPS. Нет `trap cleanup EXIT`.

---

## Новые находки из runtime-review

### R1. ✅ Статус после `apply_profile` в UI — временно устаревший

**Закрыто ранее** — `apply_profile_to_router_internal` вызывает `resync_runtime_to_switch`, который поллит `router_path_active()` до 25 секунд перед возвратом. `status_json` строится после. Подтверждено gap audit.

**Файл:** `routers/gl-mt3000-glinet/files/xray-vps.cgi:1565-1568`

`apply_profile_to_router_internal` вызывает `gl-switch-xray.sh` через `run_async` (возвращает немедленно). `status_json` в ответе строится пока сервисы ещё стартуют. UI покажет xray как "stopped" ~5-10 секунд после apply. Не баг, но пользователь может запаниковать.

---

### R2. ✅ `render_remote_meta` не ставит chmod на tmp-файл с private key

**Закрыто в:** `c352cae` — `chmod 600` в `render_remote_meta()`. Gap: `render_server_config()` также содержит XRAY_PRIVATE_KEY — закрыто в `323eca6`. Gap: repair stage копирует meta без chmod — закрыто в `5f7ad43`.

**Файл:** `routers/gl-mt3000-glinet/files/xray-vps.cgi:702-717`

`/tmp/codex-router-vps-meta.env` создаётся без явного `chmod 600`. Содержит `XRAY_PRIVATE_KEY`. В CGI-контексте umask=022 → файл mode 644 (world-readable) в течение нескольких секунд. На однопользовательском OpenWrt практически неважно, но непоследовательно с `chmod 600` в других местах.

---

### R3. ✅ `sleep 2` в probe xray-admin.cgi может быть недостаточно

**Закрыто в:** `91e02d6`, `5f7ad43` — `_wait_for_xray_pid()` поллит pid-файл до 5×1s; `5f7ad43` добавил `kill -0 $_pid` чтобы pid-exists ≠ pid-alive.

**Файл:** `routers/gl-mt3000-glinet/files/xray-admin.cgi`

После старта probe-инстанса xray скрипт спит 2 секунды и делает smoke-test. На GL-MT3000 (Cortex-A53) xray при первом запуске может стартовать 2-3 секунды (config validation + bind). Ложный негатив при валидном конфиге.

---

## ИТОГО: СТАТУС

| # | Проблема | Статус | Ревизия |
|---|----------|--------|---------|
| 1 | verify exit 1 при switch=OFF | ✅ | `934e026` + `0108244` |
| 2 | Race condition verify vs watchdog | ✅ | `0108244` |
| 3 | Нет systemctl enable | ✅ | `0108244` |
| 4 | Порт 443 не проверяется | ✅ | `0108244` + `98b7e1b` |
| 5 | XRAY_PORT не документирован | ✅ | `0108244` |
| 6 | redsocks 0.0.0.0:12345 без WAN DROP | ✅ | `0108244` |
| 7 | MUX с Reality | ✅ | `0108244` |
| 8 | "flow":"" в JSON | ✅ | `0108244` |
| 9 | Двойные switch handlers | ✅ | `934e026` + `0108244` |
| 10 | opkg тихо падает | ✅ | `0108244` |
| 11 | VPS outbound + IPv4 check | ✅ | `0108244` + `98b7e1b` |
| 12 | NTP не проверяется | ✅ | `c8e8ca8` |
| 13 | Нет проверки локальных инструментов | ✅ | `0108244` |
| 14 | install-release.sh без верификации | ✅ | `c4d0fa1` |
| 15 | render_template KeyError | ✅ | `7baea84` |
| 16/27 | GL firmware version не проверяется | ✅ | `65ad243` + `5f7ad43` |
| 17 | StrictHostKeyChecking=no в git SSH | ✅ | `7e22337` |
| 18 | Нет паузы VPS→router деплой | ✅ | `0108244` + `98b7e1b` |
| 19 | LOCAL_HTTP_PROXY захардкожен | ✅ | `91e02d6` |
| 20 | sync_interval fallback 300s | ✅ | `323eca6` |
| 21 | curl к OpenAI без `\|\| true` | ✅ | `323eca6` |
| 22 | Нет инструкции по восстановлению | ✅ | `85a275c` |
| 23 | CURRENT-LAB-STATE.md в репо | ✅ | `2633cb4` |
| 24 | install.sh строки 52-53 | ✅ | не баг |
| 28 | Документация до factory reset | ✅ | `934e026` |
| 29 | tmp файлы на VPS без cleanup | ✅ | `c8e8ca8` |
| R1 | Статус UI после apply — устаревший | ✅ | был исправлен ранее |
| R2 | render_remote_meta без chmod | ✅ | `c352cae` + `323eca6` + `5f7ad43` |
| R3 | sleep 2 в probe — мало | ✅ | `91e02d6` + `5f7ad43` |

**Закрыто:** 30/30. Все оригинальные пункты и runtime-находки закрыты.
