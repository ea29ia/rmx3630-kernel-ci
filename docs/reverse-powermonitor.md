# PowerMonitor self-kill loop на Realme 10 (RMX3630, ColorOS 14 / Android 14, MT6789)

Дата разбора: 2026-10-25. Устройство: `RMX3630`, сборка `S.1cb668d-1`, ColorOS 14.0.0.420(EX01).
Работа велась **только read-only** по adb TCP: `logcat`, `dumpsys`, `getprop`, `settings list`, чтение `/proc`, `stat` файлов. Ничего не включалось/выключалось, ребута не было.

---

## 1. Краткий handoff (TL;DR)

1. **Петля PowerMonitor — это не «поломка», а штатная «boot memory opt» политика, растянутая на 13 минут после загрузки.**
   `PowerStatsService.onStartCommand()` при `SystemClock.elapsedRealtime() <= 780000` (13 мин) вызывает
   `scheduleFinishSelf(1000, true)` → через 1 с `stopSelfNow(true)` → `stopSelf()` + `ServiceLifeManager.g()` →
   `Process.killProcess(Process.myPid())`. Краш-буфера/ANR/`lmkd` при этом нет — процесс убивает сам себя.
2. **Триггер перезапусков — `com.oplus.exsystemservice`:** `OplusPowerConsumedMonitorService` ловит `SCREEN_OFF`,
   через 60 с дергает `PowerMonitorNotifier`, тот делает `bindServiceAsUser(PowerStatsService, BIND_AUTO_CREATE)`.
   Дальше AMS перезапускает сервис/процесс (в логах `Start proc ... for service {...PowerStatsService}`,
   `onServiceConnected` без нового `bind`), сервис снова себя убивает — до конца 13-минутного окна.
