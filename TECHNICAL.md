# Как работает WindowsProfileMigration v1.11.1

Профиль Windows принадлежит одному пользователю. В нём хранятся документы, рабочий стол и настройки. На исходном компьютере программа собирает профиль в архив. На целевом компьютере она проверяет архив и восстанавливает данные для выбранной учётной записи.

## Откуда и куда идут данные

На карте показано, куда ведёт каждый пункт меню и каким результатом заканчивается операция. Ниже можно перейти к подробной схеме и к функции, с которой начинается сценарий.

**Легенда**

| Обозначение | Что означает |
| --- | --- |
| 🟦 Синий прямоугольник | Вход в сценарий или действие программы |
| 🟨 Жёлтый ромб | Условие или выбор пользователя |
| 🟩 Зелёный прямоугольник | Итог, сохранённый архив или отчёт |
| 🟥 Красный прямоугольник | Ошибка или остановка |
| 🟪 Фиолетовый прямоугольник | Частичный результат, повтор или восстановление |

```mermaid
---
config:
  theme: base
  htmlLabels: false
  themeVariables:
    fontFamily: "Inter, Segoe UI, sans-serif"
    lineColor: "#697c9a"
    edgeLabelBackground: "#eef2fa"
    primaryTextColor: "#182945"
  flowchart:
    nodeSpacing: 28
    rankSpacing: 38
    padding: 12
    curve: basis
---
flowchart TD
    START["start.cmd · локальный<br/>диск или сеть"] --> BOOT["Запуск · права<br/>администратора и<br/>готовность Windows"]
    BOOT --> MENU{"Главное меню"}
    MENU -->|1| EXPORT["Экспорт профиля"]
    MENU -->|2 и 3| IMPORT["Импорт или проверка<br/>архива"]
    MENU -->|4| RECOVER["Восстановление или<br/>очистка"]
    MENU -->|"5, 6 и 7"| NETWORK["Сетевой перенос, приём<br/>или продолжение"]
    MENU -->|0| EXIT["Выход"]
    EXPORT --> REPORT["Итог · архив, статус и<br/>TXT-отчёт"]
    IMPORT --> REPORT
    RECOVER --> REPORT
    NETWORK --> REPORT
    REPORT --> MENU
    classDef default fill:#edf5ff,stroke:#526d9b,color:#182945,stroke-width:1.5px;
    classDef entry fill:#dce7ff,stroke:#385da6,color:#1c376a,stroke-width:2px;
    classDef decision fill:#fff3cc,stroke:#966312,color:#4a2f05,stroke-width:2px;
    classDef result fill:#e2f6e9,stroke:#257b54,color:#155138,stroke-width:2px;
    classDef exception fill:#ffe9e7,stroke:#a7443e,color:#742922,stroke-width:2px;
    classDef recovery fill:#f1eaff,stroke:#7250a4,color:#482c75,stroke-width:2px;
    class START entry;
    class MENU decision;
    class REPORT,EXIT result;
    class RECOVER recovery;
```

Откройте [FLOWCHART.html](FLOWCHART.html) из распакованного ZIP для просмотра этих же схем в браузере.

