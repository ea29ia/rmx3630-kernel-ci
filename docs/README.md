# RMX3630 docs (public, sanitized)

Документы по устройству Realme 10 4G (RMX3630, ColorOS 14.0.0.420EX01)
и сборке ядра в GitHub Actions.

| файл | содержание |
|---|---|
| `STATUS.md` | общий статус: root, деблоат, экран, инцидент NLP/powermonitor, CI ядра |
| `HANDOFF.md` | передача работы: диагностика, восстановление, ядро, риски |
| `reverse-powermonitor.md` | реверс `com.oplus.powermonitor` / `OplusExSystemService` |
| `vendor-audit.md` | аудит vendor/MTK/Google: телеметрия, debug-поверхности |

Из публичной версии удалены: LAN-адрес, ADB-порт, параметры adb-доступа,
имена вспомогательных скриптов и локальные абсолютные пути. Полная
операционная версия handoff хранится только локально у владельца.

Сборка ядра: <https://github.com/ea29ia/rmx3630-kernel-ci>
