# HANDOFF: RMX3630 → дальнейшая работа в Termux

Обновлено: 2026-10-25, после реверса `powermonitor`/NLP.
Устройство: Realme 10 4G (RMX3630, MT6789), ColorOS `14.0.0.420(EX01)`,
Android 14, ядро `5.10.209-android12-9-o-05206-g23c1467af8f7`, слот `_a`,
SELinux Permissive, Magisk 30.7.

---

## 0. Главное, что нужно знать

1. **`com.oplus.powermonitor` — не поломка.** Его `selfKill` — штатная
   «boot memory opt»: первые ~13 минут после загрузки
   (`PolicyManager.DEF_BOOT_SILENCE_DURATION = 780000`) сервис стартует,
   проверяет `isAllowToWorkSinceBoot()`, вызывает `scheduleFinishSelf()` и
   убивает себя. Это не связано с отключёнными `deepthinker/healthservice/nas`.
2. **Реальный пожиратель CPU — `OplusMultiNlpHelper`** в
   `system_server`, поток `location.blockable`: десятки тысяч сообщений
   `what=101`, O(N²) разбор очереди, ошибки
   `No package ID ff found for resource ID 0xffffffff`. Причина — попытка
   резолвить пакеты из списка NLP
   (`com.oplus.location, com.google.android.gms, com.tencent.android.location,
   com.android.location.fused, com.amap.android.location, com.baidu.map.location`)
   при **выключенном GMS**.
3. Выключение локации (`location_mode=0`, `is-location-enabled=false`)
   **не помогло** — очередь уже была забита; после ребута цикл снова
   разошёлся (15k+ строк за 5 минут).
4. `pm enable --user 0` для `gms/gsf/exsystemservice/powermonitor`
   **не сохраняется**: после ребута эти пакеты снова в `disabled-user`
   (`enabled=3`). Похоже, на boot есть внешний «замораживатель»
   (кандидаты: `com.oplus.appplatform`, `com.oplus.customize.coreapp`,
   `com.oplus.athena`) — это надо найти.
5. Ядро в CI собралось, но **CRC FAIL** и лишний `+` в release; на телефон
   **не прошивалось** и прошивать нельзя до PASS.

Текущее (последнее измерение): `system_server` ~72%, `init` ~12%,
`logd` ~15%, `OplusMultiNlpHelper` продолжает писать, ток 130–540 мА.
Телефон греется. Это состояние **нестабильное**.

---

## 1. Доступ к устройству

Адрес, порт, параметры ADB и вспомогательные скрипты в публичную версию
не включены. Полная версия handoff хранится локально у владельца.

## 2. Диагностика текущего цикла

```bash
adb shell 'top -b -n1 -m 10'
adb shell 'dumpsys cpuinfo | head -20'
adb shell 'logcat -d | grep -c OplusMultiNlpHelper'
adb shell 'logcat -d | grep -iE "OplusMultiNlpHelper|No package ID ff" | tail -10'
adb shell 'logcat -d -b events | grep am_proc_died | tail -20'
adb shell 'pm list packages -d | grep -E "gms|gsf|powermonitor|exsystemservice"'
```

Признак активного цикла: счётчик `OplusMultiNlpHelper` растёт на сотни
строк в минуту, `system_server` >50%, `location.blockable` в `top -H`.

Проверить, кто именно возвращает пакеты в disabled:

```bash
adb logcat -d -b events | grep -iE "package|enabled|disabled" | tail -50
adb shell 'dumpsys package com.oplus.appplatform | head -40'
adb shell 'dumpsys package com.oplus.customize.coreapp | head -40'
adb shell 'ls -l /data/system/users/0/package-restrictions.xml'
```

Искать в логах boot-время: кто вызывает `setApplicationEnabledSetting`
или `pm disable`.

---

## 3. План стабилизации (по приоритету)

### Вариант A — оставить GMS включённым (быстрый и вероятно рабочий)

```bash
adb shell su -c '
  pm enable --user 0 com.google.android.gms
  pm enable --user 0 com.google.android.gsf
  pm enable --user 0 com.oplus.exsystemservice
  pm enable --user 0 com.oplus.powermonitor
'
adb shell 'pm list packages -d | grep -E "gms|gsf|powermonitor|exsystemservice"'
adb reboot
```

После ребута подождать 3–5 минут и проверить:

```bash
adb shell 'top -b -n1 -m 6'
adb shell 'logcat -d | grep -c OplusMultiNlpHelper'
```

Если `system_server` упал до <10% и счётчик NLP не растёт — стабильно.
Дальше можно блокировать телеметрию GMS сетевым firewall'ом, не отключая
пакет (см. раздел 6).

### Вариант B — GMS оставить выключенным, убрать GMS из NLP-списка

Сложнее: список `config_networkLocationProviderPackageNames` — ресурс
фреймворка/оверлея. Нужно либо править оверлей (Magisk), либо отключать
`com.oplus.location`/`com.android.location.fused` и проверять, не остаётся
ли ошибка `0xffffffff`. Пока не подтверждено, что это помогает.

### Вариант C — аварийный откат

Если после A всё ещё >50%:

```bash
adb shell su -c '
  pm enable --user 0 com.oplus.deepthinker
  pm enable --user 0 com.oplus.healthservice
  pm enable --user 0 com.oplus.nas
  pm enable --user 0 com.oplus.eyeprotect
  pm enable --user 0 com.oplus.gesture
  pm enable --user 0 com.heytap.mcs
  pm enable --user 0 com.oplus.customize.coreapp
'
adb reboot
```

