# PVM — PHP Version Manager для XAMPP

Аналог `nvm` для Node.js, но для PHP в XAMPP. Одна команда — и все vhosts
работают на нужной версии PHP. Скачивает, распаковывает, настраивает и
переключает всё сам.

```
pvm use 8.4.25 -y
```

---

## 🚀 Быстрый старт

```powershell
# Установить (один раз)
cd C:\tools\pvm
.\install.bat

# Перезапустить консоль

# Установить PHP-версию
pvm install 8.4.25

# Переключить XAMPP на неё
pvm use 8.4.25 -y

# Проверить
pvm current
```

---

## 📦 Установка

### Требования

- **Windows 10/11**
- **XAMPP** (проверено на 7.x – 8.x)
- **PowerShell 5.1+**
- **curl.exe** (встроен в Windows 10 1803+)
- **tar.exe** (встроен в Windows 10 1803+)

### Шаги

1. Скопируйте папку `pvm` в `C:\tools\pvm`:

   ```
   C:\tools\pvm\
   ├── pvm.ps1
   ├── pvm.cmd
   ├── install.bat
   └── README.md
   ```

2. Запустите **`install.bat`** двойным кликом — он добавит `C:\tools\pvm` в
   пользовательский `PATH`.

3. **Закройте и откройте заново** PowerShell/cmd.

4. Проверьте:

   ```powershell
   pvm help
   ```

---

## 🎯 Использование

### Основные команды

| Команда | Что делает |
|---|---|
| `pvm install <ver>` | Скачать и установить PHP-версию |
| `pvm use <ver>` | Переключить XAMPP на эту версию (все vhosts) |
| `pvm list` / `pvm ls` / `pvm -l` | Показать установленные версии |
| `pvm current` | Показать активную версию |
| `pvm list-remote [prefix]` | Показать доступные для скачивания |
| `pvm uninstall <ver>` | Удалить версию |

### Дополнительные команды

| Команда | Что делает |
|---|---|
| `pvm tune [ver\|--all]` | Применить лимиты, UTF-8 и curl-deps к `php.ini` |
| `pvm backup create` | Создать бэкап конфигов вручную |
| `pvm backup list` | Список бэкапов |
| `pvm backup restore <id>` | Восстановить состояние из бэкапа |
| `pvm backup prune` | Удалить старые бэкапы |
| `pvm update-cache` | Обновить кэш версий PHP (с windows.php.net) |
| `pvm xampp [path]` | Показать/задать путь к XAMPP |
| `pvm init` | Мигрировать папку `php` в junction |
| `pvm help` / `pvm -h` | Справка |
| `pvm -v` / `pvm --version` | Версия pvm |

### Флаги

| Флаг | Что делает |
|---|---|
| `-y`, `--yes` | Не спрашивать подтверждения |
| `--dry-run` | Показать план без изменений |
| `--no-backup` | Пропустить авто-бэкап (⚠️ ОПАСНО) |
| `--keep-backups=N` | Хранить N последних бэкапов (по умолчанию 10) |

### Примеры

```powershell
# Установить PHP 8.2, потом переключиться
pvm install 8.2.29
pvm use 8.2.29 -y

# Вернуться на 7.4 (тоже одной командой)
pvm use 7.4.33 -y

# Посмотреть, что вообще доступно из PHP 8.3.x
pvm list-remote 8.3

# План переключения без изменений
pvm use 8.4.25 --dry-run

# Применить лимиты/UTF-8 ко всем версиям сразу
pvm tune --all
Restart-Service Apache2.4

# Откатить последнее переключение
pvm backup list
pvm backup restore 20260929-131036-use-7.4.33
```

---

## 🔧 Как это работает

### Архитектура

```
C:\xampp\php ─── junction ──▶ ~\.pvm\versions\<активная-версия>\
                              │
                              ├── 7.4.33\
                              ├── 8.2.29\
                              └── 8.4.25\
```

**Junction (`mklink /J`)** — это как ярлык, но на уровне файловой системы.
`C:\xampp\php` остаётся на месте, но «указывает» на папку с нужной версией.
Apache и PHP работают с абсолютными путями `/php/...` — и не замечают, что
это junction.

**Переключение** (`pvm use`) делает:

1. Останавливает службу Apache
2. Создаёт junction `C:\xampp\php` → `~\.pvm\versions\<версия>`
3. Правит `httpd-xampp.conf`:
   - `LoadModule php7_module` (для PHP 7.x) или `php_module` (для 8.x)
   - `LoadFile phpXts.dll` — нужное имя
   - `LoadFile libcrypto-X-X64.dll`, `libssh2.dll` и т.д. — зависимости curl
