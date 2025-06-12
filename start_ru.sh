#!/bin/bash

# Путь к исполняемому файлу клиента Shadowsocks
SS_CLIENT="/usr/bin/ss-local"

# Директория с конфигурационными файлами (можно изменить аргументом)
CONFIG_DIR="/$HOME/.config/shadowsocks/"

# Проверка наличия установленного клиента Shadowsocks
check_installed() {
    if [ ! -x "$SS_CLIENT" ]; then
        echo "Ошибка: Shadowsocks client (ss-local) не установлен или путь неверный!"
        echo "Проверьте установку: sudo apt install shadowsocks-libev"
        exit 1
    fi
}

#Создаём desktop entry для данного скрипта
check_and_create_desktop_entry() {
  # Получаем абсолютный путь к текущему скрипту
  script_path="$(realpath "$0")"
  script_directory="$(dirname "$(readlink -f "$0")")"

  # Директория для .desktop файлов
  target_dir="$HOME/.local/share/applications"
  mkdir -p "$target_dir"

  # Проверяем наличие .desktop файлов
  if [ -z "$(find "$target_dir" -maxdepth 1 -name 'shadowsocks_client.desktop' -print -quit)" ]; then
      # Создаём .desktop файл с корректным путём
      cat > "$target_dir/shadowsocks_client.desktop" << EOF
[Desktop Entry]
Name=Shadowsocks Client
Comment=Terminal shadowsocks client
Exec="$script_path"
Icon=$script_directory/icon_script.png
Terminal=true
Type=Application
Categories=Network;
EOF
    echo "Создан файл: $target_dir/shadowsocks_client.desktop"
    echo "Проверьте параметры Exec и Icon при необходимости"
else
    echo ".desktop файл уже существует. Действия не требуются."
fi
}

# Поиск JSON-конфигов
find_configs() {
    local configs=()

    # Ищем все .json файлы в указанной директории
    while IFS= read -r -d $'\0' file; do
        # Проверяем, содержит ли файл обязательные поля
        if grep -q '"server"' "$file" && grep -q '"password"' "$file"; then
            configs+=("$file")
        fi
    done < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.json" -print0)

    # Если конфигов не найдено
    if [ ${#configs[@]} -eq 0 ]; then
        echo "Не найдено ни одного конфигурационного файла (*.json) в директории: $CONFIG_DIR"
        echo "Убедитесь что файлы содержат поля 'server' и 'password'"
        exit 1
    fi

    echo "${configs[@]}"
}

# Интерактивное меню выбора конфига
select_config() {
    local configs=("$@")
    local menu_items=()

    # Подготовка пунктов меню для dialog
    for i in "${!configs[@]}"; do
        menu_items+=("$((i+1))" "$(basename "${configs[$i]}")")
    done

    clear
    # Вызов диалогового окна
    choice=$(dialog --keep-tite --menu "Выберите конфигурацию Shadowsocks" 20 50 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    clear

    if [ -n "$choice" ]; then
        local index=$((choice-1))
        CONFIG_FILE="${configs[$index]}"
    else
        echo "Отменено пользователем"
        exit 0
    fi
}

# Настройка прокси в GNOME через gsettings
configure_gnome_proxy() {
    local port="$1"

    # Проверяем наличие gsettings
    if ! command -v gsettings &> /dev/null; then
        echo "gsettings не найден. Пропускаем настройку прокси."
        return
    fi

    echo "Настройка прокси для GNOME"
    echo "SOCKS-прокси: 127.0.0.1:$port"

    # Сохраняем текущие настройки для возможного восстановления
    OLD_PROXY_MODE=$(gsettings get org.gnome.system.proxy mode)
    OLD_SOCKS_HOST=$(gsettings get org.gnome.system.proxy.socks host)
    OLD_SOCKS_PORT=$(gsettings get org.gnome.system.proxy.socks port)

    # Устанавливаем новые настройки
    gsettings set org.gnome.system.proxy mode 'manual'
    gsettings set org.gnome.system.proxy.socks host '127.0.0.1'
    gsettings set org.gnome.system.proxy.socks port "$port"

    echo "Прокси успешно настроен для GNOME"
}

# Сброс настроек прокси в GNOME
reset_gnome_proxy() {
    if ! command -v gsettings &> /dev/null; then
        return
    fi

    # Восстанавливаем предыдущие настройки
    if [ -n "$OLD_PROXY_MODE" ]; then
        gsettings set org.gnome.system.proxy mode "$OLD_PROXY_MODE"
    fi

    if [ -n "$OLD_SOCKS_HOST" ]; then
        gsettings set org.gnome.system.proxy.socks host "$OLD_SOCKS_HOST"
    fi

    if [ -n "$OLD_SOCKS_PORT" ]; then
        gsettings set org.gnome.system.proxy.socks port "$OLD_SOCKS_PORT"
    fi

    echo "Настройки прокси сброшены для GNOME"
}

# Запуск клиента
start_proxy() {
    echo "================================="
    echo "Запуск Shadowsocks клиента"
    echo "Конфигурация: $CONFIG_FILE"
    echo "Исполняемый файл: $SS_CLIENT"
    echo "Для остановки нажмите Ctrl+C"
    echo "================================="

    # Определяем локальный порт из конфига
    if ! command -v jq &> /dev/null; then
        echo "Установка jq для парсинга JSON..."
        sudo apt update
        sudo apt install -y jq
    fi

    local_port=$(jq -r '.local_port' "$CONFIG_FILE")
    if [ -z "$local_port" ] || [ "$local_port" = "null" ]; then
        local_port=1080  # значение по умолчанию
    fi

    # Настраиваем прокси для GNOME
    configure_gnome_proxy "$local_port"

    # Установим обработчик для Ctrl+C
    trap 'cleanup' INT

    # Запуск с выбранным конфигом
    "$SS_CLIENT" -c "$CONFIG_FILE"
}

# Очистка перед выходом
cleanup() {
    clear
    echo "Остановка Shadowsocks и сброс настроек прокси..."
    reset_gnome_proxy
    exit 0
}

# Главная функция
main() {
    # Обработка аргумента (если указана другая директория)
    if [ -n "$1" ]; then
        if [ -d "$1" ]; then
            CONFIG_DIR="$1"
        else
            echo "Ошибка: Директория '$1' не существует!"
            exit 1
        fi
    fi

    # Проверки
    check_installed

    check_and_create_desktop_entry

    # Поиск и выбор конфига
    configs=($(find_configs))
    select_config "${configs[@]}"

    # Запуск
    start_proxy
}

# Запуск главной функции
main "$@"