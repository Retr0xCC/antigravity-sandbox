[English](README.md) | **Русский**

# Antigravity Sandbox 🛡️

> Безопасная, изолированная среда Dev Container для Google DeepMind Antigravity и ИИ кодинг-агентов.

[![CI Docker Publish](https://github.com/Retr0defeated/antigravity-sandbox/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/Retr0defeated/antigravity-sandbox/actions/workflows/docker-publish.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Dev Container](https://img.shields.io/badge/Dev%20Containers-Supported-blue.svg)](https://containers.dev/)

---

## 💡 Обзор

Автономные ИИ-агенты для написания кода (такие как **Antigravity CLI**, Claude Code, Aider) оперируют мощными системными инструментами: выполняют произвольные команды в терминале (`bash`, `run_command`), модифицируют файлы и обращаются к сети. Запуск таких агентов напрямую на рабочей станции разработчика сопряжен с серьезными угрозами:

1. **Радиус поражения хоста (Host Blast Radius):** Ошибочные команды, галлюцинации модели или атаки через prompt injection способны скомпрометировать персональные файлы (`~/.ssh`, `~/.aws`, `~/.kube`, `/etc/`).
2. **Уязвимость локальной сети (Local Network Exposure):** Работая в сетевом стеке хоста, агент может непреднамеренно просканировать или получить доступ к ресурсам домашней/корпоративной сети (LAN), IoT-устройствам, сетевым хранилищам или панелям управления.
3. **Засорение системы и конфликт зависимостей:** Установка глобальных пакетов, конфликтующие версии библиотек Python/Node и временные файлы загрязняют операционную систему.

**Antigravity Sandbox** решает эту проблему, предоставляя изолированную и защищенную среду **Dev Container**, строго следующую [спецификации Development Containers](https://containers.dev/). Все действия агента замыкаются внутри контролируемого контейнера с жестким сетевым периметром, а контекст диалогов и токены авторизации безопасно сохраняются в изолированных томах.

---

## 🔒 Столпы безопасности и архитектура

```text
 ┌─────────────────────────────────────────────────────────────┐
 │                Хостовая машина разработчика                 │
 │                                                             │
 │   Защищенные ресурсы (НЕДОСТУПНЫ контейнеру):               │
 │   - Домашний каталог хоста (~/.ssh, ~/.aws, ~/.gnupg)       │
 │   - Корневая файловая система хоста (/)                     │
 │   - Docker Socket хоста (/var/run/docker.sock)              │
 │   - Сетевые сокеты и порты хоста (SSH, Postgres, Ollama)    │
 │     через Netfilter INPUT DROP на agy0 (разрешен только DNS)│
 └───────────────────────────────┬─────────────────────────────┘
                                 │
                   Монтируется только проект
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │             Antigravity Sandbox (Dev Container)             │
 │                                                             │
 │   - Непривилегированный пользователь: 'vscode' (UID 1000)   │
 │   - Предустановлено: antigravity-cli, uv, git, сборщики     │
 │   - Без сетевых админ-прав: NO CAP_NET_ADMIN                │
 │   - Автообновление отключено: AGY_CLI_DISABLE_AUTO_UPDATE   │
 │   - Бинарник заблокирован: chmod 555 agy                    │
 │   - Изолированное рабочее пространство: /workspaces/<proj>  │
 │   - Персистентный том состояния:                            │
 │       agy-gemini-data ──► /home/vscode/.gemini              │
 └───────────────────────────────┬─────────────────────────────┘
                                 │
                    Изолированная docker-сеть
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │               Мост Docker-сети (agy_net)                    │
 │                                                             │
 │   - Подсеть: 172.16.151.0/24 (Интерфейс: agy0)              │
 │   - Выделенный апстрим DNS: 9.9.9.9 (Quad9 Secured DNS)     │
 │   - Предотвращение утечек IPv6: IPv6 отключен               │
 │   - Динамический Netfilter DOCKER-USER DROP в RFC 1918 LAN  │
 │   - Динамический Netfilter INPUT DROP к портам хоста на agy0│
 │   - Динамический Linux Policy Routing: unreachable в LAN    │
 │   - Персистентность через Systemd: agy-sandbox-network      │
 └─────────────────────────────────────────────────────────────┘
```

### Ключевые рубежи защиты

- **Защита рубежа хоста (Host Boundary, цепочка INPUT):** Входящие пакеты с интерфейса контейнера `agy0` к слушающим портам хоста (SSH порт 22, базы данных, Ollama порт 11434, демон Docker) сбрасываются в цепочке Netfilter `INPUT` (`-i agy0 -j DROP`). При этом сохраняются необходимые DNS-запросы (порт 53 UDP/TCP) и установленные соединения (ESTABLISHED/RELATED).
- **Динамическая изоляция локальной сети (LAN):** Исходящий транзитный трафик из подсети контейнера `172.16.151.0/24` в приватные подсети RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) блокируется в цепочке пересылки `DOCKER-USER` и через правила маршрутизации ядра Linux (`ip rule ... unreachable`).
- **Персистентность правил через Systemd:** Сетевые правила автоматически восстанавливаются при перезагрузке ОС с помощью легковесного сервиса `agy-sandbox-network.service` (`Type=oneshot`, `RemainAfterExit=yes`), вызывающего `ensure-network.sh` на старте и `teardown.sh` при выключении.
- **Контролируемый DNS (`--dns=9.9.9.9`):** Запросы резолвятся через безопасные серверы Quad9, исключая утечки DNS и попытки обнаружения локальных хостов через NetBIOS/mDNS.
- **Непривилегированный контейнер:** Контейнер запускается строго без capability `CAP_NET_ADMIN`, предотвращая манипуляции с raw-сокетами, подмену ARP или изменение сетевых таблиц.
- **Блокировка исполняемого файла CLI:** Права на пропатченный бинарник `agy` зафиксированы только на чтение и выполнение (`chmod 555`), а в окружении зафиксирован флаг `AGY_CLI_DISABLE_AUTO_UPDATE=true`.
- **Изоляция токенов и истории:** Учетные данные агента и история чатов сохраняются в независимом томе Docker (`agy-gemini-data -> /home/vscode/.gemini`), не попадая в рабочий каталог проекта на хосте.
- **Строгие границы монтирования:** В контейнер монтируется исключительно целевой каталог репозитория (`${localWorkspaceFolder}` в `/workspaces/<project>`). Доступ к остальной файловой системе хоста полностью закрыт.

---

## 🚀 Быстрый старт: подключение песочницы к проекту

### Способ 1: Интерактивный TUI или CLI-инициализатор

Чтобы развернуть Antigravity Sandbox в вашем репозитории:

```bash
# Клонируйте репозиторий песочницы (один раз)
git clone https://github.com/Retr0defeated/antigravity-sandbox.git ~/.antigravity-sandbox

# Установите глобальную команду 'agy-sandbox' в ~/.local/bin
~/.antigravity-sandbox/scripts/init-sandbox.sh --install-bin

# Запустите удобный интерактивный терминальный интерфейс (TUI)
agy-sandbox

# Либо инициализируйте проект напрямую через CLI:
agy-sandbox /path/to/your/project
agy-sandbox /path/to/rpi-edge-node rpi-edge-node
```

#### Параметры и команды CLI:

```text
Использование: agy-sandbox [ОПЦИИ] [ЦЕЛЕВОЙ_КАТАЛОГ] [ШАБЛОН]

При запуске без аргументов в терминале открывается интерактивный TUI.

Опции:
  -i, --interactive        Запустить интерактивный терминальный интерфейс (TUI)
  -l, --list               Показать список доступных шаблонов
  -d, --diagnose, diagnose Запустить аудит и диагностику безопасности сети
  --service [КОМАНДА]      Управление сервисом systemd (status|enable|disable|install)
  --install-bin            Создать симлинк agy-sandbox в ~/.local/bin
  -h, --help               Показать справку
```

Доступные профили шаблонов:
- `default` (по умолчанию) — Минимальная универсальная песочница с `antigravity-cli`, `uv`, `git` и базовыми утилитами сборки. Быстрая, легковесная, без лишних расширений.
- `rpi-edge-node` — Профиль для автоматизации граничных узлов и шлюзов с Ansible (2.15+), `ansible-lint`, `yamllint`, коллекцией `community.general`, Go (1.22+), клиентом OpenSSH и расширениями VS Code (`redhat.ansible`, `golang.go`, `redhat.vscode-yaml`, `even-better-toml`, `samuelcolvin.jinjahtml` для шаблонов Jinja2 `.j2`).

---

### Способ 2: Демон персистентности Systemd (Host Network Daemon)

Чтобы сетевые границы ядра (`ip rule`, `DOCKER-USER` и защита хоста `INPUT`) сохранялись после перезагрузки хоста:

```bash
# Включить и запустить демон персистентности systemd (вызывает ensure-network.sh при загрузке):
sudo agy-sandbox service enable
# Либо напрямую через systemctl:
sudo systemctl enable --now agy-sandbox-network.service

# Проверить статус демона:
agy-sandbox service status
sudo systemctl status agy-sandbox-network.service

# Отключить персистентность и очистить правила изоляции:
sudo agy-sandbox service disable
# Либо напрямую через systemctl:
sudo systemctl disable --now agy-sandbox-network.service
```

---

### Способ 3: Диагностика безопасности и аудит

Проверка всех 7 уровней изоляции ядра, правил Netfilter и периметра хоста:

```bash
agy-sandbox diagnose
# Либо запуск отдельного скрипта:
~/.antigravity-sandbox/scripts/diagnose.sh
```

---

### Способ 4: Ручная настройка

1. Создайте каталог `.devcontainer` в корне вашего проекта:
   ```bash
   mkdir -p .devcontainer
   ```
2. Скопируйте файлы из `templates/default/` (или `templates/rpi-edge-node/`):
   ```bash
   cp -r ~/.antigravity-sandbox/templates/default/* .devcontainer/
   ```
3. Примените правила изоляции сети на хосте:
   ```bash
   ~/.antigravity-sandbox/scripts/ensure-network.sh
   ```
4. Для удаления правил изоляции выполните:
   ```bash
   ~/.antigravity-sandbox/scripts/teardown.sh
   ```

---

## 🛠️ Использование с VS Code и Cursor

1. Откройте проект в VS Code или Cursor:
   ```bash
   code /path/to/your/project
   ```
2. Нажмите `F1` (или `Ctrl+Shift+P` / `Cmd+Shift+P`) и выберите:
   ```text
   Dev Containers: Reopen in Container
   ```
3. VS Code соберет образ из `Dockerfile`, смонтирует каталог проекта и выполнит инициализацию контейнера через `setup.sh` (`postCreateCommand`), в ходе которой автоматически загружаются зависимости и применяется патчер `eligibility-antigravity-patcher`.
4. Безопасно запускайте Antigravity CLI внутри контейнера:
   ```bash
   agy
   ```

---

## ⚡ Автоматический хук инициализации и производительность

Хук инициализации песочницы (`setup.sh`) является полностью **идемпотентным**:
1. При первом создании контейнера (`postCreateCommand`) он настраивает права на персистентный том и автоматически применяет первичный патч CLI с помощью [QNIX-Dev/eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher).
2. Он блокирует права на бинарник `agy` только на чтение/выполнение (`chmod 555`), защищая от перезаписи или нежелательного автообновления.
3. Создается файл-маркер `/home/vscode/.agy_initialized`.
4. Все последующие вызовы `agy` выполняются **мгновенно** без повторного обхода диска или переустановки пакетов.

---

## 🎨 Создание собственных шаблонов

`antigravity-sandbox` поддерживает два формата создания шаблонов:

### 1. Декларативный режим (рекомендуется)
Вместо дублирования 90% кода `Dockerfile` и `setup.sh`, создайте каталог `templates/<ваш-шаблон>/` только с необходимыми манифестами:

- **`packages.txt`** *(опционально)*: системные пакеты для установки через `apt-get` (по одному на строку, поддерживаются комментарии `#`).
- **`extensions.txt`** *(опционально)*: ID расширений VS Code для предустановки (например, `golang.go`, `ms-python.python`).
- **`settings.json`** *(опционально)*: персональные настройки редактора, объединяемые с `customizations.vscode.settings`.
- **`extra.Dockerfile`** *(опционально)*: дополнительные инструкции сборки образа (например, `uv tool install ...`).
- **`extra-setup.sh`** *(опционально)*: дополнительные bash-команды, выполняемые при инициализации контейнера.
- **`description.txt`**: краткое описание шаблона для CLI `--list` и меню TUI.

*Инициализатор песочницы автоматически наследует файлы `base/Dockerfile`, `base/setup.sh` и `base/devcontainer.json`, динамически внедряя ваши пакеты и расширения.*

### 2. Режим полного контроля (Full Custom Mode)
Если вам требуется полный контроль над конфигурацией Dev Container, просто разместите файлы `devcontainer.json` и/или `Dockerfile` внутри `templates/<ваш-шаблон>/`. Мастер распознает их и скопирует все файлы шаблона 1-в-1 без изменений.

---

## 📂 Структура репозитория

```text
antigravity-sandbox/
├── .devcontainer/                # Собственная конфигурация devcontainer для репозитория (default)
├── .github/
│   └── workflows/
│       └── docker-publish.yml    # Multi-arch CI пайплайн (linux/amd64 и linux/arm64)
├── base/
│   ├── devcontainer.json         # Базовая спецификация devcontainer
│   ├── Dockerfile                # Базовый универсальный образ
│   └── setup.sh                  # Однократный идемпотентный хук настройки (применяет eligibility-antigravity-patcher)
├── scripts/
│   ├── ensure-network.sh         # Настройка Netfilter (DOCKER-USER, INPUT) и ip rule
│   ├── teardown-network.sh       # Очистка сети, фаервола и маршрутизации
│   ├── teardown.sh               # Симлинк на teardown-network.sh
│   ├── service.sh                # Управление сервисом systemd (agy-sandbox-network.service)
│   ├── diagnose.sh               # Комплексный 7-уровневый аудит безопасности изоляции
│   └── init-sandbox.sh           # Интерактивный TUI и точка входа CLI (agy-sandbox)
├── templates/
│   ├── default/                  # Минимальная универсальная песочница (100% наследование из base)
│   │   └── description.txt       # Описание шаблона
│   └── rpi-edge-node/            # Декларативный профиль для граничной автоматизации
│       ├── packages.txt          # Дополнительные apt-пакеты (openssh-client, golang-go и др.)
│       ├── extensions.txt        # Расширения VS Code (ansible, go, yaml, jinja)
│       ├── extra.Dockerfile      # Дополнительные шаги сборки (ansible-core через uv)
│       ├── settings.json         # Персональные настройки VS Code
│       └── description.txt       # Описание шаблона
├── .gitignore
├── LICENSE                       # Лицензия GNU General Public License v3.0
├── README.md                     # Документация на английском языке
└── README.ru.md                  # Документация на русском языке
```

---

## 🤝 Благодарности и сторонние компоненты (Credits & Third-Party Notice)

Во время инициализации контейнера (`setup.sh`) проект автоматически загружает и применяет сторонний скрипт патчера:
- **[QNIX-Dev/eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher)** (автор: [QNIX-Dev](https://github.com/QNIX-Dev)):
  - **Роль:** обеспечивает первичный патчинг CLI Antigravity внутри контейнера для корректной работы окружения песочницы.
  - **Лицензия:** распространяется под лицензией [MIT License](https://github.com/QNIX-Dev/eligibility-antigravity-patcher/blob/main/LICENSE) и остаётся интеллектуальной собственностью его автора.

---

## 📄 Лицензирование (Licensing Clarification)

- **Проект `antigravity-sandbox`:** сам проект (скрипты изоляции, интерактивный TUI, конфигурации шаблонов и сетевые правила) распространяется под лицензией [GNU General Public License v3.0](LICENSE) (GNU GPLv3).
- **Сторонние компоненты:** сторонний компонент [eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher) от QNIX-Dev распространяется под лицензией **MIT License** и остаётся интеллектуальной собственностью его автора.