4. Проверяет конфиг через `httpd -t`
5. Запускает службу
6. Проверяет health-check через `http://127.0.0.1/`

### Что делает `pvm install`

1. Скачивает ZIP с **windows.php.net** (`curl.exe`)
2. Распаковывает через **`tar.exe`** (не `Expand-Archive` — он теряет файлы!)
3. Копирует зависимости curl (`libssh2.dll`, `libcrypto-*.dll` и т.д.) в `ext/`
4. Создаёт `php.ini` из `php.ini-development`
5. Включает нужные расширения: `curl`, `gd`, `mbstring`, `mysqli`, `intl`,
   `openssl`, `zip`, `sockets` и т.д.
6. Ставит лимиты: `upload_max_filesize=512M`, `memory_limit=1024M`,
   `max_execution_time=600`
7. Устанавливает `default_charset = "UTF-8"`

### Что делает `pvm use` **автоматически**

- **Проверяет совместимость** Apache ↔ PHP:
  - PHP 7.4 требует Apache **VC15+**
  - PHP 8.0–8.3 требуют **VS16+**
  - PHP 8.4+ требует **VS17+**
- Если Apache не подходит — **скачивает** нужную сборку с
  [apachelounge.com](https://www.apachelounge.com/download/), делает бэкап
  старого и **заменяет** `bin/` и `modules/`
- Регенерирует SSL-сертификат, если он 1024-битный (новый Apache требует 2048+)
- **Автоматически откатывает** всё, если что-то пошло не так

---

## 📁 Структура файлов

```
C:\tools\pvm\
├── pvm.ps1          # Основной скрипт (PowerShell)
├── pvm.cmd          # Обёртка для cmd.exe
├── install.bat      # Добавляет папку в PATH
└── README.md

%USERPROFILE%\.pvm\
├── versions\        # Скачанные версии PHP
│   ├── 7.4.33\
│   ├── 8.2.29\
│   └── 8.4.25\
├── phpmyadmin\      # Версии phpMyAdmin
│   └── 5.2.3\
├── cache\           # Скачанные ZIP-архивы
│   └── php-8.4.25-Win32-vs17-x64.zip
├── backups\         # Бэкапы перед каждой операцией
│   ├── 20260929-131036-use-7.4.33\
│   └── apache-VC15-to-VS17-20260929-130418\
├── config.json      # Настройки (путь к XAMPP, имя службы)
└── pvm.lock         # Lock-файл (защита от параллельного запуска)
```

---

## 🛡️ Безопасность и откаты

### Автоматический откат

Если `pvm use` **на любой стадии** потерпит неудачу:

- Apache не запустился
- `httpd -t` вернул ошибку
- junction не создался
- health-check провалился

Скрипт **сам** восстановит предыдущее состояние:

1. `httpd-xampp.conf` → из бэкапа
2. `C:\xampp\php` → на старую версию
3. `phpMyAdmin` junction → на старую версию
4. `config.inc.php` → из бэкапа
5. Перезапустит Apache

### Ручной откат

```powershell
# Список бэкапов
pvm backup list

# Восстановить конкретный
pvm backup restore 20260929-131036-use-7.4.33

# Или создать новый сейчас (перед экспериментами)
pvm backup create
```

### Что **не** трогает pvm

- `C:\xampp\htdocs` — ваши сайты
- `C:\xampp\mysql` — база данных
- `wp-content` в WP-проектах
- Любые другие папки вне `C:\xampp\php`, `C:\xampp\apache\bin`,
  `C:\xampp\apache\modules`, `C:\xampp\apache\conf\extra\httpd-xampp.conf`

---

## ⚠️ Известные ограничения

### Права администратора

`pvm use` **требует прав администратора** для управления службой `Apache2.4`.
Запускайте PowerShell **от имени администратора**.

Если запустить от обычного пользователя — всё сделает, но Apache не
перезапустит:

```
Не удалось открыть службу Apache2.4 на компьютере '.'
```

### Одна версия PHP на всё

`pvm` — **глобальный** переключатель, как `nvm`. Все vhosts одновременно
работают на **одной** версии PHP.

Если нужно **разные** версии PHP одновременно для разных vhosts — это уже
архитектура **FastCGI** (`mod_proxy_fcgi`), а не `pvm`.

### WordPress на разных версиях

WordPress + плагины **чувствительны** к версии PHP. Часто:

- Плагины, работающие на 7.4, падают с fatal на 8.4
- WordPress **сам деактивирует** плагин при fatal (сохраняет в БД)
- Обратно вернув PHP 7.4, вы получите сайт без плагина — нужно **активировать
  вручную**

**Перед `pvm use` на WP-проекте**:
1. Сделайте дамп БД: `mysqldump -u root db_name > backup.sql`
2. Или закоммитьте `wp-content/` в git
3. После возврата — **активируйте плагины в админке**

### Антивирус

Windows Defender и другие антивирусы могут **сканировать** `php.exe`,
`php8ts.dll` и т.д. при каждом вызове — это сильно замедляет `pvm list`,
`pvm use`. Добавьте в **исключения**:

```
C:\tools\pvm\
%USERPROFILE%\.pvm\
C:\xampp\php\
C:\xampp\apache\bin\
```

Для Windows Defender:

```powershell
Add-MpPreference -ExclusionPath 'C:\tools\pvm'
Add-MpPreference -ExclusionPath "$env:USERPROFILE\.pvm"
Add-MpPreference -ExclusionPath 'C:\xampp\php'
Add-MpPreference -ExclusionPath 'C:\xampp\apache\bin'
```

### Кэш версий

Список доступных PHP кэшируется на **6 часов** (`~\.pvm\cache\php-remote.json`).
Обновить:

```powershell
pvm update-cache
```

---

## 🐛 Troubleshooting

### `pvm help` ничего не выводит / каскад ошибок парсинга

Файл `pvm.ps1` **потерял BOM** или **повреждён**. Проверить:

```powershell
$b = [System.IO.File]::ReadAllBytes('C:\tools\pvm\pvm.ps1')
if ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
    "BOM: OK"
} else {
    "BOM: НЕТ — сохраните файл как UTF-8 with BOM"
}
```

Открыть в VS Code → правый нижний угол → `UTF-8` → **Save with Encoding** →
**UTF-8 with BOM**.

### `pvm list` виснет

Антивирус сканирует `~\.pvm\versions\`. Добавьте папку в исключения.

### `Cannot load C:/xampp/php/phpXts.dll into server`

Зависимости PHP не загружены до модуля. Проверьте `httpd-xampp.conf`:

```powershell
Select-String -Path 'C:\xampp\apache\conf\extra\httpd-xampp.conf' -Pattern 'LoadFile|LoadModule'
```

Должны быть `LoadFile` для `libssh2.dll`, `libcrypto-*.dll` и т.д. **перед**
`LoadModule php*_module`.

Если нет — `pvm use <та-же-версия>` восстановит.

### `curl_init` в CLI `YES`, а в web `NO`

Классика: `php.exe` (CLI) видит DLL в своей папке, `httpd.exe` (LocalSystem)
— нет. Лечится `LoadFile` в `httpd-xampp.conf`. `pvm use` делает это сам.

### 500 в браузере, пустой ответ

Проверьте лог Apache:

```powershell
Get-Content 'C:\xampp\apache\logs\error.log' -Tail 40
```

Скорее всего: SSL-сертификат (1024-bit), или PHP-модуль не загрузился, или
несовместимость версий PHP ↔ Apache. Запустите `pvm use <версия>` ещё раз —
он сам всё проверит и поправит.

### phpMyAdmin не открывается / виснет

1. Проверьте **MySQL** запущен:
   ```powershell
   Get-Service mysql | Select Status
   ```
2. Очистите сессии:
   ```powershell
   Get-ChildItem 'C:\xampp\tmp\sess_*' | Remove-Item -Force
   ```
3. Проверьте `curl` в web (см. выше).

### `LoadModule php_module` на PHP 7.4 — `Can't locate API module structure`

В PHP 7.4 модуль называется `php7_module`, а не `php_module`. Обновите
`pvm.ps1` до v3.0 (или новее) — он определяет правильное имя по имени DLL.

---

## 📝 TODO / Roadmap

- [ ] Автоповышение до администратора через UAC
- [ ] `pvm doctor` — диагностика окружения
- [ ] Проверка целостности распакованных DLL после `install`
- [ ] Поддержка **FastCGI** для одновременной работы разных версий
- [ ] `pvm pma install/use/update` — полное управление phpMyAdmin

---

## 📜 Лицензия

MIT. Делайте что хотите.

---

## 🙏 Благодарности

- [windows.php.net](https://windows.php.net/) — за официальные сборки PHP
- [Apache Lounge](https://www.apachelounge.com/) — за сборки Apache под разные
  VS-компиляторы
- [phpMyAdmin](https://www.phpmyadmin.net/) — за замечательный инструмент