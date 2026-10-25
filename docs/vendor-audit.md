# Vendor / MTK / Google: телеметрия и потенциальные «закладки» (redacted)

Полная версия отчёта хранится локально и **не публикуется**: она содержит
детали сетевого доступа к устройству, свойства ADB и команды управления.
Ниже — безопасный для публикации digest.

## TL;DR

1. Доказанного вендорского «remote root backdoor» не найдено. Единственный
   реальный путь удалённого получения root — сетевой ADB, настроенный
   владельцем вручную (детали опущены), плюс `SELinux Permissive`,
   разблокированный загрузчик и Magisk.
2. Вендорская телеметрия собирается, но в этой сборке нет штатного
   «отправлятора»: не установлены `com.oplus.dcs`, `com.oplus.olc`,
   `com.oplus.logkit`, `com.coloros.logkit`, `com.oplus.ota`.
3. Основные сборщики: `oplus_gaia` (root, abstract-сокет `@gaia_socket`,
   27 плагинов; по конфигу копирует логи сторонних приложений — WeChat,
   QQ, IME, скриншоты/screen record, systrace, touch/GPS/BT/Wi-Fi/audio/
   camera-логи), `oplus_theia`, `criticallog`, `ostatsd`/`ostats_pullerd`/
   `ostats_tpd`, `midasd`, `horae`.
4. `common_dcs` (`libcommon_dcs_service.so`) — универсальная upload-труба
   (`runUpload`, `sendToDcsFromCommonDcs`); URL передаёт вызывающий, в
   бинарнике не зашит. Её линкуют `vold`, `criticallog`, `oplus_gaia`,
   `oplus_theia`, `midasd`, `ostatsd`.
5. У `oplus_gaia` есть строка `https://hio.oppo.com/app/ozone/pt/`, но
   HTTP-клиента в бинаре нет (`readelf -d`: только `libGaiaClient` и
   `libcommon_dcs_service`); прямая выгрузка не доказана.
6. Фабричные/AT-интерфейсы (`atcid`, `atci_service`, `meta_tst`,
   `factory`) выключены; их сокеты в `/dev/socket` отсутствуют.
7. Исходящие TLS на момент снимка: `com.coloros.lockassistant`
   (Alibaba Cloud), клавиатура `com.preff.kb.op` (Facebook edge),
   кратковременно `com.heytap.accessory`.
8. Google-компоненты (GMS/GSF/Vending) были выключены; в dex доказаны
   `checkin.gstatic.com/checkin`, `play.googleapis.com/log/batch`,
   `android.clients.google.com/fdfe/` — при включении пойдёт классический
   checkin + пакетная телеметрия Play + инвентаризация приложений.

## Классификация

| класс | примеры | риск |
|---|---|---|
| Сбор логов/телеметрия | `oplus_gaia`, `oplus_theia`, `criticallog`, `ostatsd`, `midasd`, `horae` | высокий для privacy |
| Upload-труба | `common_dcs` | средний (URL от вызывающего) |
| Локальные debug-поверхности | netdiag, customer_tcpdump, Perfetto, engineer/META (выключены) | высокий локально |
| Фабричные/AT | atcid/meta/factory (выключены) | низкий в текущем состоянии |
| Сетевой root | ADB, настроенный владельцем | критичный (self-imposed) |

## Рекомендации

- Не держать сетевой ADB включённым без необходимости; ограничивать
  источник на устройстве.
- Телеметрию блокировать сетевым firewall'ом по доменам/IP, а не
  отключением вендорных сервисов.
- Не отключать `exsystemservice`/`powermonitor`/`battery`/`athena` и
  прочие core-сервисы.
- Для полного отчёта — локальная версия у владельца.