| Пункт | Сценарий | Точка входа |
| --- | --- | --- |
| Запуск | [Подготовка Windows и USMT](#запуск-и-подготовка) | [Bootstrap.ps1](Program/Bootstrap.ps1) · `Start-MigrationProcess` |
| 1 | [Экспорт](#экспорт-профиля) | [Export.ps1](Program/Export.ps1) · `Do-Export` |
| 2 и 3 | [Импорт и проверка архива](#проверка-и-импорт-архива) | [Import.ps1](Program/Import.ps1) · `Do-Import` |
| 4 | [Состояние, очистка и восстановление](#восстановление-и-очистка) | [Recovery.ps1](Program/Recovery.ps1) · `Show-RecoveryMenu` |
| 5, 6 и 7 | [Прямой перенос и возобновление](#прямой-перенос-по-сети) | [Network.ps1](Program/Network.ps1) · `Do-RemoteDeploy`, `Prepare-RemoteReceiver` |
| 0 и остановка | [Отмена, итог и отчёт](#отмена-итог-и-отчёт) | [MainMenu.ps1](Program/MainMenu.ps1) · `Invoke-InteractiveMenu` |

### Запуск и подготовка

```mermaid
---
config:
  theme: base
  htmlLabels: false
  themeVariables:
    fontFamily: "Inter, Segoe UI, sans-serif"
    lineColor: "#697c9a"
    edgeLabelBackground: "#eef2fa"
    primaryTextColor: "#182945"
  flowchart:
    nodeSpacing: 28
    rankSpacing: 38
    padding: 12
    curve: basis
---
flowchart TD
    A["Открыть start.cmd с диска или из<br/>общей папки"] --> B["Bootstrap.ps1 определяет папку<br/>комплекта"]
    B --> C{"Это подключённый сетевой диск?"}
    C -->|Да| D["Попытка получить сетевой адрес<br/>ресурса"]
    C -->|Нет| E{"Есть права администратора?"}
    D --> E
    E -->|Нет| F{"Пользователь подтвердил запрос<br/>Windows?"}
    F -->|Нет| G["Выход. При ошибке запуска<br/>записать отчёт"]
    F -->|Да| H["Проверить Windows, права и<br/>доступ к комплекту"]
    E -->|Да| H
    H -->|Ошибка| G
    H -->|"Локальный запуск"| I["Invoke-InteractiveMenu<br/>показывает пункты 0–7"]
    H -->|"Удалённый запуск"| J["Проверить параметры и наличие<br/>USMT, затем Do-Import"]
    I --> K{"Какой пункт выбран?"}
    K -->|0| L["Выход"]
    K -->|4 или 6| M["Восстановление или подготовка<br/>WinRM"]
    K -->|"1, 2, 3, 5 или 7"| N{"Найден USMT нужной разрядности?"}
    N -->|Да| O["Выполнить выбранную операцию"]
    N -->|Нет| P["Выбор: скачать ADK, повторить<br/>поиск или вернуться"]
    P --> Q{"Загрузка, подпись Microsoft и<br/>установка прошли?"}
    Q -->|Да| N
    Q -->|"Нет или нужна перезагрузка"| I
    classDef default fill:#edf5ff,stroke:#526d9b,color:#182945,stroke-width:1.5px;
    classDef entry fill:#dce7ff,stroke:#385da6,color:#1c376a,stroke-width:2px;
    classDef decision fill:#fff3cc,stroke:#966312,color:#4a2f05,stroke-width:2px;
    classDef result fill:#e2f6e9,stroke:#257b54,color:#155138,stroke-width:2px;
    classDef exception fill:#ffe9e7,stroke:#a7443e,color:#742922,stroke-width:2px;
    classDef recovery fill:#f1eaff,stroke:#7250a4,color:#482c75,stroke-width:2px;
    class A entry;
    class C,E,F,K,N,Q decision;
    class J,L,O result;
    class G exception;
    class M,P recovery;
```

[Usmt.ps1](Program/Usmt.ps1) реализует `Get-UsmtPath`, `Require-USMT` и установку ADK. Пункт 4 и подготовка WinRM доступны без USMT.

### Экспорт профиля

```mermaid
---
config:
  theme: base
  htmlLabels: false
  themeVariables:
    fontFamily: "Inter, Segoe UI, sans-serif"
    lineColor: "#697c9a"
    edgeLabelBackground: "#eef2fa"
    primaryTextColor: "#182945"
  flowchart:
    nodeSpacing: 28
    rankSpacing: 38
    padding: 12
    curve: basis
---
flowchart TD
    A["Do-Export: выбрать профиль"] --> B{"Профиль выгружен, SID и путь<br/>совпадают?"}
    B -->|Нет| X["Остановить экспорт, записать<br/>причину"]
    B -->|Да| C["Выбрать личные файлы и защиту<br/>архива"]
    C --> D{"Доступны настройки личных папок?"}
    D -->|Да| E["Разрешить стандартные и<br/>проверенные перенаправленные<br/>пути"]
    D -->|Нет| F["Записать предупреждение,<br/>использовать доступные настройки<br/>и локальные пути"]
    E --> G["Оценить объём профиля без<br/>AppData/Local/Temp и размер<br/>Extras"]
    F --> G
    G --> H{"Достаточно места на рабочем<br/>диске и в папке назначения?"}
    H -->|Нет| X
    H -->|Да| I{"Пользователь подтвердил экспорт?"}
    I -->|Нет| Y["Отменить и убрать рабочую копию"]
    I -->|Да| J["Создать правила USMT и исходный<br/>реестр SHA-256"]
    J --> K["ScanState сохраняет профиль,<br/>Temp исключён"]
    K --> L{"Список путей и хранилище USMT<br/>прошли проверку?"}
    L -->|Нет| X
    L -->|Да| M["Собрать личные файлы, ярлыки и<br/>дополнительные настройки"]
    M --> N{"Источник не изменился после<br/>ScanState?"}
    N -->|Нет| X
    N -->|Да| O["Записать метаданные и манифест<br/>Extras, собрать ZIP"]
    O --> P{"Выбран пароль?"}
    P -->|Да| Q["Зашифровать ZIP, итог .wpm.pgp"]
    P -->|Нет| R["Оставить ZIP"]
    Q --> S["Скопировать под временным<br/>именем, сверить SHA-256"]
    R --> S
    S -->|Сверка прошла| T["Опубликовать архив, очистить<br/>рабочую копию, выдать отчёт"]
    S -->|Ошибка или отмена| U["Оставить рабочие данные по<br/>правилам восстановления"]
    classDef default fill:#edf5ff,stroke:#526d9b,color:#182945,stroke-width:1.5px;
    classDef entry fill:#dce7ff,stroke:#385da6,color:#1c376a,stroke-width:2px;
    classDef decision fill:#fff3cc,stroke:#966312,color:#4a2f05,stroke-width:2px;
    classDef result fill:#e2f6e9,stroke:#257b54,color:#155138,stroke-width:2px;
    classDef exception fill:#ffe9e7,stroke:#a7443e,color:#742922,stroke-width:2px;
    classDef recovery fill:#f1eaff,stroke:#7250a4,color:#482c75,stroke-width:2px;
    class A entry;
    class B,D,H,I,L,N,P decision;
    class T result;
    class X,Y exception;
    class F,U recovery;
```

[Export.ps1](Program/Export.ps1) объединяет `New-ProfileOnlyRules`, `Invoke-ProfileScan` и `Save-ProfileScopeProof`. [UserFiles.ps1](Program/UserFiles.ps1) читает папки пользователя и копирует личные файлы.

### Проверка и импорт архива

```mermaid
---
config:
  theme: base
  htmlLabels: false
  themeVariables:
    fontFamily: "Inter, Segoe UI, sans-serif"
    lineColor: "#697c9a"
    edgeLabelBackground: "#eef2fa"
    primaryTextColor: "#182945"
  flowchart:
    nodeSpacing: 28
    rankSpacing: 38
    padding: 12
    curve: basis
---
flowchart TD
    A["Do-Import: выбрать архив<br/>локально или по сети"] --> B{"Что выбрано?"}
    B -->|Папка| C["Скопировать в рабочий каталог и<br/>сверить файлы"]
    B -->|ZIP| D["Проверить структуру и<br/>распаковать в рабочий каталог"]
    B -->|OpenPGP| E["Получить пароль, проверить<br/>место, расшифровать ZIP"]
    E --> D
    C --> F["Проверить метаданные, правила,<br/>SHA-256 и хранилище USMT"]
    D --> F
    F -->|Сбой обязательной проверки| X["Остановить до записи профиля,<br/>выдать отчёт"]
    F -->|Проверка пройдена| G{"Пункт меню?"}
    G -->|3| H["Закончить проверку архива и<br/>показать отчёт"]
    G -->|2| T{"Версии Windows поддерживают<br/>перенос?"}
    T -->|Нет| X
    T -->|Да| I["Выбрать учётную запись, сверить<br/>SID и свободное место"]
    I --> J{"Есть профиль назначения или<br/>незавершённый импорт?"}
    J -->|Да| X
    J -->|Нет| K{"Импорт подтверждён?"}
    K -->|Нет| Y["Отмена до LoadState"]
    K -->|Да| L["При необходимости создать<br/>локальную учётную запись"]
    L --> M["Записать начало и выполнить<br/>LoadState"]
    M -->|Сбой или отмена| N["Зафиксировать возможный<br/>частичный профиль"]
    M -->|Успех| O["Вернуть личные файлы и сверить<br/>восстановленный профиль"]
    O --> P["Применить проверенные<br/>дополнительные настройки"]
    P --> Q{"Файлы и проверки завершены?"}
    Q -->|Да| R["Записать результат и передать<br/>профиль на приёмку"]
    Q -->|"Есть пропуски или проверка ограничена"| S["Указать причину, сохранить<br/>возможность повтора личных<br/>файлов"]
    classDef default fill:#edf5ff,stroke:#526d9b,color:#182945,stroke-width:1.5px;
    classDef entry fill:#dce7ff,stroke:#385da6,color:#1c376a,stroke-width:2px;
    classDef decision fill:#fff3cc,stroke:#966312,color:#4a2f05,stroke-width:2px;
    classDef result fill:#e2f6e9,stroke:#257b54,color:#155138,stroke-width:2px;
    classDef exception fill:#ffe9e7,stroke:#a7443e,color:#742922,stroke-width:2px;
    classDef recovery fill:#f1eaff,stroke:#7250a4,color:#482c75,stroke-width:2px;
    class A entry;
    class B,G,T,J,K,Q decision;
    class H,R result;
    class X,Y exception;
    class N,S recovery;
```

[ArchiveSelection.ps1](Program/ArchiveSelection.ps1) находит архив. [Import.ps1](Program/Import.ps1) выполняет `Assert-ImportProfileUnused` и `Invoke-ProfileLoad`. [FileManifest.ps1](Program/FileManifest.ps1) сверяет контрольные файлы. Старые правила формата 7 принимаются только по известному SHA-256. Форматы 1–6 доступны для проверки, если их метаданные читаются.

### Прямой перенос по сети

```mermaid
---
config:
  theme: base
  htmlLabels: false
  themeVariables:
    fontFamily: "Inter, Segoe UI, sans-serif"
    lineColor: "#697c9a"
    edgeLabelBackground: "#eef2fa"
    primaryTextColor: "#182945"
  flowchart:
    nodeSpacing: 28
    rankSpacing: 38
    padding: 12
    curve: basis
---
flowchart TD
    A["Новый ПК: пункт 6"] --> B{"Подтверждена настройка WinRM?"}
    B -->|Да| C["Windows настраивает приём"]
    B -->|Нет| Z["Отмена"]
    C --> D["Старый ПК: пункт 5 или 7"]
    D -->|5| E["Выбрать исходный профиль"]
    D -->|7| F["Выбрать готовый архив и открыть<br/>его метаданные"]
    E --> G["Проверить WinRM, ПК назначения,<br/>права и учётную запись"]
    F --> G
    G -->|Ошибка| X["Закончить с отчётом"]
    G -->|Всё готово| H{"Есть готовый архив?"}
    H -->|Нет| I["Экспортировать исходный профиль"]
    H -->|Да| J["Сверить, что получатель тот же"]
    I --> J
    J --> K{"На получателе есть<br/>подтверждённая копия?"}
    K -->|Часть файла| V["Сверить сохранённый префикс"]
    K -->|Нет| W["Начать передачу с нуля"]
    V --> L["Передавать блоками и сохранять<br/>подтверждённое смещение"]
    W --> L
    K -->|Весь файл| M["Проверить итоговый SHA-256"]
    L -->|Обрыв| N["Переподключиться и проверить<br/>смещение"]
    N --> K
    L -->|Передано| M
    M --> O{"Получатель уже записал итог<br/>импорта?"}
    O -->|Да| P["Показать сохранённый итог"]
    O -->|"Начат, итог неизвестен"| X
    O -->|Нет| Q["Подготовить комплект и USMT,<br/>запустить импорт"]
    Q -->|Нет подтверждения| X
    Q -->|Получен итог| P
    classDef default fill:#edf5ff,stroke:#526d9b,color:#182945,stroke-width:1.5px;
    classDef entry fill:#dce7ff,stroke:#385da6,color:#1c376a,stroke-width:2px;
    classDef decision fill:#fff3cc,stroke:#966312,color:#4a2f05,stroke-width:2px;
    classDef result fill:#e2f6e9,stroke:#257b54,color:#155138,stroke-width:2px;
    classDef exception fill:#ffe9e7,stroke:#a7443e,color:#742922,stroke-width:2px;
    classDef recovery fill:#f1eaff,stroke:#7250a4,color:#482c75,stroke-width:2px;
    class A,D entry;
    class B,H,K,O decision;
    class P result;
    class X,Z exception;
    class F,L,N,V recovery;
```

[Network.ps1](Program/Network.ps1) использует `Send-RemoteArchive` и `Enter-RemoteMigration`. При несовпадении префикса, недостатке места или смене получателя передача останавливается. Если архив с паролем, пароль передаётся получателю по закрытому каналу. Сохранённый итог описывает полный, частичный или неподтверждённый результат.

### Восстановление и очистка

```mermaid
---
config:
  theme: base
  htmlLabels: false
  themeVariables:
    fontFamily: "Inter, Segoe UI, sans-serif"
    lineColor: "#697c9a"
    edgeLabelBackground: "#eef2fa"
    primaryTextColor: "#182945"
  flowchart:
    nodeSpacing: 28
    rankSpacing: 38
    padding: 12
    curve: basis
---
flowchart TD
    A["Пункт 4: выбрать запись<br/>операции"] --> B{"Запись старого формата?"}
    B -->|Да| C["Показать сведения для<br/>ручной проверки"]
    B -->|Нет| D["Выбрать действие и<br/>получить блокировку"]
    D --> E{"Запись читается и<br/>процессы остановлены?"}
    E -->|Нет| X["Отказать, указать<br/>причину в отчёте"]
    E -->|Да| F{"Номер действия?"}
    F -->|1| G["Проверить и очистить<br/>зарегистрированный<br/>временный каталог"]
    F -->|2| H["По SID проверить пустую<br/>локальную учётку и<br/>запросить два<br/>подтверждения"]
    F -->|3| I["Сверить хеш резервной<br/>копии и вернуть<br/>параметры значков"]
    F -->|4| J["Сверить имя и путь<br/>незавершённой копии<br/>архива, запросить<br/>удаление"]
    F -->|5| K["Проверить назначение и<br/>разрешить повторный<br/>импорт"]
    F -->|0| Z["Назад без изменения<br/>операции"]
    F -->|6| L{"LoadState завершён и<br/>остались личные файлы?"}
    L -->|Нет| X
    L -->|Да| M["Выбрать исходный архив<br/>или копию, сверить хеши<br/>и SID"]
    M --> N["Повторить только<br/>копирование личных<br/>файлов"]
    G --> O["Записать итог и<br/>освободить блокировку"]
    H --> O
    I --> O
    J --> O
    K --> O
    N --> O
    classDef default fill:#edf5ff,stroke:#526d9b,color:#182945,stroke-width:1.5px;
    classDef entry fill:#dce7ff,stroke:#385da6,color:#1c376a,stroke-width:2px;
    classDef decision fill:#fff3cc,stroke:#966312,color:#4a2f05,stroke-width:2px;
    classDef result fill:#e2f6e9,stroke:#257b54,color:#155138,stroke-width:2px;
    classDef exception fill:#ffe9e7,stroke:#a7443e,color:#742922,stroke-width:2px;
    classDef recovery fill:#f1eaff,stroke:#7250a4,color:#482c75,stroke-width:2px;
    class A entry;
    class B,E,F,L decision;
    class O,Z result;
    class X exception;
    class C,G,H,I,J,K,M,N recovery;
```

[Recovery.ps1](Program/Recovery.ps1) связывает меню с `Invoke-TrackedRecovery`. При выборе пункта 5 импорт запускается пользователем отдельно после подтверждения, а при выборе пункта 6 LoadState повторно не вызывается.

### Отмена, итог и отчёт

```mermaid
---
config:
  theme: base
  htmlLabels: false
  themeVariables:
    fontFamily: "Inter, Segoe UI, sans-serif"
    lineColor: "#697c9a"
    edgeLabelBackground: "#eef2fa"
    primaryTextColor: "#182945"
  flowchart:
    nodeSpacing: 28
    rankSpacing: 38
    padding: 12
    curve: basis
---
flowchart TD
    A["Открыть TXT-отчёт и<br/>отмечать этапы"] --> B["Записать ход операции и<br/>признаки начала USMT"]
    B --> C{"Чем закончилась операция?"}
    C -->|Успех| D["Сохранить итог и завершить<br/>отчёт"]
    C -->|"Отмена до записи профиля"| E["Сохранить статус отмены,<br/>очистить временные данные<br/>по правилам"]
    C -->|"Ошибка или отмена во время LoadState"| F["Сохранить признак<br/>возможного частичного<br/>профиля"]
    C -->|"Часть личных файлов осталась"| G["Сохранить отметку<br/>доступного повтора"]
    C -->|"Сбой публикации архива"| H["Записать пути к рабочей и<br/>незавершённой копиям"]
    C -->|"Прочий сбой"| X["Записать этап, причину и<br/>доступные сведения об<br/>ошибке"]
    X --> I
    E --> I["Показать путь к отчёту"]
    D --> I
    F --> I
    G --> I
    H --> I
    I --> J["Возврат в меню или выход"]
    classDef default fill:#edf5ff,stroke:#526d9b,color:#182945,stroke-width:1.5px;
    classDef entry fill:#dce7ff,stroke:#385da6,color:#1c376a,stroke-width:2px;
    classDef decision fill:#fff3cc,stroke:#966312,color:#4a2f05,stroke-width:2px;
    classDef result fill:#e2f6e9,stroke:#257b54,color:#155138,stroke-width:2px;
    classDef exception fill:#ffe9e7,stroke:#a7443e,color:#742922,stroke-width:2px;
    classDef recovery fill:#f1eaff,stroke:#7250a4,color:#482c75,stroke-width:2px;
    class A entry;
    class C decision;
    class D,I,J result;
    class E,X exception;
    class F,G,H recovery;
```

[Reporting.ps1](Program/Reporting.ps1) создаёт отчёт и пишет причину ошибки. [Recovery.ps1](Program/Recovery.ps1) атомарно обновляет запись состояния. По отчёту можно понять действие и причину остановки, по записи состояния - доступные операции восстановления.

## Что лежит в комплекте

```text
WindowsProfileMigration/
├── start.cmd                 Запускает программу
├── README.txt                Краткая инструкция по переносу
├── TECHNICAL.md              Схемы и техническое описание
├── FLOWCHART.html            Схемы для просмотра без интернета
├── Program/                  Код и библиотеки
│   ├── Bootstrap.ps1         Запрашивает права администратора
│   ├── ProfileMigration.ps1  Подключает части программы
│   ├── MainMenu.ps1          Вызывает действие по номеру из меню
│   ├── Export.ps1            Собирает профиль на исходном ПК
│   ├── Import.ps1            Проверяет и восстанавливает профиль
│   ├── Vendor/               Библиотека Bouncy Castle и её лицензия
│   └── …                     Вспомогательные файлы перечислены ниже
├── Reports/                  Итоговые отчёты
└── Backups/                  Архивы при сохранении рядом с программой
```

В репозитории также есть каталог `tests/` со сценариями проверок, `.github/workflows/` с настройками GitHub Actions, история версий и результаты испытаний. Для запуска на Windows достаточно распакованного комплекта.

## Какие файлы работают вместе

| Файлы в Program | За что отвечают |
| --- | --- |
| `Console.ps1`, `MainMenu.ps1` | Показывают варианты, читают номер и передают выбор нужному действию. |
| `Profiles.ps1`, `Export.ps1`, `Usmt.ps1` | Определяют владельца и состояние профиля, готовят правила отбора файлов и запускают USMT. |
| `ArchiveSelection.ps1`, `Archives.ps1`, `FileManifest.ps1` | Находят архив, проверяют имена и пути. В списке файлов записаны размеры и контрольные суммы SHA-256. Изменение файла можно обнаружить сравнением этих сумм. |
| `Encryption.ps1`, `OpenPgpArchive.cs` | Закрывает ZIP паролем и открывает его для проверки или импорта. До распаковки проверяется целостность защищённого файла. |
| `Import.ps1`, `Storage.ps1` | Проверяют свободное место, хранилище USMT и учётную запись назначения. Только потом запускают восстановление. |
| `Extras.ps1`, `Browsers.ps1`, `Desktop.ps1` | Обрабатывают дополнительные настройки, в том числе файлы браузеров, сетевые диски и расположение значков. |
| `UserFiles.ps1` | Собирает выбранные «Документы» и «Загрузки», а также файлы ярлыков рабочего стола. На приёмнике возвращает их в папки целевого пользователя. |
| `Network.ps1` | Передаёт архив блоками. После обрыва сверяет уже доставленную часть, перед импортом проверяет SHA-256 всего файла. |
| `Recovery.ps1`, `Reporting.ps1` | Запоминают пройденные этапы и пишут отчёт. Если выполнение LoadState прервалось, пункт 4 помогает выяснить состояние операции перед повтором. |

## Что сохраняется в архиве

- `metadata.json` указывает исходный профиль, версию формата и данные для проверок. Windows различает учётные записи по **SID**. Это постоянный идентификатор, который программа сверяет при выборе профиля.
- `Store/` содержит хранилище USMT. `Rules/` хранит правила отбора. `Validation/` содержит список обработанных путей и контрольные суммы.
- `Extras/` содержит дополнительные пользовательские данные. Можно включить отдельную копию локальных файлов и подпапок из «Документов» и «Загрузок». Программа учитывает папки внутри профиля и отдельные локальные или сетевые папки, если доступен точный путь и владельцем является выбранный пользователь. При недоступности программа покажет локальный путь для запасной копии. Для облачной папки файлы должны быть доступны на диске. Если при восстановлении отдельной копии уже существует файл с тем же именем и другим содержимым, перенесённая копия сохраняется отдельно.
- Ярлыки рабочего стола `.lnk`, `.url`, `.rdp` и `.website` переносятся автоматически. Например, для ярлыка на `\\server\share\plan.xlsx` архив хранит сам ярлык. После восстановления он по-прежнему ведёт на тот же сетевой ресурс.

При проверке архивов формата 7 принимаются текущие и прежние правила ProfileOnly.xml с известными SHA-256. Новые архивы исключают временную папку профиля из расчёта места и переноса. При выборе защиты библиотека Bouncy Castle шифрует весь ZIP в формате OpenPGP с AES-256. Получается файл `.wpm.pgp`. При экспорте пароль вводится дважды. Для открытия файла потребуется пароль архива. Пароль новой локальной учётной записи используется отдельно для входа в Windows. Перед расшифровкой программа проверяет место на рабочем диске. Перед импортом программа требует место для самого профиля и предупреждает об объёме возможных дополнительных копий. Совпадающие файлы пропускаются. Для записи нового файла проверяется свободное место в его фактической папке. Сведения о пропусках при экспорте сохраняются в архиве и отображаются при проверке и импорте.

## Закрытие окна

`start.cmd` задаёт локальную рабочую папку для загрузчика. Отчёты и резервные копии по-прежнему сохраняются по путям, заданным в комплекте или выбранным в меню. Если консоль уже повышена, загрузчик открывает меню в том же процессе и передаёт код выхода обратно в `cmd`. При запросе UAC исходный загрузчик завершается сразу после запуска окна администратора. Пункт 0 завершает программу без дополнительного ожидания ввода.

## Где искать результат

При локальном экспорте готовый архив сохраняется в выбранной папке. По умолчанию это `Backups/`. Путь к итоговому TXT программа показывает на экране. Обычно отчёт находится в `Reports/`. Если часть личных файлов осталась невосстановленной, пункт 4 → 6 предлагает исходный архив или другую его копию. Программа сверяет SHA-256 метаданных и манифеста, затем повторяет копирование для того же SID. По SHA-256 программа пропускает совпадающие файлы. Закрытые рабочие копии и записи о незавершённых операциях хранятся в `%ProgramData%\WindowsProfileMigration-Work`. Пока процесс USMT работает, журнал блокирует очистку его временных файлов. При прямом сетевом переносе получатель записывает итог для отправителя. При частичном результате отчёт указывает причину и расположение архива на целевом ПК. Если контрольный список пуст и пропусков по другим проверкам нет, на исходном ПК отображается «Полнота переноса не подтверждена».

Автор проекта: Arhivater.

## Отчёт и прогресс

- `Reporting.ps1` пишет итоговый TXT с отметками начала и завершения этапов, временем работы, средой и идентификатором отчёта. При исключении сохраняются файл, строка, код HRESULT и код Windows, если он доступен.
- Общий индикатор считает завершённые шаги. Архив, OpenPGP, SHA-256 и передача по сети показывают байты. Обработка папок, файлов и настроек использует известное число объектов. В сетевой передаче учитываются только байты, подтверждённые получателем.
- `ScanState` и `LoadState` показывают проценты из журнала USMT. При подготовке зависимостей загрузка показывает байты. При неизвестном объёме и ожидании внешнего процесса видны текущий этап, а при наличии данных - счётчики или время.
- После сбоя сначала найдите последнюю строку «ЭТАП НАЧАТ». Она помогает определить, где остановилась операция. В сетевом сценарии особенно важны шаг передачи, подтверждённое смещение и итог на получателе. Перед публикацией отчёта проверьте имена и пути.

## Проверки сборки

При запуске на Windows распакуйте весь ZIP и откройте `start.cmd`. Результаты автоматических проверок и стенда публикуются вместе с версией комплекта. [Скачать ZIP](https://raw.githubusercontent.com/Arhivater/WindowsProfileMigration/release/v1.11.1/dist/WindowsProfileMigration_v1.11.1.zip) · [Прогоны GitHub Actions](https://github.com/Arhivater/WindowsProfileMigration/actions?query=branch%3Arelease%2Fv1.11.1)
