[English](README.en.md) | **Русский**

# Antigravity Sandbox

> Изолированное окружение для Antigravity на базе VS Code Dev Containers

[![Dev Container](https://img.shields.io/badge/Dev%20Containers-Supported-blue.svg)](https://containers.dev/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Codeberg](https://img.shields.io/badge/Codeberg-Main_Repo-2185D0?logo=codeberg&logoColor=white)](https://codeberg.org/Retr0xCC/antigravity-sandbox)
[![GitHub](https://img.shields.io/badge/GitHub-Mirror-181717?logo=github&logoColor=white)](https://github.com/Retr0xCC/antigravity-sandbox)

---

## Обзор

При работе **Antigravity** выполняет shell-команды, изменяет файлы и обращается к сети. Запуск напрямую создает риски для хоста из-за ошибок модели или галлюцинаций.

**Antigravity Sandbox** изолирует агента внутри Docker-контейнера через спецификацию Dev Containers, решая три ключевые задачи:

* **Изоляция файловой системы:** агент ограничен рабочей директорией проекта внутри контейнера и не имеет доступа к файлам хоста (`~/.ssh`, токенам, переменным окружения и системным каталогам).
* **Блокировка доступа к локальной сети (LAN):** стандартный Docker bridge не изолирует локальную сеть хоста. В проекте сетевой периметр защищен на уровне ядра с помощью правил `iptables` и `ip rule` (через systemd-сервис), что исключает сканирование и доступ к локальным ресурсам (роутерам, NAS, другим машинам).
* **Чистота хост-системы:** все зависимости, пакетные менеджеры и временные файлы остаются внутри контейнера, не засоряя основную ОС.

Состояние сессий, история диалогов и авторизационные токены Antigravity сохраняются в выделенных Docker-томах (volumes), не смешиваясь с файлами пользователя.

---

## Модель изоляции и архитектура

```text
 ┌─────────────────────────────────────────────────────────────┐
 │                           Хост                              │
 │                                                             │
 │   Защищенные ресурсы (Недоступны контейнеру):               │
 │   - Домашний каталог хоста (~/.ssh, ~/.aws, ~/.gnupg)       │
 │   - Корневая файловая система хоста (/)                     │
 │   - Docker Socket хоста (/var/run/docker.sock)              │
 │   - Сетевые сокеты и порты хоста (SSH, Postgres, Ollama)    │
 │     через Netfilter INPUT DROP на agy0 (разрешен только DNS)│
 └───────────────────────────────┬─────────────────────────────┘
                                 │
                                 │  Монтируется только проект
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │                          Песочница                          │
 │                                                             │
 │   - Непривилегированный пользователь: 'vscode' (UID 1000)   │
 │   - Автопатч бинарника при сборке: QNIX-Dev agy patch       │
 │   - Сброшены сетевые привилегии: drop CAP_NET_ADMIN         │
 │   - Автообновление отключено: AGY_CLI_DISABLE_AUTO_UPDATE=1 │
 │   - Защита бинарника от перезаписи: chmod 555 agy           │
 │   - Изолированное рабочее пространство: /workspaces/<proj>  │
 │   - Персистентный том состояния:                            │
 │       agy-gemini-data ──► /home/vscode/.gemini              │
 └───────────────────────────────┬─────────────────────────────┘
                                 │
                                 │  Изолированная docker-сеть
                                 │
                                 ▼
 ┌─────────────────────────────────────────────────────────────┐
 │                            Сеть                             │
 │                                                             │
 │   - Подсеть: 172.16.151.0/24 (Интерфейс: agy0)              │
 │   - Выделенный апстрим DNS: 9.9.9.9 (Quad9 DNS)             │
 │   - Предотвращение утечек IPv6: IPv6 отключен               │
 │   - Netfilter DOCKER-USER DROP в RFC 1918 LAN               │
 │   - Netfilter INPUT DROP к портам хоста на agy0             │
 │   - Linux Policy Routing: unreachable в LAN                 │
 │   - Сохранение правил через Systemd: agy-sandbox-network    │
 └─────────────────────────────────────────────────────────────┘
```

### Реализация защиты

- **Защита сервисов хоста (цепочка INPUT):** Входящий трафик с интерфейса контейнера `agy0` к слушающим портам хоста (SSH, БД, Ollama, сокет демона Docker) сбрасывается правилом Netfilter `INPUT` (`-i agy0 -j DROP`). Разрешены только локальные DNS-запросы (порт 53 UDP/TCP) и установленные соединения (ESTABLISHED/RELATED).
- **Изоляция локальной сети (RFC 1918):** Транзитный трафик из подсети контейнера `172.16.151.0/24` в приватные диапазоны LAN (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) блокируется в цепочке пересылки `DOCKER-USER` и правилом маршрутизации ядра Linux (`ip rule ... unreachable`).
- **Персистентность правил (systemd):** Сетевая конфигурация и правила фильтрации управляются юнитом `agy-sandbox-network.service` (`Type=oneshot`, `RemainAfterExit=yes`), который вызывает `ensure-network.sh` при старте системы и `teardown-network.sh` при остановке.
- **Изолированный DNS (`--dns=9.9.9.9`):** Запросы резолвятся напрямую через Quad9 в обход резолвера хоста, что исключает утечки DNS и сканирование локальных хостов через NetBIOS/mDNS.
- **Сброс сетевых привилегий:** Контейнер запускается без capability `CAP_NET_ADMIN`, что запрещает манипуляции с raw-сокетами, подмену ARP или модификацию внутренних сетевых таблиц.
- **Защита бинарника от модификации:** Для зафиксированных версий (`AGY_VERSION != latest`) права на `agy` фиксируются на чтение и выполнение (`chmod 555`), а автообновление блокируется переменной `AGY_CLI_DISABLE_AUTO_UPDATE=1`. При использовании версии `latest` сохраняются стандартные права (`chmod 755`) и штатные автообновления.
- **Изоляция авторизации и истории:** Сессионные токены и история чатов сохраняются в выделенном Docker-томе (`agy-gemini-data -> /home/vscode/.gemini`), не смешиваясь с файлами в репозитории на хосте.
- **Ограничение монтирования:** В контейнер монтируется исключительно рабочая директория проекта (`${localWorkspaceFolder}` в `/workspaces/<project>`). Доступ к файловой системе хоста за пределами этого каталога закрыт.

---

## Быстрый старт: подключение к проекту

### Инициализатор agy-sandbox (TUI / CLI)

Развертывание песочницы в целевом репозитории:

```bash
# Клонировать репозиторий песочницы
git clone https://codeberg.org/Retr0xCC/antigravity-sandbox.git ~/.antigravity-sandbox

# Установить команду 'agy-sandbox' в ~/.local/bin
~/.antigravity-sandbox/scripts/init-sandbox.sh --install-bin

# Интерактивный режим (TUI):
agy-sandbox

# Либо инициализация напрямую через аргументы:
agy-sandbox /path/to/project
agy-sandbox /path/to/project [шаблон]
agy-sandbox /path/to/project [шаблон] -v 1.4.6
```

#### Параметры CLI

```text
Использование: agy-sandbox [ОПЦИИ] [КАТАЛОГ_ПРОЕКТА] [ШАБЛОН]

При запуске без аргументов открывается интерактивное меню (TUI).

Опции:
  -i, --interactive              Интерактивный выбор проекта, шаблона, версии и патча (TUI)
  -v, --agy-version <тег>        Зафиксировать версию Antigravity CLI (например, 1.4.6, latest)
  --patch                        Применить патч QNIX-Dev к бинарнику CLI (по умолчанию)
  --no-patch, --skip-patch       Отключить патч, оставить чистый официальный бинарник
  -l, --list                     Список доступных шаблонов
  -d, --diagnose                 Аудит и диагностика сетевых правил
  --service [КОМАНДА]            Управление systemd-сервисом (status | enable | disable | install)
  --install-bin                  Установить симлинк agy-sandbox в ~/.local/bin
  -h, --help                     Справка
```

#### Фиксация версий Antigravity CLI и патчинг

По умолчанию песочницы развертываются с зафиксированной стабильной версией CLI (`1.4.6`), что исключает непредвиденные поломки из-за обновлений upstream, и применяют патч `QNIX-Dev`.

* **Единая переменная управления (`AGY_VERSION`):** Переменная `AGY_VERSION` выполняет обе функции — задает установленный бинарник и активирует режим безопасности. При фиксации версии (`AGY_VERSION != latest`) песочница автоматически защищает бинарник от перезаписи (`chmod 555`) и отключает автообновления (`AGY_CLI_DISABLE_AUTO_UPDATE=true` в `~/.bashrc`). Для версии `latest` сохраняются стандартные права (`chmod 755`) и штатное автообновление.
* **Опциональный патчинг:** Передайте `--no-patch` (или выберите `No` на шаге 4 мастера TUI), чтобы использовать чистый официальный бинарник без сторонних модификаций. Флаг `--patch` принудительно включает патчинг.
* **Постоянная настройка по умолчанию в `base/devcontainer.json`:** Чтобы перманентно изменить дефолтную версию или состояние патчинга для всех будущих песочниц, достаточно отредактировать файл `base/devcontainer.json` (`build.args.AGY_VERSION`, `remoteEnv.AGY_VERSION` и `remoteEnv.AGY_PATCH`). Инициализатор считывает значения по умолчанию напрямую из этого файла.
* **Интерактивный TUI и CLI:** Мастер позволяет интерактивно выбрать версию (`1.4.6`, `latest`, произвольный тег) и включить/выключить патчер. В CLI доступны флаги `-v, --agy-version <тег>` и `--no-patch`.

Доступные профили шаблонов:
- `default` (по умолчанию) — Базовое чистое окружение: antigravity-cli, uv, git и стандартный набор утилит сборки.
- `rpi-edge-node` — Профиль для автоматизации граничных узлов и шлюзов с Ansible (2.15+), `ansible-lint`, `yamllint`, коллекцией `community.general`, Go (1.22+), клиентом OpenSSH и расширениями VS Code (`redhat.ansible`, `golang.go`, `redhat.vscode-yaml`, `even-better-toml`, `samuelcolvin.jinjahtml` для шаблонов Jinja2 `.j2`).
- `math-labs` — Профиль для математических вычислений и анализа данных с Python, Jupyter (`ms-toolsai.jupyter`), просмотрщиком PDF (`tomoki1207.pdf`), NumPy, SciPy, Matplotlib, SymPy и pandas.

---

## Настройка сетевой изоляции на хосте

Чтобы правила фильтрации (`nftables`/`iptables`) и маршрутизации (`ip rule`) автоматически поднимались при загрузке ОС, в проект включен systemd-сервис:

```bash
# Установить и активировать сервис в системе:
sudo agy-sandbox service install
sudo agy-sandbox service enable

# Проверить статус:
agy-sandbox service status

# При необходимости отключить правила:
sudo agy-sandbox service disable
```

---

### Проверка сетевой изоляции

Для верификации правил Netfilter, таблицы маршрутизации и доступности DNS предусмотрен встроенный аудит:

```bash
agy-sandbox diagnose
# Либо прямой запуск скрипта:
~/.antigravity-sandbox/scripts/diagnose.sh
```

---

## Запуск в VS Code

1. Откройте директорию проекта в VS Code:
   ```bash
   code /path/to/project
   ```

2. Откройте командную панель (`F1` или `Ctrl+Shift+P`) и выберите:
   ```text
   Dev Containers: Reopen in Container
   ```

3. Редактор соберет Docker-образ и выполнит первичную инициализацию (`setup.sh` через `postCreateCommand`): установит зависимости и применит патч для `agy`.

4. Запустите CLI в интегрированном терминале контейнера:
   ```bash
   agy
   ```

---

### Жизненный цикл контейнера (setup.sh)

Скрипт первичной настройки `setup.sh` выполняется один раз при создании контейнера (`postCreateCommand`):
* выставляет права на том `/home/vscode/.gemini`;
* опционально запускает патчер `QNIX-Dev/eligibility-antigravity-patcher` (при `AGY_PATCH=true`);
* условно блокирует запись в бинарник (`chmod 555`) при зафиксированной версии или оставляет `chmod 755` для `latest`;
* создает маркер `/home/vscode/.agy_initialized`, предотвращая повторное выполнение при перезапусках.

---

## Создание собственных шаблонов

`antigravity-sandbox` поддерживает два формата создания шаблонов:

### 1. Декларативный режим (рекомендуется)

Вместо дублирования базовых файлов `Dockerfile` и `setup.sh`, достаточно создать каталог `templates/<имя_шаблона>/` только с необходимыми манифестами:

- **`packages.txt`** *(опционально)* — системные пакеты для установки через `apt-get` (по одному на строку, поддерживаются комментарии `#`).
- **`extensions.txt`** *(опционально)* — идентификаторы расширений VS Code (например, `golang.go`, `ms-python.python`).
- **`settings.json`** *(опционально)* — параметры конфигурации редактора, объединяемые с `customizations.vscode.settings`.
- **`extra.Dockerfile`** *(опционально)* — дополнительные сборочные инструкции для образа (например, `uv tool install ...`).
- **`extra-setup.sh`** *(опционально)* — bash-команды, выполняемые при первичной инициализации контейнера.
- **`description.txt`** *(опционально)* — краткое описание для справки CLI (`--list`) и меню TUI (по умолчанию: `Custom sandbox profile`).

Инициализатор песочницы автоматически наследует базовую конфигурацию (`base/Dockerfile`, `base/setup.sh`, `base/devcontainer.json`), объединяя её с манифестами шаблона.

### 2. Режим полной конфигурации (Full Custom Mode)

Если требуется полностью переопределить среду сборки, поместите собственные файлы `devcontainer.json` и/или `Dockerfile` напрямую в каталог `templates/<имя_шаблона>/`. Инициализатор скопирует их в целевой проект без объединения с базовым слоем.

---

## Структура репозитория

```text
antigravity-sandbox/
├── .devcontainer/                  # Конфигурация Dev Container для разработки самой песочницы
├── .github/workflows/
│   └── docker-publish.yml          # Сборка multi-arch образов (linux/amd64, linux/arm64)
├── base/
│   ├── devcontainer.json           # Базовая спецификация Dev Container
│   ├── Dockerfile                  # Базовый Docker-образ
│   ├── install-agy.sh              # Автономный загрузчик CLI и фиксатор версий
│   └── setup.sh                    # Первичная настройка контейнера (патч agy, права на том)
├── scripts/
│   ├── ensure-network.sh           # Создание сети agy_net, правил Netfilter и ip rule
│   ├── teardown-network.sh         # Удаление сети agy_net и сброс правил фильтрации
│   ├── service.sh                  # Управление systemd-юнитом (agy-sandbox-network.service)
│   ├── diagnose.sh                 # Скрипт аудита сетевых правил и изоляции хоста
│   └── init-sandbox.sh             # Точка входа CLI (agy-sandbox) и TUI-меню
├── templates/
│   ├── default/                    # Базовый профиль (наследует конфигурацию base/)
│   │   └── description.txt
│   ├── math-labs/                  # Профиль для математических вычислений и анализа данных
│   │   ├── packages.txt            # Системные пакеты (python3, graphviz)
│   │   ├── extensions.txt          # Расширения VS Code (Jupyter, Python, PDF viewer)
│   │   ├── extra.Dockerfile        # Установка Python-библиотек (numpy, scipy, matplotlib)
│   │   ├── settings.json           # Конфигурация VS Code
│   │   └── description.txt
│   └── rpi-edge-node/              # Профиль для автоматизации граничных узлов и шлюзов
│       ├── packages.txt            # Системные пакеты (openssh-client, golang)
│       ├── extensions.txt          # Расширения VS Code (Ansible, Go, YAML, Jinja)
│       ├── extra.Dockerfile        # Установка ansible-core и ansible-lint
│       ├── settings.json           # Конфигурация VS Code
│       └── description.txt
├── .gitignore
├── LICENSE                         # GNU General Public License v3.0
├── README.en.md                    # Документация на английском языке
├── README.md                       # Симлинк на README.en.md (для главной страницы)
└── README.ru.md                    # Документация на русском языке
```

---

## Сторонние компоненты

При инициализации контейнера (`setup.sh`) используется сторонний скрипт:

* **[QNIX-Dev/eligibility-antigravity-patcher](https://github.com/QNIX-Dev/eligibility-antigravity-patcher)** (автор: [QNIX-Dev](https://github.com/QNIX-Dev))
  * **Назначение:** патчинг бинарника Antigravity CLI при сборке окружения.
  * **Лицензия:** MIT License.

---

## Лицензия

- **antigravity-sandbox** (скрипты сетевой изоляции, TUI, шаблоны окружений) — [GNU General Public License v3.0](LICENSE).
- **eligibility-antigravity-patcher** — [MIT License](https://github.com/QNIX-Dev/eligibility-antigravity-patcher/blob/main/LICENSE).
