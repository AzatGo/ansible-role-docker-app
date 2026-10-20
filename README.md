# Ansible role: docker_app

Роль скачивает [test_app](https://github.com/AzatGo/test_app) на машину запуска
Ansible и копирует исходные Dockerfile, Compose и код на сервер.
Небольшой `compose.override.yml` задаёт порт, ротацию логов и время остановки.
Healthcheck, ожидание PostgreSQL, образ БД и постоянный том берутся из исходного
проекта. PostgreSQL не публикуется наружу.

## Структура и использование

```text
defaults/main.yml       все публичные переменные роли
tasks/main.yml          порядок выполнения
tasks/docker.yml        Docker, Compose plugin, JSON-логи с ротацией
tasks/firewall.yml      iptables и восстановление правил
tasks/deploy.yml        файлы проекта и обновление контейнеров
tasks/prune.yml         cron и ежедневный docker system prune -f
handlers/main.yml      перезапуск Docker при изменении конфигурации
templates/             .env, Compose override и firewall
tests/                 проверки на отдельной Ubuntu 22.04 VM
```

Готовый плейбук, inventory `prod/staging`, установка зависимостей и работа с
Vault находятся в [test-app-deploy](https://github.com/AzatGo/test-app-deploy).
Роль устанавливается под именем `docker_app` и подключается так:

```yaml
- name: Deploy Notes
  hosts: docker_hosts
  become: true
  roles:
    - docker_app
```

Для установки только Docker и настройки JSON-логов:

```yaml
- name: Prepare Docker hosts
  hosts: docker_hosts
  become: true
  tasks:
    - name: Install Docker and configure logging
      ansible.builtin.import_role:
        name: docker_app
        tasks_from: docker
```

Этот блок не требует пароля БД или исходников приложения и не устанавливает
cron. Аналогично доступны `tasks_from: firewall`, `deploy` и `prune`:
они предполагают уже установленный Docker; `firewall` также использует
`/etc/docker/daemon.json`, созданный блоком `docker`.
Полный запуск применяет настройки Docker и firewall перед запуском приложения.

## Переменные

Все публичные переменные находятся в [defaults/main.yml](defaults/main.yml).
Переопределяйте их в inventory и `group_vars`; секреты храните в Ansible Vault.

| Переменная | По умолчанию | Назначение |
| --- | --- | --- |
| `docker_app_repo_url` | `https://github.com/AzatGo/test_app.git` | Репозиторий приложения |
| `docker_app_repo_version` | `094b0213d2c583d96dc412a6073ee171d4b6f12b` | Проверенный commit приложения; можно задать тег или другую версию |
| `docker_app_source_dir` | `{{ playbook_dir }}/.cache/test_app` | Checkout на машине запуска, общий для хостов плейбука |
| `docker_app_project_dir` | `/opt/test_app` | Каталог на сервере |
| `docker_app_project_name` | `test_app` | Compose project name и префикс тома БД |
| `docker_app_bind_address` | `0.0.0.0` | Адрес публикации приложения |
| `docker_app_port` | `8000` | Внешний TCP-порт приложения |
| `docker_app_ssh_port` | `ansible_port` или `22` | TCP-порт SSH для firewall |
| `docker_app_postgres_db` | `notes` | Имя базы |
| `docker_app_postgres_user` | `notes` | Пользователь БД |
| `docker_app_postgres_password` | пусто | Обязательный пароль БД |
| `docker_app_name` | `notes` | `APP_NAME` |
| `docker_app_log_level` | `INFO` | `LOG_LEVEL` |
| `docker_app_shutdown_delay` | `3` | Пауза завершения приложения, секунды |
| `docker_app_db_connect_timeout` | `5` | Таймаут подключения к БД, секунды |
| `docker_app_log_max_size` | `10m` | Размер одного JSON-лога |
| `docker_app_log_max_files` | `3` | Число файлов логов на контейнер |
| `docker_app_prune_hour` | `"3"` | Час очистки, время сервера |
| `docker_app_prune_minute` | `"0"` | Минута очистки |
| `docker_app_stop_timeout` | `75` | Ожидание корректной остановки, секунды |
| `docker_app_wait_timeout` | `180` | Ожидание здоровых сервисов, секунды |
| `docker_app_legacy_containers` | `[]` | Имена старых контейнеров для удаления |

Подключение внутри проекта фиксировано: `POSTGRES_HOST=db`,
`POSTGRES_PORT=5432`. Секреты записываются в `.env` с правами `0600`,
владельцем `root`; вывод и diff этой задачи отключены.
Имена БД и пользователя должны состоять из строчных латинских букв,
цифр и `_`, не начинаясь с цифры.

## Повторный запуск и старые контейнеры

Повторите ту же команду Ansible: изменённые исходники пересобираются,
Compose обновляет сервисы и удаляет orphan-контейнеры только своего проекта.
При изменении параметров логов сервисы пересоздаются благодаря настройкам
`logging` в override-файле. Том `test_app_postgres_data` сохраняется.

Для перехода с запуска вручную или с другого Compose-проекта явно перечислите
контейнеры, которые нужно остановить и удалить:

```yaml
docker_app_legacy_containers:
  - old-notes-app
```

Остальные контейнеры при развёртывании не удаляются. Если неизвестный контейнер
занимает порт приложения, запуск завершится ошибкой; укажите его в списке
только если он действительно относится к прежнему приложению.
Для подключения существующего тома сохраните прежнее `docker_app_project_name`.
Изменение имени проекта создаёт другой том; данные между томами не переносятся.
Изменение пароля в переменных не меняет пароль внутри уже созданной БД.
При обновлении PostgreSQL на другую major-версию нужна отдельная миграция.

## Docker, firewall и очистка

Docker CE и Compose plugin устанавливаются из официального APT-репозитория.
Конфликтующие distro-пакеты Docker/containerd удаляются, данные Docker остаются.
Настройки JSON-логов добавляются в существующий `/etc/docker/daemon.json`.
При изменении этого файла Docker перезапускается. Контейнеры без политики
автозапуска могут потребовать ручного запуска после перезапуска демона.

Firewall предназначен для отдельного сервера приложения: входящие TCP-порты
разрешены только для SSH и приложения. Разрешены также loopback, ответы на
установленные соединения, ICMP/ICMPv6 и DHCP. Остальные входящие соединения
блокируются, включая IPv6 при его наличии. Исходящие соединения и общение
контейнеров через стандартные Docker-мосты разрешены.

Опубликованные Docker-порты фильтруются через `DOCKER-USER` по исходному порту
до DNAT. Скрипт изменяет только свои цепочки и переходы в них;
systemd запускает его после старта Docker, в том числе после перезагрузки.
На хосте должен использоваться Docker backend `iptables`; параллельное
управление firewall через UFW/firewalld/nftables этой ролью не предусмотрено.

Файл `/etc/cron.d/docker-system-prune` задаёт ежедневный запуск
`/usr/bin/docker system prune -f`: удаляет остановленные
контейнеры, неиспользуемые сети, dangling-образы и неиспользуемый build cache
**всего Docker-хоста**. Тома не удаляются, флаг `--volumes` не используется.
Во время применения роли сама очистка не запускается.

## Необходимые тесты

Тесты запускаются на отдельной чистой VM Ubuntu 22.04. Они используют
тестовый пароль БД из `tests/converge.yml`; не запускайте их на prod/staging.
VM создаётся отдельно, Molecule и Python-фреймворки для тестов не требуются.

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
cp tests/inventory.example.yml tests/inventory.local.yml
```

Укажите адрес тестовой VM, SSH-пользователя и при необходимости путь к ключу
в `tests/inventory.local.yml`. При SSH через проброс порта задайте
`docker_app_ssh_port` равным порту sshd **внутри VM**.

```bash
ansible-playbook -i tests/inventory.local.yml tests/converge.yml --syntax-check
ansible-lint
bash tests/run.sh -i tests/inventory.local.yml
```

Первый play проверяет отдельный блок Docker без секретов приложения, второй
разворачивает проект. Проверки используют `assert`, `uri`, `service_facts`,
`stat`, а также `slurp` и команды только для чтения конфигурации:

- Docker и cron запущены и включены в автозапуск, Compose plugin доступен.
- В `daemon.json` включены JSON-логи с заданными пределами ротации.
- `.env` принадлежит root и имеет права `0600`, cron содержит нужное расписание.
- Активны переходы firewall для INPUT и DOCKER-USER.
- `/readyz` доступен с машины запуска, приложение подключается к PostgreSQL.

`tests/run.sh` выполняет два настоящих прогона и завершается ошибкой,
если во втором есть изменения или не был проверен ни один хост.
Эти проверки firewall подтверждают установку правил; полноценную проверку
блокировки лишнего порта следует проводить снаружи VM с работающим
тестовым listener.