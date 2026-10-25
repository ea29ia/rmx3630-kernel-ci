# RMX3630: статус телефона и сборки ядра

Дата: 2026-10-25. Устройство: Realme 10 4G (RMX3630, MT6789), прошивка
`RMX3630_14.0.0.420(EX01)`, Android 14 (API 34), ядро
`5.10.209-android12-9-o-05206-g23c1467af8f7`, слот `_a`,
`verifiedbootstate=orange`, SELinux `Permissive`.

---

## 1. Коротко

- Телефон разлочен и рутирован (Magisk 30.7), доступен по сети; детали
  доступа в публичную версию не включены.
- Экран физически разбит, но программно выключен: DPMS Off, подсветка 0,
  DSI-клоки 0, панель не потребляет. Тач-IRQ почти не растёт — дигитайзер
  фактически мёртв вместе с панелью.
- Bluetooth, NFC, мобильная сеть и Google-сервисы выключены.
- После экспериментов с вендорными Oplus-сервисами телефон ушёл в цикл
  `com.oplus.powermonitor` (selfKill → перезапуск), из-за чего
  `system_server` держит 60–170% CPU. Часть последних изменений была
  прервана, поэтому текущее состояние требует проверки/отката (раздел 5).
- Ядро в GitHub Actions **собралось** (19 мин), но проверка совместимости со
  стоковыми модулями дала **FAIL**: 923 CRC совпали, 1100 разошлись,
  232 из 232 модулей не загрузятся. Плюс release-строка получила лишний `+`.
  На телефон ядро **не прошивалось**.

---

## 2. Телефон: что сделано

### 2.1 Разблокировка и root

- Разблокировка: `seccfg lock_state=3` + зеркало boot-info в RPMB
  (`locked=0`), переживает ребут. LK подтверждает:
  `double_check_lock_state ... boot normal`, `img_auth_required = 0`,
  `avb_ret = 0`.
- Root без эксплойта ядра: 31 байт в cmdline заголовка `vendor_boot`
  (`" androidboot.selinux=permissive"`, поле `0x1C`, файл `0x44..0x62`).
  После этого `adb root` даёт `uid=0`, `u:r:su:s0`.
- Magisk 30.7: патч vendor-рамдиска через `magiskboot`; `su` →
  `uid=0 u:r:magisk:s0`.
- `vendor_boot` v23 (текущий): `6f835b07a684ba4d443d3c65ccc3b87e`.
  Бэкапы стоковых `boot_a`/`vendor_boot_a` лежат в `~/`.

### 2.2 Сеть и доступ

Адрес, порт и параметры ADB в публичную версию не включены. Полная
операционная версия отчёта хранится локально у владельца.
### 2.3 Деблоат

- Удалено 53 системных пакета (`pm uninstall --user 0`), 306 → 253.
- Списки и откат: `~/debloat-removed-2026-10-25.txt`,
  `~/restore-debloat.sh`.
- Дополнительно отключено (см. 2.5).

### 2.4 Экран и питание

Проверено на устройстве:

```
mWakefulness=Asleep
Display State=OFF, dpms=Off
lcd-backlight=0 / 4095
DSI: mipi_tx0_pll, mm_dsi0, dsi_occ_ck — enable=0
Регуляторы панели: 0 mA
touch-00: 3 прерывания за всё время аптайма
oplus_display esd=0
```

Настройки:

```
screen_off_timeout=15000
screen_brightness=0 (manual)
doze_enabled=0, doze_always_on=0
wake_gesture_enabled=0
stay_on_while_plugged_in=0
```

Итог: экран сейчас не потребляет; `screen: 17.7 mAh` в batterystats —
историческое (6 мин включённого экрана до этого).

### 2.5 Отключённые сервисы