Если и это не помогает — вернуть Google-стек целиком
(`gms/gsf/vending`) и/или рассматривать factory reset.

**Не отключать** `system_server`, `exsystemservice`, `powermonitor`,
`battery`, `athena`, `subsys`, `nhs`, `appplatform`,
`securitypermission`, `notificationmanager`.

---

## 4. Почему `pm enable` не держится

Наблюдение: команда отвечает `new state: enabled`, но после ребута пакет
снова `disabled-user` (`enabled=3`). Проверять сразу после enable и после
ребута. Искать enforcer:

- `com.oplus.appplatform` — управление приложениями/облачные политики;
- `com.oplus.customize.coreapp` — кастомизация/списки;
- `com.oplus.athena` — фоновое управление.

Если найден — либо отключить сам enforcer (рискованно), либо убрать
соответствующий конфиг/список, либо принять, что эти пакеты будут
выключены, и строить сервер без них.

---

## 5. Ядро: состояние CI

Репозиторий: <https://github.com/ea29ia/rmx3630-kernel-ci>

| run | результат |
|---|---|
| 40210216432 | FAIL: OEM include `kernel-5.10/...` не найден |
| 40212862431 | сборка успешна за 19м12с, но CRC gate **FAIL** |

Ключевые цифры CRC:

```
kernel-required symbols: 2024
  match 923, mismatch 1100, missing 1
stock modules analyzed: 232
modules that would fail: 232
```

Release собрался как
`5.10.209-android12-9-o-05206-g23c1467af8f7+` — лишний `+`
(git-dirty). Это ломает vermagic.

Причина: официальный исходник 5.10.198, устройство 5.10.209 + Oplus-патчи;
genksyms даёт другие CRC.

Что делать до флеша:
1. Убрать `+`: чистый temp-commit в CI или правка `scripts/setlocalversion`.
2. Добиться точного `uname -r` = сток.
3. Решить судьбу модулей: патч `__versions` (как
   `patch-module-crcs.py` в порте FDevNull), пересборка модулей или pmOS.
4. Только после PASS — `fastboot flash boot_a` с бэкапом.

Артефакты в CI: `Image`, `Image.gz`, `System.map`, `Module.symvers`,
`kernel.config`, `crc-report.txt`, `modules.tar.gz`.

---

## 6. Телеметрия и «закладки»: что уже известно

- `OplusMultiNlpHelper` сам по себе — не закладка, а кривой NLP-хелпер,
  но он перебирает локационные пакеты (Oplus/Google/Tencent/Amap/Baidu).
- `com.heytap.mcs` — push/статистика HeyTap, отключать можно (лист).
- `com.oplus.nas` — «ускорение сети», persistent, для сервера не нужен.
- `com.oplus.deepthinker` — AI-планировщик; отключение может рвать
  зависимости, не трогать без проверки.
- `com.oplus.exsystemservice` — хост `PowerMonitorNotifier`, не отключать.
- Полные отчёты агентов: `re/02-oplus-telemetry.md`,
  `re/03-vendor-backdoors.md` — **могли быть прерваны** (остановлены),
  проверяйте наличие/полноту. Надёжный отчёт только
  `re/01-powermonitor.md`.

Для блокировки телеметрии без отключения пакетов использовать
iptables/firewall по доменам/IP (после стабилизации), а не pm disable.

---

## 7. Файлы и артефакты

```
~/re/01-powermonitor.md          # реверс, доказательства, selfKill/NLP
~/re/decompiled/powermonitor/out # jadx-вывод
~/re/decompiled/exsystem/out
~/re/raw/                        # logcat/dumps/grep
~/re/apks/                       # APK + framework/services jar
~/re/02-oplus-telemetry.md       # может быть неполным (агент остановлен)
~/re/03-vendor-backdoors.md      # может быть неполным
~/rmx3630-status-report.md       # общий отчёт (см. поправку в конце)
~/4pda-report-bbcode.txt         # пост для 4PDA
~/rmx3630-kernel-ci/             # workflow, конфиг, expected CRC
~/debloat-removed-2026-10-25.txt
~/restore-debloat.sh
~/*.img                          # бэкапы boot/vendor_boot
```

Инструменты: jadx `/tmp/opencode/tools/jadx/bin/jadx` (может не пережить
очистку `/tmp` — тогда скачать jadx 1.5.6 заново).

---

## 8. Ограничения и предупреждения

- adb по TCP с root **без авторизации** — любой в LAN получает root.
  Ограничить iptables'ом или держать порт выключенным.
- Экран разбит: восстановление только adb/Preloader/BROM. Кнопочные
  комбинации вслепую.
- Не прошивать ядро/`boot_a` без бэкапа и без PASS CRC.
- Не делать массовый `pm disable-user` вендорных сервисов: dependency-граф
  ColorOS рвётся, а boot-time политика может возвращать пакеты обратно.
- `pm enable` проверять сразу и после ребута.

---

## 9. Ближайшие шаги в Termux

2. Проверить, кто возвращает `gms/gsf/powermonitor` в disabled
   (logcat boot, `package-restrictions.xml`).
3. Выполнить вариант A (GMS + exsystemservice + powermonitor), ребут,
   проверить, ушёл ли NLP-цикл.
4. Если ушёл — зафиксировать стабильную конфигурацию и **не трогать**
   Oplus core; телеметрию блокировать сетью.
5. Если не ушёл — вариант C/возврат Google-стека, затем решение о
   factory reset/pmOS.
6. Ядро: фикс `+`, решение по CRC/модулям; флеш только с разрешения.