3. **Отключение `deepthinker / healthservice / nas / eyeprotect / gesture / mcs` к этой петле отношения не имеет.**
   В коде пути self-kill нет ни одной ссылки на эти пакеты (проверено grep'ом). Более того, по логам
   эти пакеты были **включены** (`enabled=1`), а `mcs` выключили в 13:38:35 — **после** того, как петля уже
   прекратилась (последняя смерть 13:33:30). `powermonitor` и `exsystemservice` отключили вручную в 13:34:49.
4. **Отдельный, более опасный дефект:** `system_server` сейчас жрёт 88–99 % ядра не из-за PowerMonitor,
   а из-за бесконечного цикла `OplusMultiNlpHelper` в потоке `location.blockable` (tid 2309):
   очередь `MessageQueue` распухла до >50 000 сообщений `what=101`, каждое сообщение снова дергает
   резолв NLP-провайдеров и печатает `No package ID ff found for resource ID 0xffffffff`.
   Сеть-провайдер локации выключен (`network provider: enabled=false`), `com.google.android.gms`
   в состоянии `enabled=3` (disabled). Причина/следствие здесь **выведены**, не доказаны по коду (см. §8).
5. **Безопасное лечение:** вернуть `pm enable com.oplus.exsystemservice`, затем `pm enable com.oplus.powermonitor`;
   для CPU — либо вернуть `com.google.android.gms`, либо выключить локацию, затем один ребут, чтобы очистить
   50-тысячную очередь сообщений. Петля PowerMonitor после ребута снова будет ≤13 мин (это by design), это нормально.
   **Нельзя** оставлять выключенными `exsystemservice` и `powermonitor` и нельзя трогать `system_server`/`services.jar`.

---

## 2. Артефакты

```
~/re/apks/                                  исходные apk/jar
~/re/decompiled/powermonitor/out/           jadx: PowerMonitor.apk (815 классов)
~/re/decompiled/exsystem/out/               jadx: OplusExSystemService.apk (3056 классов)
~/re/decompiled/powermonitor/key/           ключевые файлы, скопированные для handoff:
    ServiceLifeManager_y0_g.java
    PowerStatsService.java, PolicyManager.java
    PowerConnectionReceiver.java, BootCompletedRecevier.java, PMApplication.java
    exss_OplusPowerConsumedMonitorService_j5_b.java
    exss_PowerMonitorNotifier_j5_c.java, exss_j5_d.java
    AndroidManifest.xml
~/re/raw/
    logcat_full.txt (26 064 строки, 13:20:50–13:58), logcat_events.txt, logcat_crash.txt
    dumpsys_pkg_powermonitor.txt, dumpsys_pkg_exss.txt, dumpsys_services_pm.txt
    dumpsys_alarm.txt, dumpsys_location.txt, settings_list.txt, getprop.txt
    disabled_pkgs.txt, enabled_pkgs.txt
    grep_powermonitor_logcat.txt, code_evidence.txt, snapshot_final.txt
```

JADX: `/tmp/opencode/tools/jadx/bin/jadx`, Java 21. Оба apk разобраны полностью (были нефатальные ошибки
декомпиляции в не относящихся к делу классах).

---

## 3. Таймлайн (время устройства, EDT; boot ≈ 13:20:50)

| Время | Событие | Источник |
|---|---|---|
| 13:20:50 | загрузка (uptime 0) | `snapshot_final.txt` |
| 13:21:17.880 | `OplusAlarmAdjustment: MSG_SCREEN_OFF` — экран выключен | `logcat_full.txt` |
| 13:21:20.336 | `Start proc 5660:com.oplus.powermonitor/1000 for broadcast {…BootCompletedRecevier}` | AMS |
| 13:21:20.537 | `BootCompletedRecevier.d()` → `startService(PowerStatsService, EXTRA_COMMAND=5)` | `ContextImpl` WTF-стек |
| **13:21:21.760** | **`Process com.oplus.powermonitor (pid 5660) has died: fg SVC`** (через 1.42 с, без краша) | AMS |
| 13:21:22.771 | `Start proc 6008 … for service {…ChargeStatusService}` | AMS |
| 13:22:54.250 | `PowerMonitorNotifier: handleMessage: 20/0` → `onScreenOff: trying to connecting` | exsystem |
| 13:22:56.704 | pid 6008 died | AMS |
| 13:22:59.081 | `Start proc 8336 … for service {…PowerStatsService}` | AMS |
| 13:22:59 → 13:33:30 | **20 стартов / 19 смертей** процесса, время жизни 1.4–4.0 с | `logcat_events.txt` |
| 13:25:40.779→13:25:42.312 | пример: 1.53 с | events |
| 13:29:59.590→13:30:02.803 | пример: 3.21 с | events |
| **13:33:26.587 → 13:33:30** | последний старт/смерть; uptime = **12 мин 40 с** | events |
| 13:34:49.532 | `SetEnabledSetting(com.oplus.exsystemservice …, 3, 0)` — `pm disable-user` | PackageManager |
| 13:34:49.622 | `SetEnabledSetting(com.oplus.powermonitor …, 3, 0)` + `force-stop` | PackageManager/AMS |
| 13:34:49.657 | `Killing 22006:com.oplus.powermonitor … change com.oplus.powermonitor` (единственный AMS-kill!) | AMS |
| 13:38:35.361 | `SetEnabledSetting(com.heytap.mcs …, 3, 0)` | PackageManager |
| 13:39:19 / 13:39:41 / 13:42:26 | `Unable to start service Intent { act=…RESUME_POWER_MONITOR … } … not found` (живой exsystem бьётся в выключенный пакет) | AMS |
| ≈13:43:20 | начало роста очереди `what=101` (NLP), по `MessageQueue: searched … head message is {when=-10m58s…}` | `logcat` |
| 13:51:59 → сейчас | `OplusMultiNlpHelper` спам, 18 834 строки за минуту, ~200/с | `logcat` |
| 13:58:35 | `system_server` 88–99 % CPU, tid 2309 = 237 тиков за 3 с (79 % ядра), очередь >50 000 msg | `/proc` |

Ключевой факт: **петля закончилась в 13:33:30 сама**, за 79 с до ручного `pm disable-user`.
Следующий перезапуск должен был случиться уже после 13:33:50 (граница 13 мин), поэтому он бы выжил.
Ручное отключение в 13:34:49 просто совпало по времени и создало иллюзию «я выключил пакеты — петля ушла».

---

## 4. Код: точный путь selfKill

### 4.1 `ServiceLifeManager` — сам убийца

`~/re/decompiled/powermonitor/out/sources/y0/g.java`

```java
35:    private static long f3945g = 600000;      // deadline (10 мин), переопределяется RUS-конфигом
145:            Log.d("ServiceLifeManager", "PowerMonitor selfKill!");
146:            Process.killProcess(Process.myPid());
```

```java
174:    public void l() {
175:        synchronized (f3940b) {
176:            Log.d("ServiceLifeManager", "tryToSelfKill: ");
177:            if (f()) {                  // f() == (f3941c == 0), нет активных сервисов
178:                i();                    // sendEmptyMessageDelayed(1, 60000)
```

Т.е. это **рефкаунтер сервисов**: каждый сервис делает `b(TAG)` в `onCreate` и `h(TAG)` в `onDestroy`;
когда счётчик дошёл до 0 — через 60 с убивается процесс. Но в нашем случае до 60-секундного таймера
дело не доходит — есть прямой путь (см. 4.3).

### 4.2 `PowerStatsService.onStartCommand()` — «boot memory opt»

`.../standbymonitor/powerstats/PowerStatsService.java`

```java
1809:        Log.d(TAG, "onStartCommand end");
1810:        if (!this.mPolicyManager.isAllowToWorkSinceBoot()) {
1811:            scheduleFinishSelf(1000L, true);
1812:        }
1813:        return 1;
```

```java
1100:    public void scheduleFinishSelf(long j2, boolean z2) {
1101:        Log.d(TAG, "scheduleFinishSelf " + j2);
...
1105:        Message messageObtainMessage = this.mPowerStatsHandler.obtainMessage(11);
1106:        messageObtainMessage.obj = Boolean.valueOf(z2);
1107:        this.mPowerStatsHandler.sendMessageDelayed(messageObtainMessage, j2);
```

```java
 562:                        if (!PowerStatsService.this.mPolicyManager.isAllowToWorkSinceBoot()) {
 563:                            str = PowerStatsService.TAG;
 564:                            str2 = "stop self for boot memory opt";
...
 572:                        Log.d(str, str2);
 573:                        PowerStatsService.this.stopSelfNow(zBooleanValue);
```

```java
1837:    public void stopSelfNow(boolean z2) {
1838:        if (this.mPolicyManager.stopSelfWhenSrnIdle() || z2) {
1839:            stopSelf();
1840:            g.c().h(TAG);
1841:            if (z2) {
1842:                g.c().g();          // -> "PowerMonitor selfKill!" -> killProcess
1843:            }
```

`onCreate`/`onDestroy` берут/отпускают тег:

```java
1741:        g.c().b(TAG, false);
1751:        g.c().h(TAG);
```

### 4.3 `PolicyManager` — те самые 13 минут

`.../powerstats/PolicyManager.java`

```java
 24:    public static final long DEF_BOOT_SILENCE_DURATION = 780000;   // 13 min
 86:    private boolean mStopSelfWhenSrnIdle = true;

432:    public boolean isAllowToWorkSinceBoot() {
433:        if (this.mDebugMode) {
434:            return true;
435:        }
436:        boolean z2 = SystemClock.elapsedRealtime() > DEF_BOOT_SILENCE_DURATION;
437:        Log.d(TAG, "isAllowToWorkSinceBoot:" + z2);
438:        return z2;
439:    }
```

**Это константа в коде, а не настройка.** Отключение любых пакетов её не меняет.
`mStopSelfWhenSrnIdle` по умолчанию `true`, т.е. `stopSelf()` вызывается всегда.

### 4.4 Кто стартует сервис

`BootCompletedRecevier.java` (sic, опечатка Oplus):

```java
21:    private void d(Context context) {
22:        Intent intent = new Intent();
23:        intent.putExtra(Constant.EXTRA_COMMAND, 5);
24:        intent.setClass(context, PowerStatsService.class);
...
28:            d(context);
```

`PowerConnectionReceiver.java`:

```java
195:  if (Constant.ACTION_SYSTEM_STATE_CHANGE.equals(action)) {
198:      intent3.putExtra(Constant.EXTRA_COMMAND, 7);
201:      context.startService(intent3);
```

Манифест (`key/AndroidManifest.xml:152-158`): `PowerStatsService` — `exported=true`,
permission `com.oplus.powermonitor.permission.POWER_MONITOR`, action `com.oplus.action.RESUME_POWER_MONITOR`.

### 4.5 Почему виноват screen-off: exsystem

`~/re/decompiled/exsystem/out/sources/j5/b.java` (`OplusPowerConsumedMonitorService`):

```java
 46:                case "android.intent.action.SCREEN_OFF":
...
 50:                    b.this.f8492c.sendEmptyMessage(2);
...
 86:                if (b.this.f8494e != null) {
 87:                    b.this.f8494e.k(20);          // -> PowerMonitorNotifier
```

`j5/c.java` (`PowerMonitorNotifier`):

```java
 45:    private long f8501e = 180000;   // backoff клиента 3 мин, удваивается
 51:    private long f8503g = 60000;    // задержка screen-off -> bind

144:    static void c(c cVar) {                       // вызывается из onServiceDisconnected
145:        if (cVar.f8501e >= 7200000) {
146:            cVar.f8501e = 180000L;
147:        }
148:        cVar.f8499c.postDelayed(new d(cVar), cVar.f8501e);
149:    }

151:    static void d(c cVar) {
152:        if (cVar.f8497a == null) {
153:            Slog.d("PowerMonitorNotifier", "onScreenOff: trying to connecting");
154:            Intent intent = new Intent();
155:            ComponentName componentName = new ComponentName("com.oplus.powermonitor",
                      "com.oplus.powermonitor.standbymonitor.powerstats.PowerStatsService");
157:            intent.setAction("com.oplus.action.RESUME_POWER_MONITOR");
160:            if (cVar.f8500d.bindServiceAsUser(intent, cVar.f8504h, 1, UserHandle.CURRENT)) {
```

```java
292:    public void k(int i9) {                 // toggle-дебounce
293:        if (this.f8499c.hasMessages(i9)) {
294:            this.f8499c.removeMessages(i9);
295:        } else {
296:            this.f8499c.sendEmptyMessageDelayed(i9, this.f8503g);   // 60 с
```

`j5/d.java:17` — `this.f8508d.f8501e *= 2;`.

### 4.6 Уточнение про 3–6 секунд

Клиентский backoff — **180 с и удвоение** (это видно и в логах: `Unable to start service` в 13:39:19 → 13:42:26,
интервал ≈187 с). Наблюдаемые же рестарты — 1.5–9 с, причём `onServiceConnected: success` идёт **без**
предшествующего `onScreenOff: trying to connecting`, т.е. новый `bindService` не вызывался: сервис
поднимает **AMS** по сохранившемуся `ServiceRecord` (`Start proc … for service {...PowerStatsService}`).
Точную ветку `ActiveServices` из `services.jar` не проверял (см. §8) — это **выведено**.

---

## 5. Граф зависимостей

```
BOOT_COMPLETED
   └─> com.oplus.powermonitor.BootCompletedRecevier.d()
         └─> startService(PowerStatsService, cmd=5)      [startRequested=true]
               └─> onStartCommand()
                     ├─ uptime <= 780 s ?  ── да ──> scheduleFinishSelf(1000, true)
                     │                                   └─(1 s)→ stopSelfNow(true)
                     │                                             ├─ stopSelf()
                     │                                             ├─ ServiceLifeManager.h("PowerStatsService")
                     │                                             └─ ServiceLifeManager.g()
                     │                                                   └─ Process.killProcess(myPid)  ← смерть
                     └─ иначе → нормальная работа (сбор статистики)

SCREEN_OFF
   └─> com.oplus.exsystemservice (OplusPowerConsumedMonitorService, j5.b)
         └─(60 s, j5.c.k(20))→ PowerMonitorNotifier.d()
               └─> bindServiceAsUser(PowerStatsService, BIND_AUTO_CREATE)
                     └─> процесс/сервис поднимается AMS
                           └─> снова onStartCommand → self-kill (пока uptime < 13 мин)
                                 └─> AMS снова поднимает сервис … (петля до 13-й минуты)

onServiceDisconnected → PowerMonitorNotifier.c() → postDelayed(180 s, ×2, max 2 ч) → повторный bind
```

**Чего в графе нет:** `com.oplus.deepthinker`, `com.oplus.healthservice`, `com.oplus.nas`,
`com.oplus.eyeprotect`, `com.oplus.gesture`, `com.heytap.mcs`. Grep по всем исходникам PowerMonitor:

```
$ grep -rn -iE 'deepthinker|healthservice|com\.oplus\.nas|eyeprotect|com\.oplus\.gesture|heytap\.mcs' \
      decompiled/powermonitor/out/sources
→ единственное совпадение: тестовая JSON-строка в modem/JsonParser.java (не код-зависимость)
```

---

## 6. Что реально было с пакетами (проверка гипотезы)

Текущее состояние (`dumpsys package … | grep 'User 0:'`):

| Пакет | `stopped` | `enabled` | Комментарий |
|---|---|---|---|
| com.oplus.deepthinker | false | **1** (enabled) | включён |
| com.oplus.healthservice | false | **1** | включён |
| com.oplus.nas | false | **1** | включён |
| com.oplus.eyeprotect | false | **1** | включён |
| com.oplus.gesture | false | **1** | включён |
| com.heytap.mcs | false | **3** (disabled_user) | выключен в 13:38:35, **после** петли |
| com.oplus.exsystemservice | **true** | **3** | выключен вручную 13:34:49 |
| com.oplus.powermonitor | **true** | **3** | выключен вручную 13:34:49 |
| com.google.android.gms | false | **3** | выключен; из-за него, вероятно, NLP-цикл |

Вывод: **гипотеза «петлю вызвало отключение deepthinker/healthservice/nas/eyeprotect/gesture/mcs» не подтверждается.**
Петля шла 13:21–13:33, когда эти пакеты были включены; в коде пути self-kill на них нет ссылок;
отключения произошли позже.

Что действительно дало отключение — побочные эффекты:
- `exsystemservice` (system uid) остался жить как процесс (pid 2361, запущен на boot), но его `bindService`
  в выключенный `powermonitor` теперь падает: `Unable to start service … not found` каждые ~3 мин.
- После ребута выключенный `exsystemservice` **не запустится вообще** → отвалятся screen-off-пайплайн,
  `AppServices`-биндинги (oshare, floatassistant, accessory, gesture), часть сценариев камеры/фонарика и т.п.

---

## 7. Второй дефект: 88–99 % CPU в system_server (NLP)

Это **не** PowerMonitor: петля закончилась в 13:33, а CPU-пожар начался ≈13:43 и продолжается.

Факты (read-only):

```
$ adb shell 'read … /proc/1899/task/2309/stat; sleep 5; …'
ticks delta: 418 in 5s          # ≈84 % одного ядра
$ cat /proc/1899/task/2309/comm
ation.blockable                 # обрезанное имя потока "location.blockable"
```

```
10-25 13:58:42.532  1899  2309 D OplusMultiNlpHelper: resource of name:config_nlp_packageName_oplus id is:201589169
10-25 13:58:42.532  1899  2309 E OplusMultiNlpHelper: nlpPackageNameList:[com.oplus.location, com.google.android.gms,
                                        com.tencent.android.location, com.android.location.fused, com.amap.android.location, com.baidu.map.location]
10-25 13:58:42.533  1899  2309 E system_server: No package ID ff found for resource ID 0xffffffff.
10-25 13:54:18.229  1899  2309 I MessageQueue: searched 50000messages, recent msg is { when=-59s411ms what=101 target=android.os.Handler }
```

- 18 834 строки от tid 2309 за одну минуту (~200/с), из них 12 216 — `OplusMultiNlpHelper`, 4 071 — `MessageQueue`.
- `MessageQueue: searched 10000/20000/…/50000messages` — это O(N)-скан очереди при постановке каждого
  сообщения; при >50 000 сообщений получаем квадратичное поведение и вечный цикл.
- `dumpsys location`: `network provider: enabled=false, allowed=false`; `settings`: `location_mode=3`, `location_providers_allowed=+network`.
- `com.google.android.gms` — `enabled=3` (disabled), `lastDisabledCaller: shell:1000`.

**Выведено (не доказано кодом):** `OplusMultiNlpHelper` в цикле резолвит список NLP-пакетов, включающий
выключенный `com.google.android.gms`; резолв ресурса даёт `0xffffffff`, ошибка не имеет backoff'а и
сама себя переотправляет (`what=101`), очередь растёт, `MessageQueue.enqueueMessage` уходит в O(N²).
Класс `OplusMultiNlpHelper` **отсутствует** в выкачанных `services.jar`, `oplus-services.jar`,
`framework.jar`, `oplus-framework.jar` (grep по dex), поэтому точный код цикла не процитирован.

Практический эффект: устройство греется/жрёт батарею; UI может лагать; это опаснее, чем косметическая
петля PowerMonitor.

---

## 8. Доказано vs выведено

| Утверждение | Статус | Доказательство |
|---|---|---|
| Смерть процесса — суицид `Process.killProcess`, не краш/ANR/lmk | **доказано** | `y0/g.java:145-146`; в crash-буфере нет PowerMonitor; единственный `Killing …powermonitor` — 13:34:49 от `pm disable-user`; смертей 19, все без стека |
| Смерть через 1–4 с после старта из-за `scheduleFinishSelf(1000,true)` | **доказано (код + тайминг)** | `PowerStatsService.java:1810-1812, 1100-1107, 1837-1843`; старт 13:21:20.336 → смерть 13:21:21.760 |
| 13-минутное окно — константа 780000 мс | **доказано** | `PolicyManager.java:24, 432-439` |
| Screen-off → exsystem bind → старт сервиса | **доказано** | `j5/b.java:46-50,86-87`, `j5/c.java:151-160`; логи `handleMessage: 20/0` → `onScreenOff: trying to connecting` |
| Рестарты делает AMS, а не клиент (клиент — 180 с) | **выведено, сильная улика** | `onServiceConnected` без `trying to connecting`; интервалы 1.5–9 с vs `f8501e=180000` |
| Петля сама умирает на 13-й минуте | **выведено, сильная улика** | последняя смерть 13:33:30 при uptime 12:40; следующего старта нет; ручное отключение только в 13:34:49 |
| Отключённые пакеты не влияют на self-kill | **доказано (grep + таймлайн)** | нет ссылок в коде; пакеты были enabled; `mcs` выключен в 13:38:35 |
| CPU-пожар — цикл `OplusMultiNlpHelper`/`location.blockable` | **доказано (наблюдение)** | tid 2309 = 84–99 % ядра; 18.8k строк/мин; очередь 50k |
| Причина NLP-цикла — выключенный GMS / отсутствующий network provider | **выведено** | `nlpPackageNameList` содержит gms; `network provider enabled=false`; gms `enabled=3`; код класса не найден |
| Точная ветка AMS-рестарта (AOSP или патч ColorOS) | **не проверено** | `services.jar` не декомпилировался |

---

## 9. Безопасная ремедиация

### 9.1 Порядок восстановления (не выполнять вслепую; делать с пониманием)

```bash
# 0. снять текущее состояние (read-only)
adb shell dumpsys package com.oplus.exsystemservice | grep 'User 0:'
adb shell dumpsys package com.oplus.powermonitor   | grep 'User 0:'
adb shell dumpsys activity services com.oplus.powermonitor

# 1. сначала вернуть ядро системы — exsystemservice
adb shell pm enable com.oplus.exsystemservice

# 2. затем PowerMonitor
adb shell pm enable com.oplus.powermonitor

# 3. (опционально, если нужен push) MCS — к багу отношения не имеет
adb shell pm enable com.heytap.mcs

# 4. CPU/NLP: выбрать ОДНО
#    4a. если Google-сервисы допустимы — вернуть network location provider:
adb shell pm enable com.google.android.gms
#    4b. если GMS остаётся выключенным — убрать спрос на локацию:
adb shell settings put secure location_mode 0

# 5. один ребут, чтобы очистить очередь system_server (>50k сообщений)
adb reboot
```

Почему именно так: `exsystemservice` — клиент, который держит bind на PowerStatsService; включать его
раньше потребителя. `powermonitor` после включения **не начнёт петлю сразу**, потому что текущий uptime
уже > 13 мин; петля возможна только в первые 13 минут после следующего ребута (и это штатное поведение).

### 9.2 Если нужно убрать именно 13-минутный шторм

Легального «переключателя» нет: `DEF_BOOT_SILENCE_DURATION` — константа. Варианты:

1. **Ничего не делать.** Шторм ограничен 13 минутами и заканчивается сам; на фоне NLP-проблемы он незначим.
2. **`am force-stop com.oplus.powermonitor` после загрузки** (обратимо, не меняет package state) —
   гасит шторм до следующего ребута. НЕ `pm disable-user`.
3. Не включать `debugMode` через RUS-конфиг (`updatePolicyFromConfig`): он отключит self-kill,
   но заодно поменяет кучу порогов диагностики (`mDebugMode` используется в десятках методов PolicyManager).

### 9.3 Что НЕ трогать

- **Не оставлять выключенными `com.oplus.exsystemservice` и `com.oplus.powermonitor`.** Это system-uid
  сервисы; эксстем — поставщик `AppServices` (oshare, accessory, gesture, floatassistant), screen-off пайплайна;
  powermonitor — статистика батареи/standby. После ребута в disabled-состоянии они просто не поднимутся.
- **Не трогать `system_server`, `services.jar`, `/system`, `framework`.** NLP-цикл лечится на уровне пакетов/настроек.
- **Не делать `kill -9 system_server`**, `stop`/`start`, `setprop` отладки, `pm clear`.
- **Не выключать GMS «для батареи»** — это и есть наиболее вероятная причина текущего 99 % CPU.
- **Не менять appops и не чистить `/data`** — в логах нет ни одного отказа по permission/appops для powermonitor.

### 9.4 Проверка после лечения

```bash
# пакеты снова включены, stopped сбросится после первого запуска
adb shell dumpsys package com.oplus.powermonitor | grep -E 'User 0:|lastDisabledCaller'
adb shell dumpsys package com.oplus.exsystemservice | grep 'User 0:'

# сервис живёт и не перезапускается каждые 3 с
adb shell dumpsys activity services com.oplus.powermonitor
adb shell 'logcat -d | grep -c "Start proc .*powermonitor"'   # за 5 мин должно быть 0–1, не 20

# self-kill не должен повторяться после 13-й минуты uptime
adb shell 'logcat -d | grep -E "ServiceLifeManager|PowerMonitor selfKill"'

# CPU: поток location.blockable не должен жечь ядро
adb shell 'P=$(pidof system_server); for t in /proc/$P/task/*; do \
  read -r _ _ _ _ _ _ _ _ _ _ _ _ _ u s _ < $t/stat; echo "$((u+s)) $(cat $t/comm)"; done | sort -rn | head -3'
adb shell 'logcat -d | grep -c OplusMultiNlpHelper'            # должно перестать расти
adb shell dumpsys location | grep -A8 'network provider'        # enabled=true, allowed=true (если GMS включён)
```

Ожидаемая норма: `system_server` < 20 %; в топе потоков нет `ation.blockable`; нет пачки
`Unable to start service … not found`; `PowerStatsService` присутствует в `dumpsys activity services`
только когда экран выключен/идёт измерение.

---

## 10. Открытые вопросы

1. **Где живёт `OplusMultiNlpHelper`?** Его нет в выкачанных jar'ах; нужен `/system_ext/framework/*.jar`
   или другой boot-jar, чтобы процитировать цикл и подтвердить, что ретрай завязан именно на `gms`.
2. **Почему цикл стартовал в 13:43, а не сразу после выключения GMS?** Нужен триггер (запрос локации
   от `com.oplus.nhs`/погоды/камеры) и код `OplusMultiNlpHelper`.
3. **AMS-рестарт:** AOSP `ActiveServices` или патч ColorOS? Требуется декомпиляция `services.jar`
   (ветка `bringDownServiceLocked`/`scheduleServiceRestartLocked`).
4. **Воспроизводится ли 13-минутный шторм на другом RMX3630** с той же прошивкой? Сравнительного лога нет;
   «by design» подтверждено только кодом, не вторым устройством.
5. **Достаточно ли включить один `com.google.android.gms`**, если `com.android.vending`/`gsf` остаются
   выключены? Не проверялось; возможно, потребуется весь Google-стек или отказ от network location.
6. **Логи приложения (`Log.d`) в буфере отсутствуют** (нет ни `PowerStatsService: onCreate`, ни
   `PowerMonitor selfKill!`), хотя код их пишет; вероятно, фильтрация уровня логирования для uid 1000.
   Поэтому self-kill доказан кодом + таймингом, а не строкой в logcat. Стоит проверить
   `persist.log.tag.*`/`log.tag.PowerStatsService`, если нужна прямая строка.