| что | состояние |
|---|---|
| Bluetooth | `cmd bluetooth_manager disable`, `bluetooth_on=0`, state OFF |
| NFC | `svc nfc disable`, `nfc_on=0`, `pm disable-user com.android.nfc` |
| Мобильная сеть | `airplane_mode_on=1`, `mobile_data=0`, `mobile_data_always_active=0`, `data_roaming=0` |
| Google | disabled-user: `gms`, `gsf`, `vending`, `as.oss`, `tts`, `switchaccess`, `talkback`, `hotspot2.osulogin`, `cellbroadcastreceiver`, `cellbroadcastservice` |
| Ранее | `com.google.android.inputmethod.latin`, `com.google.android.setupwizard` |

После ребута эти состояния сохранились. Wi-Fi и adb при этом работают.

---

## 3. Потребление и нагрузка

Измерения `current_now` очень шумные (0…567 мА), среднее в стабильном
состоянии было ~120–150 мА. `dumpsys batterystats` за ~50 мин:

```
Computed drain: 150 mAh
  screen        17.7 mAh   (историческое)
  idle           2.05 mAh
  wakelock       0.475 mAh
  wifi           0.0448 mAh
  mobile_radio   0.0219 mAh
```

Основные наблюдаемые потребители/пробуждения:

- `WLAN timeout/hif_thread/main_thread/interrupt` — главные wakelocks;
  за 79 мин аптайма WLAN держал систему ~42 мин.
- `android.system.suspend-service` (autosuspend) — 11–18% CPU,
  churn suspend/resume; были `200 fail`, `last_failed_dev=alarmtimer.1.auto`.
- `logd` — 10–14% CPU из-за огромного потока kernel-логов WLAN
  (`dmesg` ~29k строк, `kalPerMonUpdate` раз в секунду).
- RIL/Volte (`mtkfusionrild`, `volte_stack`, `gsm0710muxd`) — по ~0.5–3%.
- Вендорные Oplus HAL/сервисы — постоянно висят, часть можно не трогать.
- `wfca` (вендорный Wi-Fi демон), `kworker/u16`, `ufs_clk_gating` — по ~3%.

Вывод: «пожирателя»-экрана нет; расход — это постоянно бодрствующий Wi-Fi +
Android-фон + suspend churn. Наибольший практический выигрыш даст
**USB Ethernet и выключение Wi-Fi**, а не дальнейшее убийство пакетов.

---

## 4. Инцидент со стабильностью (важно)

После партии отключений Oplus-сервисов и перезагрузки:

- `com.oplus.powermonitor` начал цикл: старт → `PowerMonitor selfKill` →
  рестарт каждые 3–6 секунд (19 смертей за ~15 мин).
- `com.oplus.exsystemservice` (PowerMonitorNotifier) повторно поднимает его
  по screen-off событию.
- `system_server` держит 60–174% CPU, `init second_stage` 15–20%,
  `logd` 12–17%; телефон греется, ток растёт.
- Попытки `pm enable` без `--user 0` не сохранялись после ребута;
  повторные `pm enable --user 0` вернули пакеты, но цикл powermonitor
  сохранялся.
- Последняя команда (disable `com.heytap.mcs`, kill процесса) была
  **прервана**, поэтому состояние могло примениться частично.
- `com.oplus.exsystemservice` и `com.oplus.powermonitor` в последнем
  выполненном шаге были переведены в `disabled-user`.

Текущее состояние следует считать **непроверенным**; телефон может
продолжать грузить CPU. Это не связано с ядром — ядро не прошивалось.

### 4.1 Быстрый откат к стабильному состоянию

С любого adb-хоста (USB или Wi-Fi):

```bash
adb shell su -c '
  pm enable --user 0 com.oplus.exsystemservice
  pm enable --user 0 com.oplus.powermonitor
  pm enable --user 0 com.heytap.mcs
  pm enable --user 0 com.oplus.nas
  pm enable --user 0 com.oplus.healthservice
  pm enable --user 0 com.oplus.eyeprotect
  pm enable --user 0 com.oplus.gesture
  pm enable --user 0 com.oplus.leftscreen
  pm enable --user 0 com.coloros.alarmclock
  am force-stop com.oplus.powermonitor
'
adb reboot
```

Если после ребута `system_server` всё ещё >50%:

```bash
adb shell 'logcat -d -b events | grep am_proc_died | tail -20'
adb shell 'top -b -n1 -m 10'
adb shell 'dumpsys cpuinfo | head -20'
```

Проверить, кто именно умирает/перезапускается, и **не отключать**
зависимости powermonitor (deepthinker/healthservice/nas/exsystemservice).

Если стабильность не возвращается — вернуть и Google-стек:

```bash
adb shell su -c '
  for p in com.google.android.gms com.google.android.gsf com.android.vending \
           com.google.android.as.oss com.google.android.tts \
           com.google.android.cellbroadcastreceiver \
           com.google.android.cellbroadcastservice; do pm enable --user 0 "$p"; done
'
adb reboot
```

---

## 5. Сборка ядра

### 5.1 Цель

Добавить в ядро то, чего нет в стоковом конфиге, сохранив загрузку
стоковых вендорных модулей (Wi-Fi, камера, тач и т.д.):

```
CONFIG_PID_NS, CONFIG_IPC_NS, CONFIG_USER_NS
CONFIG_SYSVIPC, CONFIG_POSIX_MQUEUE
CONFIG_CGROUP_PIDS, CONFIG_CGROUP_DEVICE
CONFIG_VXLAN, CONFIG_MACVLAN, CONFIG_IPVLAN, CONFIG_BRIDGE_NETFILTER
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
```

Без этого Docker/runc на стоковом ядре невозможен: `unshare -p/-i/-U`
возвращает `EINVAL`, pids/devices cgroup отсутствуют.

### 5.2 Что сделано

- Репозиторий: <https://github.com/ea29ia/rmx3630-kernel-ci> (public).
- База: официальные `realme-kernel-opensource/realme10-AndroidU-kernel-source`
  (5.10.198, commit `01f8dc9`) + `realme10-AndroidU-vendor-source`
  (`e92b9be`).
- Тулчейн: Android clang `r416183b` (12.0.5), как у стока.
- Конфиг: снят с устройства (`/proc/config.gz`) + правки:
  LTO thin, `DEBUG_INFO` off (иначе 2-ядерный раннер не укладывается),
  версия принудительно `5.10.209` + `LOCALVERSION`.
- Артефакты: `Image`, `Image.gz`, `System.map`, `Module.symvers`,
  `kernel.config`, `crc-report.txt`, `modules.tar.gz`.

### 5.3 Результаты прогонов

| run | результат | причина |
|---|---|---|
| [40210216432](https://github.com/ea29ia/rmx3630-kernel-ci/actions/runs/40210216432) | FAIL через 25м49с | OEM include `../../../../kernel-5.10/drivers/power/supply/charger_class.h` не найден |
| [40212862431](https://github.com/ea29ia/rmx3630-kernel-ci/actions/runs/40212862431) | **успех, 19м12с** | после фикса symlink `vendor/kernel-5.10 -> kernel` |

Артефакт: 62 291 327 байт (`rmx3630-kernel-2`), скачивание целиком
не завершилось из-за размера, но отчёт есть в логах CI.

### 5.4 CRC-отчёт (главное)

```
kernel-required symbols: 2024
  present, CRC match : 923
  CRC mismatch       : 1100
  missing            : 1
stock modules analyzed: 232
modules that would fail to load: 232
VERDICT: FAIL
```

Примеры: `__alloc_pages_nodemask` expected `cfd14bde`, built `2e58927e`;
`__alloc_skb` expected `bcf85bc0`, built `20e8c7da`.

Дополнительно release-строка собралась как:

```
5.10.209-android12-9-o-05206-g23c1467af8f7+
```

Лишний `+` — git-dirty worktree (`setlocalversion`), то есть даже vermagic
не совпадёт со стоковыми модулями.

### 5.5 Почему FAIL

- Опубликован исходник **5.10.198**, телефон работает на **5.10.209**
  (11 stable-релизов + Oplus-патчи позже публикации).
- CRC в `__versions` считаются genksyms из типов; у Oplus/MTK-кода
  меняются структуры/прототипы → почти все CRC расходятся.
- KMI-совместимость тут не спасает: вендорные модули собраны под
  конкретный OEM-ревизион, а не под чистый ACK.
- Плюс `+` в release ломает vermagic.

### 5.6 Варианты продолжения

1. **Патчить `__versions` стоковых модулей** под CRC нашего ядра
   (как делает порт FDevNull в `scripts/patch-module-crcs.py`).
   Плюс: быстро; минус: ABI-риск, 232 модуля, доставка модулей на сток
   (vendor_dlkm/verity или Magisk overlay) — отдельная проблема.
2. **Пересобрать модули из того же дерева** и доставить их:
   проще в pmOS (ext4 root), сложнее на Android (vendor_dlkm).
3. **Найти/дождаться исходника ровно 5.10.209** (на GitHub у Realme
   только 5.10.198; AndroidT — 5.10.110).
4. **pmOS downstream + наше ядро** — там rootfs writable, модули можно
   подменять без verity; но установка стирает Android и требует
   Preloader/UnlockTool.
5. Отказаться от Docker на Android и оставить chroot-сервисы + текущий
   рут (наименьший риск).

Перед любым флешем:
- убрать `+` из release (чистый temp-commit в CI или правка
  `scripts/setlocalversion`);
- проверить, что `uname -r` после сборки **точно**
  `5.10.209-android12-9-o-05206-g23c1467af8f7`;
- прогнать CRC-отчёт после патча/пересборки модулей;
- только потом `fastboot flash boot_a` с бэкапом.

---

## 6. Риски и ограничения

- adb по TCP с root и без авторизации — доступ любому в LAN.
- SELinux Permissive глобально — Play Integrity/банки могут ругаться.
- Деблоат удалил OTA-сервисы; обновления не приходят.
- Экран мёртв: восстановление только через adb/Preloader/BROM.
- Эксперименты с Oplus-сервисами показали: отключение «лишнего» может
  уронить system_server в цикл. Массовый debloat Oplus — только по одному
  пакету с проверкой.
- Ядро из CI **не проверено на устройстве**; артефакт не прошивался.

---

## 7. Следующие шаги

1. **Стабилизировать телефон**: выполнить откат из 4.1, ребут, убедиться,
   что `system_server` <10% и `am_proc_died` не содержит powermonitor.
2. Зафиксировать стабильный набор отключений (BT/NFC/mobile/Google) и
   **не трогать** Oplus core.
3. Для экономии: USB Ethernet + выключить Wi-Fi; лимит заряда 80%.
4. По ядру: решить, идём ли в вариант 1/2/4; при варианте 1 — подготовить
   патчер CRC и набор модулей, при варианте 4 — план миграции в pmOS.
5. Прошивка `boot_a` — только после отдельного подтверждения и чистого
   CRC-отчёта.

---

## 8. Ссылки и артефакты

- CI: <https://github.com/ea29ia/rmx3630-kernel-ci>
- Успешный прогон: <https://github.com/ea29ia/rmx3630-kernel-ci/actions/runs/40212862431>
- Неуспешный прогон: <https://github.com/ea29ia/rmx3630-kernel-ci/actions/runs/40210216432>
- Порт pmOS: <https://github.com/FDevNull/realme-rmx3630-postmarketos>
- Официальные исходники:
  <https://github.com/realme-kernel-opensource/realme10-AndroidU-kernel-source>,
  <https://github.com/realme-kernel-opensource/realme10-AndroidU-vendor-source>
- Локальные материалы:
  - `~/mtkclient/docs/notes/reverse/` — заметки по руту/ядру/модулям;
  - `~/debloat-removed-2026-10-25.txt`, `~/restore-debloat.sh`;
  - `~/4pda-report-bbcode.txt` — пост для 4PDA;
  - `~/rmx3630-kernel-ci/` — workflow, конфиг, expected CRC.

---

## 9. Поправка после реверса (2026-10-25, Agent 1)

Раздел 4 (гипотеза «мы сломали зависимости powermonitor») **опровергнут**
разбором кода и логов.

### 9.1 Что оказалось на самом деле

- `com.oplus.powermonitor` не падает: его `selfKill` — **штатная boot-политика
  «boot memory opt»**. `PowerStatsService.onStartCommand()` проверяет
  `!isAllowToWorkSinceBoot()` → `scheduleFinishSelf(1000, true)` →
  `stopSelfNow(true)` → `ServiceLifeManager` → `Process.killProcess(myPid)`.
  Константа `PolicyManager.DEF_BOOT_SILENCE_DURATION = 780000` (13 минут)
  зашита в код, не настройка.
- В коде selfKill нет ссылок на `deepthinker/healthservice/nas/eyeprotect/
  gesture/mcs`; к моменту ручного `pm disable-user` петля уже закончилась
  сама (13-я минута uptime).
- Перезапуски делал `com.oplus.exsystemservice`
  (`OplusPowerConsumedMonitorService`), но это следствие, а не причина
  нагрузки.
- **Реальный пожиратель CPU** — `OplusMultiNlpHelper` в `system_server`,
  поток `location.blockable`: десятки тысяч сообщений `what=101`,
  O(N²)-разбор очереди, `No package ID ff found for resource ID 0xffffffff`.
  Причина — список NLP-пакетов
  (`com.oplus.location, com.google.android.gms, com.tencent.android.location,
  com.android.location.fused, com.amap.android.location, com.baidu.map.location`)
  и **выключенный GMS**.

### 9.2 Что проверено после этого

- `location_mode=0`, `is-location-enabled=false` — не помогло: очередь уже
  была забита, после ребута цикл разошёлся заново (15k+ строк за 5 минут).
- `pm enable --user 0 com.google.android.gms/gsf` отвечает «enabled», но
  после ребута пакеты снова `disabled-user` (`enabled=3`). То же для
  `com.oplus.exsystemservice`/`powermonitor`. Значит, на boot есть внешний
  «замораживатель» (кандидаты: `appplatform`, `customize.coreapp`, `athena`).
- Последнее состояние: `system_server` ~72–77%, NLP-счётчик ~14.7k,
  `gms/gsf/powermonitor/exsystemservice` в disabled, локация off,
  BT/NFC/mobile off, экран off, ток 130–540 мА.

### 9.3 Правильный следующий шаг

1. Найти boot-enforcer, который возвращает пакеты в disabled
   (`logcat -b events` при загрузке, `package-restrictions.xml`,
   `dumpsys package com.oplus.appplatform/customize.coreapp`).
2. Либо оставить GMS включённым (тогда NLP-цикл должен уйти), либо убрать
   GMS из NLP-списка (оверлей/фреймворк) — это сложнее.
3. После стабилизации — не трогать Oplus core; телеметрию блокировать
   сетью, а не `pm disable-user`.
4. Ядро: см. раздел 5; без PASS CRC и точного release — не прошивать.

Подробный handoff для Termux: `~/HANDOFF.md`
(он же `~/re/HANDOFF.md`).
Реверс powermonitor: `~/re/01-powermonitor.md`.
Аудит vendor: `~/re/03-vendor-backdoors.md` (агент остановлен,
отчёт может быть неполным). Oplus-telemetry отчёт не создан (агент
отменён).
