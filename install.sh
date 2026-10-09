#!/bin/sh
# PS5 OpenWrt. Local server and guided installation for BusyBox ash.
# SC2015: chained validators deliberately fail if any check fails.
# shellcheck disable=SC2015
set -eu
umask 077
LC_ALL=C
export LC_ALL

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$(printf '\033[0m')
    C_TITLE=$(printf '\033[1;36m')
    C_INFO=$(printf '\033[0;37m')
    C_OK=$(printf '\033[1;32m')
    C_WARN=$(printf '\033[1;33m')
    C_ERROR=$(printf '\033[1;31m')
    C_PROMPT=$(printf '\033[1;34m')
else
    C_RESET=''; C_TITLE=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERROR=''; C_PROMPT=''
fi

OWNER='ps5-openwrt'
SELF=$(readlink -f "$0")
REPO_DIR=$(dirname "$SELF")
SOURCE="$REPO_DIR/www"
ROOT_PREFIX=${PS5OW_TEST_ROOT:-}
if [ -n "$ROOT_PREFIX" ]; then
    [ "${PS5OW_TEST_MODE:-0}" = 1 ] || { printf '%s\n' 'Test root requires PS5OW_TEST_MODE=1.' >&2; exit 2; }
    case "$ROOT_PREFIX" in /*) ;; *) exit 2 ;; esac
    [ "$ROOT_PREFIX" != / ] || exit 2
fi

path() { printf '%s%s\n' "$ROOT_PREFIX" "$1"; }
BASE=$(path /etc/ps5-openwrt)
BACKUPS=$(path /root/ps5-openwrt-backups)
LOCK=$(path /var/lock/ps5-openwrt.lock)
TEMP=''
LOCKED=0
TRANSACTION=0
BACKUP=''
STAGE=''
OLD_SITE=''

msg() { printf '%s%s%s\n' "$C_INFO" "$*" "$C_RESET"; }
ok() { printf '%s%s%s\n' "$C_OK" "$*" "$C_RESET"; }
fail() { printf '%sОШИБКА: %s%s\n' "$C_ERROR" "$*" "$C_RESET" >&2; exit 1; }
u() {
    if [ -n "$ROOT_PREFIX" ]; then
        command uci -c "$(path /etc/config)" -t "$(path /tmp/uci-delta)" "$@"
    else
        command uci "$@"
    fi
}
get() { u -q get "$1" 2>/dev/null || true; }
sections() {
    u -q show "$1" 2>/dev/null | awk -F= -v c="$1" -v t="$2" '$2==t {sub("^" c "\\.", "", $1); print $1}' || true
}
service() {
    if [ -n "$ROOT_PREFIX" ]; then ps5ow-test-service "$1" "$2"
    else "$(path "/etc/init.d/$1")" "$2"; fi
}
yesno() {
    printf '%s%s [y/N]: %s' "$C_PROMPT" "$1" "$C_RESET"
    IFS= read -r answer || return 1
    case "$answer" in y|Y|yes|YES|д|Д|да|Да) return 0 ;; *) return 1 ;; esac
}
ask() {
    printf '%s%s [%s]: %s' "$C_PROMPT" "$1" "$2" "$C_RESET" >&2
    IFS= read -r answer || fail 'Ввод завершён. Запускайте мастер в интерактивном SSH-сеансе.'
    printf '%s\n' "${answer:-$2}"
}
safe_id() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_-]*$'; }
valid_mac() {
    printf '%s\n' "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' || return 1
    case "$(printf '%s' "$1" | cut -c 2)" in 0|2|4|6|8|a|A|c|C|e|E) ;; *) return 1 ;; esac
    [ "$(printf '%s' "$1" | tr 'A-F' 'a-f')" != '00:00:00:00:00:00' ]
}
valid_ip() {
    case "$1" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s\n' "$1" | awk -F. 'NF!=4 {exit 1} {for(i=1;i<=4;i++) if($i=="" || $i+0>255 || (length($i)>1 && substr($i,1,1)=="0")) exit 1}'
}
valid_name() {
    [ "${#1}" -le 63 ] && printf '%s\n' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
}
valid_domain() {
    [ "${#1}" -le 253 ] || return 1
    case "$1" in ''|.*|*.|*..*) return 1 ;; esac
    domain_rest=$1
    while :; do
        label=${domain_rest%%.*}
        valid_name "$label" || return 1
        case "$domain_rest" in *.*) domain_rest=${domain_rest#*.} ;; *) break ;; esac
    done
}
same_subnet() {
    valid_ip "$1" && valid_ip "$2" || return 1
    printf '%s\n' "$3" | grep -Eq '^([0-9]|[12][0-9]|3[0-2])$' || return 1
    awk -v a="$1" -v b="$2" -v p="$3" 'BEGIN {split(a,x,".");split(b,y,".");n=m=0;for(i=1;i<=4;i++){n=n*256+x[i];m=m*256+y[i]}d=2^(32-p);exit(int(n/d)!=int(m/d))}'
}
host_ip() {
    same_subnet "$1" "$2" "$3" || return 1
    [ "$1" != "$2" ] || return 1
    awk -v a="$1" -v p="$3" 'BEGIN {split(a,x,".");n=0;for(i=1;i<=4;i++)n=n*256+x[i];d=2^(32-p);h=n-int(n/d)*d;exit(h==0 || h==d-1 || p>30)}'
}
safe_site() {
    case "$1" in /srv/*|/mnt/*) ;; *) return 1 ;; esac
    case "$1" in *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.|*//*) return 1 ;; esac
    [ "$1" != /srv/ ] && [ "$1" != /mnt/ ]
}
valid_port() { printf '%s\n' "$1" | grep -Eq '^[0-9]{4,5}$' && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }
owned() { [ -f "$BASE/owner" ] && [ "$(cat "$BASE/owner")" = "$OWNER" ]; }
owned_site() { [ -f "$1/.ps5-openwrt-site" ] && [ "$(cat "$1/.ps5-openwrt-site")" = "$OWNER" ]; }
managed_sections() {
    case "$1" in
        dhcp) msg 'ps5ow_host ps5ow_names' ;;
        firewall) msg 'ps5ow_block ps5ow_dns ps5ow_http ps5ow_https' ;;
        uhttpd) msg 'ps5ow' ;;
    esac
}

need_root() {
    [ "$(id -u)" = 0 ] || fail 'Нужен запуск от root на роутере.'
    for program in uci ubus jsonfilter fw4 nft ip netstat tar awk grep sed readlink sysupgrade sha256sum cmp gzip find sort sync; do
        command -v "$program" >/dev/null 2>&1 || fail "Не найдена штатная команда $program."
    done
    if [ -z "$ROOT_PREFIX" ]; then
        board=$(ubus call system board)
        distribution=$(printf '%s' "$board" | jsonfilter -e '@.release.distribution')
        release=$(printf '%s' "$board" | jsonfilter -e '@.release.version')
        [ "$distribution" = OpenWrt ] || fail 'Этот мастер предназначен для штатного OpenWrt.'
        case "$release" in 24.10.*|25.12.*) ;; *) fail "Версия $release не входит в проверяемую область 24.10 / 25.12. Прошивка автоматически не обновляется." ;; esac
    fi
    if command -v apk >/dev/null 2>&1; then PM=apk
    elif command -v opkg >/dev/null 2>&1; then PM=opkg
    else fail 'Не найден opkg или apk.'; fi
}
clean_uci() {
    pending=$(u changes)
    [ -z "$pending" ] || fail 'Есть несохранённые изменения UCI. Сначала примените или отмените их через LuCI/uci; мастер их не трогает.'
}
acquire_lock() {
    mkdir -p "$(dirname "$LOCK")"
    if ! mkdir "$LOCK" 2>/dev/null; then
        lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
        case "$lock_pid" in ''|*[!0-9]*) fail "Неизвестная блокировка: $LOCK" ;; esac
        if kill -0 "$lock_pid" 2>/dev/null; then fail "Уже работает экземпляр мастера, PID $lock_pid."; fi
        rm -f "$LOCK/pid"
        rmdir "$LOCK" || fail 'Не удалось удалить старую блокировку.'
        mkdir "$LOCK"
    fi
    printf '%s\n' "$$" > "$LOCK/pid"
    LOCKED=1
}
temp_dir() {
    [ -n "$TEMP" ] || { mkdir -p "$(path /tmp)"; TEMP=$(mktemp -d "$(path /tmp)/ps5-openwrt.XXXXXX"); }
}

load_settings() {
    owned || fail 'Сначала выберите консоль и сохраните параметры: пункт настройки.'
    [ "$(get ps5openwrt.main.owner)" = "$OWNER" ] || fail 'Неизвестный формат настроек.'
    MAC=$(get ps5openwrt.main.mac)
    PS5_IP=$(get ps5openwrt.main.ip)
    NAME=$(get ps5openwrt.main.name)
    FQDN=$(get ps5openwrt.main.fqdn)
    IFACE=$(get ps5openwrt.main.interface)
    DEVICE=$(get ps5openwrt.main.device)
    ZONE=$(get ps5openwrt.main.zone)
    ROUTER_IP=$(get ps5openwrt.main.router_ip)
    PREFIX=$(get ps5openwrt.main.prefix)
    DNS_PORT=$(get ps5openwrt.main.dns_port)
    HTTP_PORT=$(get ps5openwrt.main.http_port)
    HTTPS_PORT=$(get ps5openwrt.main.https_port)
    SITE=$(get ps5openwrt.main.site)
    HOST_REUSE=$(get ps5openwrt.main.host_reuse)
    STATE=$(get ps5openwrt.main.state)
    MODE=$(get ps5openwrt.main.mode)
    valid_mac "$MAC" && valid_ip "$PS5_IP" && valid_ip "$ROUTER_IP" && valid_name "$NAME" || fail 'Повреждены параметры MAC/IP/имени.'
    safe_id "$IFACE" && safe_id "$ZONE" && safe_id "$DEVICE" || fail 'Некорректные идентификаторы сети.'
    valid_port "$DNS_PORT" && valid_port "$HTTP_PORT" && valid_port "$HTTPS_PORT" || fail 'Некорректные порты.'
    [ "$DNS_PORT" != "$HTTP_PORT" ] && [ "$DNS_PORT" != "$HTTPS_PORT" ] && [ "$HTTP_PORT" != "$HTTPS_PORT" ] || fail 'Порты должны различаться.'
    safe_site "$SITE" || fail 'Некорректный каталог сайта.'
    valid_domain "$FQDN" || fail 'Некорректное локальное DNS-имя.'
    case "$STATE" in configured|prepared|installed|removed) ;; *) fail 'Неизвестное состояние настройки.' ;; esac
    case "$MODE" in uninstalled|offline|online) ;; *) fail 'Неизвестный режим.' ;; esac
    host_ip "$PS5_IP" "$ROUTER_IP" "$PREFIX" || fail 'Адрес консоли не является адресом хоста выбранной подсети.'
}

zone_for() {
    for zone_section in $(sections firewall zone); do
        for network in $(get "firewall.$zone_section.network"); do
            if [ "$network" = "$1" ]; then
                get "firewall.$zone_section.name"
                return
            fi
        done
    done
}
zone_section_for() {
    for zone_section in $(sections firewall zone); do
        if [ "$(get "firewall.$zone_section.name")" = "$1" ]; then msg "$zone_section"; return; fi
    done
}
interfaces_table() {
    temp_dir
    : > "$TEMP/interfaces"
    network_dump=$(ubus call network.interface dump)
    for net in $(printf '%s' "$network_dump" | jsonfilter -e '@.interface[*].interface'); do
        [ "$net" != loopback ] || continue
        status_json=$(ubus call "network.interface.$net" status)
        [ "$(printf '%s' "$status_json" | jsonfilter -e '@.up')" = true ] || continue
        net_ip=$(printf '%s' "$status_json" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null || true)
        net_prefix=$(printf '%s' "$status_json" | jsonfilter -e '@["ipv4-address"][0].mask' 2>/dev/null || true)
        net_device=$(printf '%s' "$status_json" | jsonfilter -e '@.l3_device' 2>/dev/null || true)
        net_zone=$(zone_for "$net")
        [ -n "$net_ip" ] && [ -n "$net_zone" ] && [ -n "$net_device" ] || continue
        safe_id "$net" && safe_id "$net_zone" && safe_id "$net_device" || continue
        printf '%s|%s|%s|%s|%s\n' "$net" "$net_device" "$net_zone" "$net_ip" "$net_prefix" >> "$TEMP/interfaces"
    done
}
devices_table() {
    temp_dir
    : > "$TEMP/devices.raw"
    for instance in $(sections dhcp dnsmasq); do
        leasefile=$(get "dhcp.$instance.leasefile")
        leasefile=${leasefile:-/tmp/dhcp.leases}
        case "$leasefile" in /*) ;; *) continue ;; esac
        if [ -f "$(path "$leasefile")" ]; then
            awk 'NF>=4 {print tolower($2) "|" $3 "|" $4 "|DHCP"}' "$(path "$leasefile")" >> "$TEMP/devices.raw"
        fi
    done
    for host in $(sections dhcp host); do
        host_ip_addr=$(get "dhcp.$host.ip")
        host_name=$(get "dhcp.$host.name")
        for host_mac in $(get "dhcp.$host.mac"); do
            printf '%s|%s|%s|static\n' "$(printf '%s' "$host_mac" | tr 'A-F' 'a-f')" "$host_ip_addr" "${host_name:-unknown}" >> "$TEMP/devices.raw"
        done
    done
    ip -4 neigh show | awk '{for(i=1;i<=NF;i++)if($i=="lladdr")print tolower($(i+1)) "|" $1 "|unknown|neighbour"}' >> "$TEMP/devices.raw"
    awk -F'|' '!seen[$1]++ {print}' "$TEMP/devices.raw" > "$TEMP/devices"
}
pick_device() {
    while :; do
        devices_table
        msg 'Выберите именно Wi-Fi MAC PS5. Имя/производитель не доказывают принадлежность консоли.'
        awk -F'|' '{printf "  %d) %-16s %-18s %-24s %s\n", NR,$2,$1,$3,$4}' "$TEMP/devices"
        msg '  m) Ввести MAC и текущий IP вручную'
        msg '  r) Обновить список'
        pick=$(ask 'Номер устройства / m / r' '')
        case "$pick" in
            r|R) continue ;;
            m|M)
                MAC=$(ask 'Wi-Fi MAC консоли' '')
                CURRENT_IP=$(ask 'Текущий IPv4 консоли' '')
                ;;
            ''|*[!0-9]*) msg 'Выберите номер из списка.'; continue ;;
            *)
                line=$(sed -n "${pick}p" "$TEMP/devices")
                [ -n "$line" ] || { msg 'Нет такого устройства.'; continue; }
                MAC=$(printf '%s' "$line" | cut -d'|' -f1)
                CURRENT_IP=$(printf '%s' "$line" | cut -d'|' -f2)
                ;;
        esac
        if valid_mac "$MAC" && valid_ip "$CURRENT_IP"; then break; fi
        msg 'Некорректный MAC или IPv4.'
    done
    MAC=$(printf '%s' "$MAC" | tr 'A-F' 'a-f')
}
pick_network() {
    interfaces_table
    : > "$TEMP/matching"
    while IFS='|' read -r net dev zone addr bits; do
        if same_subnet "$CURRENT_IP" "$addr" "$bits"; then
            printf '%s|%s|%s|%s|%s\n' "$net" "$dev" "$zone" "$addr" "$bits" >> "$TEMP/matching"
        fi
    done < "$TEMP/interfaces"
    count=$(wc -l < "$TEMP/matching" | tr -d ' ')
    [ "$count" -gt 0 ] || fail 'Не найдена сеть консоли. OpenWrt должен быть её шлюзом, без NAT между PS5 и этим роутером.'
    awk -F'|' '{printf "  %d) интерфейс=%s мост=%s зона=%s роутер=%s/%s\n",NR,$1,$2,$3,$4,$5}' "$TEMP/matching"
    choice=$(ask 'Сеть консоли' '1')
    case "$choice" in ''|*[!0-9]*) fail 'Некорректный номер сети.' ;; esac
    line=$(sed -n "${choice}p" "$TEMP/matching")
    [ -n "$line" ] || fail 'Нет такой сети.'
    IFACE=$(printf '%s' "$line" | cut -d'|' -f1)
    DEVICE=$(printf '%s' "$line" | cut -d'|' -f2)
    ZONE=$(printf '%s' "$line" | cut -d'|' -f3)
    ROUTER_IP=$(printf '%s' "$line" | cut -d'|' -f4)
    PREFIX=$(printf '%s' "$line" | cut -d'|' -f5)
}
port_used() { netstat -lntu 2>/dev/null | awk -v p="$1" '$1~/^(tcp|udp)/ && $4~(":" p "$"){found=1} END{exit !found}'; }
free_port() {
    candidate=$1
    while port_used "$candidate"; do candidate=$((candidate+1)); [ "$candidate" -lt "$(( $1 + 100 ))" ] || fail 'Не найден свободный порт.'; done
    msg "$candidate"
}
static_host_for_mac() {
    for host in $(sections dhcp host); do
        [ "$host" != ps5ow_host ] || continue
        for host_mac in $(get "dhcp.$host.mac"); do
            if [ "$(printf '%s' "$host_mac" | tr 'A-F' 'a-f')" = "$MAC" ]; then msg "$host"; fi
        done
    done
}
check_ip_conflict() {
    for host in $(sections dhcp host); do
        [ "$host" != ps5ow_host ] || continue
        if [ "$(get "dhcp.$host.ip")" = "$PS5_IP" ]; then
            found=0
            for m in $(get "dhcp.$host.mac"); do [ "$(printf '%s' "$m" | tr 'A-F' 'a-f')" != "$MAC" ] || found=1; done
            [ "$found" = 1 ] || fail "IP $PS5_IP уже зарезервирован для другого устройства ($host)."
        fi
    done
    devices_table
    while IFS='|' read -r m addr _rest; do
        if [ "$addr" = "$PS5_IP" ] && [ "$m" != "$MAC" ]; then fail "IP $PS5_IP встречается у другого MAC $m."; fi
    done < "$TEMP/devices.raw"
    # Silence is not proof that an arbitrary manually chosen address is unused.
    if [ "$PS5_IP" != "${CURRENT_IP:-$PS5_IP}" ]; then
        msg 'Адрес проверен по арендам, резервированиям и таблице соседей. Выключенное устройство со статическим IP обнаружить нельзя.'
    fi
}
check_network() {
    status_json=$(ubus call "network.interface.$IFACE" status)
    actual_ip=$(printf '%s' "$status_json" | jsonfilter -e '@["ipv4-address"][0].address')
    actual_device=$(printf '%s' "$status_json" | jsonfilter -e '@.l3_device')
    [ "$actual_ip" = "$ROUTER_IP" ] && [ "$actual_device" = "$DEVICE" ] || fail 'Сеть изменилась после выбора параметров. Выполните настройку заново.'
    [ "$(zone_for "$IFACE")" = "$ZONE" ] || fail 'Изменилась зона интерфейса.'
    zone_section=$(zone_section_for "$ZONE")
    input_policy=$(get "firewall.$zone_section.input")
    case "$input_policy" in
        ''|ACCEPT) ;;
        *) fail "У зоны $ZONE Input=$input_policy. Эта версия мастера требует обычную LAN с Input=ACCEPT." ;;
    esac
    zone_family=$(get "firewall.$zone_section.family")
    case "$zone_family" in ''|any) ;; *) fail 'У зоны ограничено семейство адресов; нужна адаптация DNS-перенаправления.' ;; esac
    instances=$(sections dhcp dnsmasq | wc -l | tr -d ' ')
    [ "$instances" = 1 ] || fail 'Поддерживается один основной экземпляр dnsmasq. Несколько DNS требуют адаптации.'
    main_instance=$(sections dhcp dnsmasq)
    main_port=$(get "dhcp.$main_instance.port")
    case "$main_port" in ''|53) ;; *) fail 'Основной dnsmasq не обслуживает DNS на 53; сначала адаптируйте нестандартную DNS-схему.' ;; esac
    [ "$(get "dhcp.$IFACE.ignore")" != 1 ] || fail 'DHCP выбранного интерфейса отключён.'
    if pidof AdGuardHome >/dev/null 2>&1 || pidof unbound >/dev/null 2>&1; then
        fail 'Обнаружен работающий AdGuard Home/unbound. Автоматическая настройка для этой DNS-схемы не предусмотрена.'
    fi
    for section in $(sections firewall redirect); do
        case "$section" in ps5ow_dns|ps5ow_http|ps5ow_https) continue ;; esac
        [ "$(get "firewall.$section.enabled")" != 0 ] || continue
        for m in $(get "firewall.$section.src_mac"); do
            [ "$(printf '%s' "$m" | tr 'A-F' 'a-f')" != "$MAC" ] || fail "Есть другое перенаправление для этой PS5: $section. Мастер его не меняет."
        done
    done
}
check_collisions() {
    if [ -e "$BASE" ] && ! owned; then fail "Каталог $BASE существует и не принадлежит мастеру."; fi
    if ! owned; then
        [ ! -e "$(path /etc/config/ps5openwrt)" ] || fail 'Конфигурация ps5openwrt уже существует без маркера владельца.'
        for cfg in dhcp firewall uhttpd; do
            for section in $(managed_sections "$cfg"); do
                [ -z "$(get "$cfg.$section")" ] || fail "Чужой раздел $cfg.$section уже существует."
            done
        done
        [ ! -e "$(path /etc/init.d/ps5owdns)" ] || fail 'Служба ps5owdns уже существует без маркера владельца.'
    fi
}
validate_source() {
    [ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || fail 'Не найден каталог www рядом с install.sh.'
    [ -z "$(find "$SOURCE" ! -type d ! -type f -print)" ] || fail 'В сайте допустимы только файлы и каталоги.'
    [ ! -e "$SOURCE/cgi-bin/entry" ] || fail 'Имя CGI entry зарезервировано установщиком.'
    [ -z "$(find "$SOURCE" -name '.ps5*' -print)" ] || fail 'Сайт содержит служебные имена установщика.'
    for f in index.html LICENSE src/site.js src/main.js src/firmware.js src/rop.js \
        src/webkit.js src/relapse_exploit.js src/kexp.js src/utils/int64.js \
        src/utils/mem.js src/utils/rop_slave.js src/utils/syscalls.js \
        payloads/kexp_2026_05_25.bin payloads/elfldr-ps5-1360.elf \
        payloads/optional/manifest.json src/payloads-ui.js cgi-bin/payloads; do
        [ -s "$SOURCE/$f" ] || fail "Отсутствует www/$f."
    done
    [ -d "$SOURCE/offsets" ] && [ -n "$(find "$SOURCE/offsets" -type f -print)" ] || fail 'Нет offsets.'
    first_char=$(sed '/^[[:space:]]*$/d' "$SOURCE/payloads/optional/manifest.json" | head -n 1 | sed 's/^[[:space:]]*//' | cut -c 1)
    flat=$(tr -d ' \t\r\n' < "$SOURCE/payloads/optional/manifest.json")
    printf '%s\n' "$flat" | grep -Eq '^\[("[A-Za-z0-9][A-Za-z0-9_.-]*\.elf"(,"[A-Za-z0-9][A-Za-z0-9_.-]*\.elf")*)?\]$' ||
        fail 'manifest.json должен содержать массив имён ELF-файлов.'
    [ "$first_char" = '[' ] || fail 'manifest.json должен содержать массив имён ELF-файлов.'
    jsonfilter -i "$SOURCE/payloads/optional/manifest.json" -e '@[*]' > "$TEMP/optional.list" ||
        fail 'Некорректный manifest.json.'
    : > "$TEMP/optional.seen"
    while IFS= read -r optional_file; do
        printf '%s\n' "$optional_file" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*\.elf$' ||
            fail "Недопустимое имя дополнительной нагрузки: $optional_file"
        [ "${#optional_file}" -le 128 ] || fail 'Слишком длинное имя нагрузки.'
        if grep -Fx "$optional_file" "$TEMP/optional.seen" >/dev/null; then fail "Повтор в manifest.json: $optional_file"; fi
        printf '%s\n' "$optional_file" >> "$TEMP/optional.seen"
        [ -s "$SOURCE/payloads/optional/$optional_file" ] || fail "Не найден дополнительный ELF: $optional_file"
    done < "$TEMP/optional.list"
}

summary() {
    printf '\nКонсоль: %s (%s), IP %s\n' "$NAME" "$MAC" "$PS5_IP"
    printf 'Локальные имена: %s, %s\n' "$NAME" "$FQDN"
    printf 'Сеть: %s / %s / %s; роутер %s/%s\n' "$IFACE" "$DEVICE" "$ZONE" "$ROUTER_IP" "$PREFIX"
    printf 'Порты: DNS %s, HTTP %s, HTTPS %s\n' "$DNS_PORT" "$HTTP_PORT" "$HTTPS_PORT"
    printf 'Источник: %s\nСайт: %s\n\n' "$SOURCE" "$SITE"
}
configure() {
    CONFIGURED=0
    clean_uci
    check_collisions
    if owned; then
        load_settings
        case "$STATE" in installed|prepared)
            summary
            msg 'Файлы уже подготовлены. Для смены устройства или сети сначала удалите настройку.'
            return ;;
        esac
    fi
    pick_device
    pick_network
    HOST_REUSE=$(static_host_for_mac)
    reuse_count=$(printf '%s\n' "$HOST_REUSE" | awk 'NF{n++}END{print n+0}')
    [ "$reuse_count" -le 1 ] || fail 'Для MAC есть несколько статических аренд. Устраните дубликаты.'
    existing_name=''
    if [ -n "$HOST_REUSE" ]; then
        existing_name=$(get "dhcp.$HOST_REUSE.name" | awk '{print $1}')
    fi
    if [ -n "$existing_name" ]; then
        NAME=$existing_name
        msg "Используется существующее имя консоли: $NAME."
    else
        NAME=$(ask 'Имя консоли' ps5)
    fi
    NAME=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')
    valid_name "$NAME" || fail 'Имя должно содержать латинские буквы, цифры и дефис, до 63 символов.'
    local_domain=$(get 'dhcp.@dnsmasq[0].domain')
    local_domain=${local_domain:-lan}
    valid_domain "$local_domain" || fail 'Некорректный локальный домен dnsmasq.'
    FQDN="$NAME.$local_domain"
    if [ -n "$HOST_REUSE" ]; then
        PS5_IP=$(get "dhcp.$HOST_REUSE.ip")
        valid_ip "$PS5_IP" || fail 'Существующее резервирование не содержит обычный IPv4.'
        msg "Используется существующее резервирование $HOST_REUSE, IP $PS5_IP. Оно не будет изменено."
    else
        PS5_IP=$(ask 'Постоянный IPv4 (Enter — оставить текущий)' "$CURRENT_IP")
    fi
    host_ip "$PS5_IP" "$ROUTER_IP" "$PREFIX" || fail 'Некорректный адрес хоста выбранной подсети.'
    check_ip_conflict
    DNS_PORT=$(free_port 1053)
    HTTP_PORT=$(free_port 8080)
    HTTPS_PORT=$(free_port 8443)
    SITE=$(ask 'Каталог сайта на роутере' /srv/ps5)
    safe_site "$SITE" || fail 'Допускается абсолютный каталог внутри /srv/ или /mnt/, без пробелов и .. .'
    if [ -e "$(path "$SITE")" ] && ! owned_site "$(path "$SITE")"; then fail 'Каталог сайта уже существует и не принадлежит мастеру. Выберите пустой новый путь.'; fi
    validate_source
    check_network
    for record in $(sections dhcp hostrecord) $(sections dhcp domain) $(sections dhcp host); do
        [ "$record" != ps5ow_names ] || continue
        [ "$record" != ps5ow_host ] || continue
        [ "$record" != "$HOST_REUSE" ] || continue
        for alias in $(get "dhcp.$record.name"); do
            alias=$(printf '%s' "$alias" | tr '[:upper:]' '[:lower:]')
            if [ "$alias" = "$NAME" ] || [ "$alias" = "$FQDN" ]; then fail "Имя $alias уже задано в $record. Сначала устраните конфликт."; fi
        done
    done
    # Keep the name read from the selected reservation through all validation helpers.
    if [ -n "$existing_name" ]; then
        NAME=$(get "dhcp.$HOST_REUSE.name" | awk '{print $1}')
        FQDN="$NAME.$local_domain"
    fi
    summary
    if ! yesno 'Сохранить эти параметры? Службы и firewall пока не изменяются'; then msg 'Параметры не сохранены.'; return; fi
    mkdir -p "$BASE"
    printf '%s\n' "$OWNER" > "$BASE/owner"
    [ -f "$(path /etc/config/ps5openwrt)" ] || : > "$(path /etc/config/ps5openwrt)"
    u set ps5openwrt.main=settings
    for pair in "owner=$OWNER" "mac=$MAC" "ip=$PS5_IP" "name=$NAME" "fqdn=$FQDN" "interface=$IFACE" "device=$DEVICE" "zone=$ZONE" "router_ip=$ROUTER_IP" "prefix=$PREFIX" "dns_port=$DNS_PORT" "http_port=$HTTP_PORT" "https_port=$HTTPS_PORT" "site=$SITE" "host_reuse=$HOST_REUSE" 'state=configured' 'mode=uninstalled'; do
        u set "ps5openwrt.main.$pair"
    done
    u commit ps5openwrt
    CONFIGURED=1
    msg 'Параметры сохранены. Следующий этап — подготовка пакетов и файлов.'
}

export_managed() {
    cfg=$1
    names=$(managed_sections "$cfg")
    u -q export "$cfg" 2>/dev/null | awk -v names="$names" '
        BEGIN {split(names,a," ");for(i in a)wanted[a[i]]=1}
        /^config / {n=$3;gsub(/\047/,"",n);keep=(n in wanted)}
        keep {print}
    ' || true
}
enabled_state() { if [ -x "$(path "/etc/init.d/$1")" ] && service "$1" enabled >/dev/null 2>&1; then msg 1; else msg 0; fi; }
keep_remove() {
    keepfile=$(path /etc/sysupgrade.conf)
    [ -f "$keepfile" ] || return 0
    awk '/^# BEGIN PS5-OPENWRT$/{skip=1;next}/^# END PS5-OPENWRT$/{skip=0;next}!skip{print}' "$keepfile" > "$TEMP/keep.clean"
    cat "$TEMP/keep.clean" > "$keepfile"
}
keep_export() {
    keepfile=$(path /etc/sysupgrade.conf)
    [ -f "$keepfile" ] || return 0
    awk '/^# BEGIN PS5-OPENWRT$/{keep=1}keep{print}/^# END PS5-OPENWRT$/{keep=0}' "$keepfile"
}
backup() {
    temp_dir
    mkdir -p "$BACKUPS"
    chmod 700 "$BACKUPS"
    BACKUP=$(mktemp -d "$BACKUPS/$(date +%Y%m%d-%H%M%S)-XXXXXX")
    printf '%s\n' "$OWNER" > "$BACKUP/owner"
    printf '%s; %s; %s; %s\n' "$STATE" "$MODE" "$MAC" "${action:-wizard}" > "$BACKUP/snapshot.info"
    printf '%s\n' "$SITE" > "$BACKUP/site.path"
    sysupgrade -l > "$BACKUP/sysupgrade-files.txt"
    if grep -F "$BACKUPS/" "$BACKUP/sysupgrade-files.txt" >/dev/null; then fail 'Каталог резервных копий включён в sysupgrade.conf. Исключите его, чтобы копии не включали друг друга.'; fi
    sysupgrade -b "$BACKUP/openwrt-config.tar.gz"
    tar -tzf "$BACKUP/openwrt-config.tar.gz" >/dev/null
    for cfg in dhcp firewall uhttpd; do
        export_managed "$cfg" > "$BACKUP/$cfg.sections"
        [ ! -f "$(path "/etc/config/$cfg")" ] || cp -p "$(path "/etc/config/$cfg")" "$BACKUP/$cfg.full"
    done
    cp -p "$(path /etc/config/ps5openwrt)" "$BACKUP/ps5openwrt.conf"
    tar -C "$BASE" -czf "$BACKUP/runtime.tar.gz" .
    tar -tzf "$BACKUP/runtime.tar.gz" >/dev/null
    if [ -x "$(path /etc/init.d/ps5owdns)" ]; then cp -p "$(path /etc/init.d/ps5owdns)" "$BACKUP/ps5owdns"; fi
    enabled_state ps5owdns > "$BACKUP/dns.enabled"
    enabled_state uhttpd > "$BACKUP/uhttpd.enabled"
    keep_export > "$BACKUP/keep.block"
    if [ -d "$(path "$SITE")" ]; then
        owned_site "$(path "$SITE")" || fail 'Неизвестный каталог сайта: отказ от резервирования/перезаписи.'
        tar -C "$(path "$SITE")" -czf "$BACKUP/site.tar.gz" .
        tar -tzf "$BACKUP/site.tar.gz" >/dev/null
    fi
    if [ "$PM" = apk ]; then apk info > "$BACKUP/packages.txt"; else opkg list-installed > "$BACKUP/packages.txt"; fi
    printf '%s\n' complete > "$BACKUP/complete"
    printf '%s\n' "$BACKUP" > "$BASE/last-backup"
    msg "Резервная копия создана: $BACKUP"
    msg 'Скопируйте этот каталог на компьютер через WinSCP. openwrt-config.tar.gz — также штатный архив настроек.'
}
restore_snapshot() {
    restore_dir=$1
    [ -f "$restore_dir/complete" ] || return 1
    [ -f "$restore_dir/owner" ] && [ "$(cat "$restore_dir/owner")" = "$OWNER" ] || return 1
    restore_site=$(cat "$restore_dir/site.path") || return 1
    safe_site "$restore_site" || return 1
    tar -tzf "$restore_dir/runtime.tar.gz" >/dev/null || return 1
    if [ -f "$restore_dir/site.tar.gz" ]; then tar -tzf "$restore_dir/site.tar.gz" >/dev/null || return 1; fi
    temp_dir || return 1
    [ ! -x "$(path /etc/init.d/ps5owdns)" ] || service ps5owdns stop || return 1
    for cfg in dhcp firewall uhttpd; do
        for section in $(managed_sections "$cfg"); do u -q delete "$cfg.$section" 2>/dev/null || true; done
        if [ -s "$restore_dir/$cfg.sections" ]; then u -m import "$cfg" < "$restore_dir/$cfg.sections" || return 1; fi
        if [ -f "$(path "/etc/config/$cfg")" ]; then u commit "$cfg" || return 1; fi
    done
    u -q revert ps5openwrt 2>/dev/null || true
    cp -p "$restore_dir/ps5openwrt.conf" "$(path /etc/config/ps5openwrt)" || return 1
    if [ -d "$BASE" ]; then owned || return 1; rm -rf "$BASE" || return 1; fi
    mkdir -p "$BASE" || return 1
    tar -C "$BASE" -xzf "$restore_dir/runtime.tar.gz" || return 1
    if [ -e "$(path "$restore_site")" ]; then
        owned_site "$(path "$restore_site")" || return 1
        rm -rf "$(path "$restore_site")" || return 1
    fi
    if [ -f "$restore_dir/site.tar.gz" ]; then
        mkdir -p "$(path "$restore_site")" || return 1
        tar -C "$(path "$restore_site")" -xzf "$restore_dir/site.tar.gz" || return 1
    fi
    if [ -f "$restore_dir/ps5owdns" ]; then
        cp -p "$restore_dir/ps5owdns" "$(path /etc/init.d/ps5owdns)" || return 1
        if [ "$(cat "$restore_dir/dns.enabled")" = 1 ]; then service ps5owdns enable && service ps5owdns start || return 1; else service ps5owdns disable || return 1; fi
    elif [ -e "$(path /etc/init.d/ps5owdns)" ]; then
        service ps5owdns disable || return 1
        rm -f "$(path /etc/init.d/ps5owdns)" || return 1
    fi
    keep_remove || return 1
    cat "$restore_dir/keep.block" >> "$(path /etc/sysupgrade.conf)" || return 1
    if [ -x "$(path /etc/init.d/uhttpd)" ]; then
        if [ "$(cat "$restore_dir/uhttpd.enabled")" = 1 ]; then service uhttpd enable || return 1; else service uhttpd disable || return 1; fi
        service uhttpd restart || return 1
    fi
    if [ -n "$(get firewall.ps5ow_block)" ]; then u reorder firewall.ps5ow_block=0 && u commit firewall || return 1; fi
    service dnsmasq restart || return 1
    fw4 check || return 1
    service firewall reload || return 1
}

pkg_installed() {
    if [ "$PM" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" 2>/dev/null | grep -q '^Status:.* installed'; fi
}
package_plan() {
    PACKAGES=''
    for package in uhttpd openssl-util curl bind-dig conntrack; do
        if ! pkg_installed "$package"; then PACKAGES="$PACKAGES $package"; fi
    done
    if [ ! -f "$(path /lib/libustream-ssl.so)" ] && ! pkg_installed libustream-mbedtls20201210; then
        PACKAGES="$PACKAGES libustream-mbedtls20201210"
    fi
}
install_packages() {
    [ -n "$PACKAGES" ] || { msg 'Все необходимые пакеты уже установлены.'; return; }
    # PACKAGES contains only the fixed package identifiers in package_plan.
    # shellcheck disable=SC2086
    set -- $PACKAGES
    if [ "$PM" = apk ]; then apk update; apk add "$@"
    else opkg update; opkg install "$@"; fi
}
space_check() {
    parent=$(dirname "$(path "$SITE")")
    while [ ! -d "$parent" ]; do parent=$(dirname "$parent"); done
    available=$(df -Pk "$parent" | awk 'NR==2{print $4}')
    site_kb=$(du -sk "$SOURCE" | awk '{print $1}')
    minimum=$((site_kb * 3 + 2048))
    [ "$available" -ge "$minimum" ] || fail "Для сайта, временной копии и резервирования нужно минимум $minimum КиБ; доступно $available КиБ."
    msg "Место для сайта: доступно $available КиБ; минимальный запас $minimum КиБ. Размер пакетов дополнительно проверяет менеджер пакетов."
}
write_entry() {
    mkdir -p "$1/cgi-bin"
    cat > "$1/cgi-bin/entry" <<'EOF'
#!/bin/sh
request_path="${REQUEST_URI%%\?*}"
case "$request_path" in
    /document|/document/*|/ps5|/ps5/*)
        printf 'Status: 302 Found\r\nLocation: /index.html\r\nCache-Control: no-store\r\nContent-Length: 0\r\n\r\n'
        ;;
    *)
        printf 'Status: 404 Not Found\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nNot found\n'
        ;;
esac
EOF
    chmod 755 "$1/cgi-bin/entry"
    sh -n "$1/cgi-bin/entry"
}
write_dns() {
    cat > "$BASE/dnsmasq.conf" <<EOF
port=$DNS_PORT
interface=$DEVICE
except-interface=lo
bind-dynamic
user=nobody
no-resolv
no-hosts
cache-size=0
no-dhcp-interface=$DEVICE
address=/manuals.playstation.net/$ROUTER_IP
local=/manuals.playstation.net/
host-record=$NAME,$FQDN,$PS5_IP
local=/#/
EOF
    cat > "$(path /etc/init.d/ps5owdns)" <<'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/sbin/dnsmasq \
        --keep-in-foreground \
        --conf-file=/etc/ps5-openwrt/dnsmasq.conf \
        --pid-file=/var/run/ps5owdns.pid
    procd_set_param file /etc/ps5-openwrt/dnsmasq.conf
    procd_set_param respawn
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod 755 "$(path /etc/init.d/ps5owdns)"
    sh -n "$(path /etc/init.d/ps5owdns)"
    dnsmasq --test --conf-file="$BASE/dnsmasq.conf"
}
certificate() {
    if [ -s "$BASE/server.crt" ] && [ -s "$BASE/server.key" ]; then
        if openssl x509 -inform DER -in "$BASE/server.crt" -noout -checkend 86400 >/dev/null; then return; fi
    fi
    [ "$(date +%Y)" -ge 2024 ] || fail 'На роутере неверная дата. Исправьте время перед созданием сертификата.'
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
        -keyout "$BASE/server.key.pem" -out "$BASE/server.crt.pem" \
        -days 3650 -subj '/CN=manuals.playstation.net' \
        -addext "subjectAltName=DNS:manuals.playstation.net,IP:$ROUTER_IP" \
        -addext 'extendedKeyUsage=serverAuth' 2> "$BASE/certificate.log"
    openssl x509 -in "$BASE/server.crt.pem" -outform DER -out "$BASE/server.crt"
    openssl pkey -in "$BASE/server.key.pem" -outform DER -out "$BASE/server.key"
    chmod 600 "$BASE"/server.*
}
prepare() {
    PREPARED=0
    clean_uci
    load_settings
    check_network
    check_ip_conflict
    validate_source
    space_check
    package_plan
    summary
    msg "Пакеты для установки:${PACKAGES:- отсутствуют}"
    msg 'Будут созданы резервная копия, локальные файлы сайта, DNS и сертификат. Системные пакеты не обновляются целиком.'
    if ! yesno 'Подготовить пакеты и установить файлы сайта?'; then return; fi
    clean_uci
    backup
    TRANSACTION=1
    install_packages
    for program in uhttpd openssl curl dig conntrack dnsmasq; do command -v "$program" >/dev/null 2>&1 || fail "После установки отсутствует $program."; done
    [ -f "$(path /lib/libustream-ssl.so)" ] || fail 'Отсутствует SSL-библиотека uhttpd.'
    parent=$(dirname "$(path "$SITE")")
    mkdir -p "$parent"
    STAGE="$(path "$SITE").ps5ow-new.$$"
    [ ! -e "$STAGE" ] || fail 'Временный каталог сайта уже существует.'
    mkdir "$STAGE"
    cp -R "$SOURCE/." "$STAGE/"
    find "$STAGE" -type d -exec chmod 755 {} \;
    find "$STAGE" -type f -exec chmod 644 {} \;
    printf '%s\n' "$OWNER" > "$STAGE/.ps5-openwrt-site"
    write_entry "$STAGE"
    chmod 755 "$STAGE/cgi-bin/payloads"
    if [ ! -s "$BASE/payloads.token" ]; then
        openssl rand -hex 32 > "$BASE/payloads.token"
        chmod 600 "$BASE/payloads.token"
    fi
    certificate
    write_dns
    : > "$BASE/httpd.conf"
    if [ -e "$(path "$SITE")" ]; then
        owned_site "$(path "$SITE")" || fail 'Каталог сайта потерял маркер владельца.'
        OLD_SITE="$(path "$SITE").ps5ow-old.$$"
        mv "$(path "$SITE")" "$OLD_SITE"
    fi
    mv "$STAGE" "$(path "$SITE")"
    STAGE=''
    if [ "$STATE" != installed ]; then u set ps5openwrt.main.state=prepared; fi
    u commit ps5openwrt
    if [ "$STATE" = installed ]; then service ps5owdns restart; service uhttpd restart; router_checks; fi
    TRANSACTION=0
    [ -z "$OLD_SITE" ] || { rm -rf "$OLD_SITE"; OLD_SITE=''; }
    PREPARED=1
    msg 'Подготовка завершена. Для первой установки выберите «Применить настройку».'
}

write_uci() {
    if [ -z "$HOST_REUSE" ]; then
        u set dhcp.ps5ow_host=host
        u set "dhcp.ps5ow_host.name=$NAME"
        u set "dhcp.ps5ow_host.mac=$MAC"
        u set "dhcp.ps5ow_host.ip=$PS5_IP"
        u set dhcp.ps5ow_host.dns=0
    else
        [ "$(get "dhcp.$HOST_REUSE.ip")" = "$PS5_IP" ] || fail 'Изменилось повторно используемое резервирование.'
    fi
    u -q delete dhcp.ps5ow_names 2>/dev/null || true
    u set dhcp.ps5ow_names=hostrecord
    u set "dhcp.ps5ow_names.name=$NAME $FQDN"
    u set "dhcp.ps5ow_names.ip=$PS5_IP"

    u -q delete uhttpd.ps5ow 2>/dev/null || true
    u set uhttpd.ps5ow=uhttpd
    u set uhttpd.ps5ow.enabled=1
    u add_list "uhttpd.ps5ow.listen_http=$ROUTER_IP:$HTTP_PORT"
    u add_list "uhttpd.ps5ow.listen_https=$ROUTER_IP:$HTTPS_PORT"
    u set "uhttpd.ps5ow.home=$SITE"
    u set uhttpd.ps5ow.config=/etc/ps5-openwrt/httpd.conf
    u set uhttpd.ps5ow.cert=/etc/ps5-openwrt/server.crt
    u set uhttpd.ps5ow.key=/etc/ps5-openwrt/server.key
    u add_list uhttpd.ps5ow.index_page=index.html
    u set uhttpd.ps5ow.cgi_prefix=/cgi-bin
    u set uhttpd.ps5ow.error_page=/cgi-bin/entry
    u set uhttpd.ps5ow.no_dirlists=1
    u set uhttpd.ps5ow.no_symlinks=1
    u set uhttpd.ps5ow.rfc1918_filter=1
    u set uhttpd.ps5ow.redirect_https=0
    u set uhttpd.ps5ow.max_requests=16
    u set uhttpd.ps5ow.script_timeout=75
    u set uhttpd.ps5ow.network_timeout=90

    for section in ps5ow_block ps5ow_dns ps5ow_http ps5ow_https; do u -q delete "firewall.$section" 2>/dev/null || true; done
    u set firewall.ps5ow_block=rule
    u set firewall.ps5ow_block.name=PS5OW-Block-Routing
    u set 'firewall.ps5ow_block.src=*'
    u set 'firewall.ps5ow_block.dest=*'
    u add_list "firewall.ps5ow_block.src_mac=$MAC"
    u set firewall.ps5ow_block.proto=all
    u set firewall.ps5ow_block.family=any
    u set firewall.ps5ow_block.target=REJECT
    u set firewall.ps5ow_block.enabled=1

    u set firewall.ps5ow_dns=redirect
    u set firewall.ps5ow_dns.name=PS5OW-Local-DNS
    u set "firewall.ps5ow_dns.src=$ZONE"
    u add_list "firewall.ps5ow_dns.src_mac=$MAC"
    u set 'firewall.ps5ow_dns.proto=tcp udp'
    u set firewall.ps5ow_dns.src_dport=53
    u set "firewall.ps5ow_dns.dest_port=$DNS_PORT"
    u set firewall.ps5ow_dns.family=any
    u set firewall.ps5ow_dns.target=DNAT
    u set firewall.ps5ow_dns.reflection=0
    u set firewall.ps5ow_dns.enabled=1

    for scheme in http https; do
        if [ "$scheme" = http ]; then public_port=80; local_port=$HTTP_PORT; rule_name=PS5OW-Local-HTTP
        else public_port=443; local_port=$HTTPS_PORT; rule_name=PS5OW-Local-HTTPS; fi
        section="ps5ow_$scheme"
        u set "firewall.$section=redirect"
        u set "firewall.$section.name=$rule_name"
        u set "firewall.$section.src=$ZONE"
        u add_list "firewall.$section.src_mac=$MAC"
        u set "firewall.$section.proto=tcp"
        u set "firewall.$section.src_dip=$ROUTER_IP"
        u set "firewall.$section.src_dport=$public_port"
        u set "firewall.$section.dest_ip=$ROUTER_IP"
        u set "firewall.$section.dest_port=$local_port"
        u set "firewall.$section.family=ipv4"
        u set "firewall.$section.target=DNAT"
        u set "firewall.$section.reflection=0"
        u set "firewall.$section.enabled=1"
    done
    for section in ps5ow_http ps5ow_https ps5ow_dns ps5ow_block; do u reorder "firewall.$section=0"; done
    for cfg in dhcp uhttpd firewall; do u commit "$cfg"; done
}
candidate_check() {
    fw4 check
    fw4 print > "$TEMP/firewall.nft"
    for rule_name in PS5OW-Block-Routing PS5OW-Local-DNS PS5OW-Local-HTTP PS5OW-Local-HTTPS; do
        grep -F "$rule_name" "$TEMP/firewall.nft" | grep -Fi "$MAC" >/dev/null || fail "Firewall пропустил правило $rule_name."
    done
    block_line=$(grep -F 'PS5OW-Block-Routing' "$TEMP/firewall.nft")
    dns_line=$(grep -F 'PS5OW-Local-DNS' "$TEMP/firewall.nft")
    if printf '%s\n%s\n' "$block_line" "$dns_line" | grep -Eq 'nfproto ipv[46]|ip6? (saddr|daddr)'; then
        fail 'Блокировка или DNS ограничены одним семейством IP.'
    fi
}
keep_write() {
    keep_remove
    cat >> "$(path /etc/sysupgrade.conf)" <<EOF
# BEGIN PS5-OPENWRT
/etc/config/ps5openwrt
/etc/ps5-openwrt/
/etc/init.d/ps5owdns
/etc/rc.d/S95ps5owdns
/etc/rc.d/K10ps5owdns
$SITE/
# END PS5-OPENWRT
EOF
}
clear_connections() {
    temp_dir
    printf '%s\n' "$PS5_IP" > "$TEMP/ipv4"
    ip -4 neigh show dev "$DEVICE" | awk -v m="$MAC" '{for(i=1;i<=NF;i++)if($i=="lladdr" && tolower($(i+1))==m)print $1}' >> "$TEMP/ipv4"
    ip -6 neigh show dev "$DEVICE" | awk -v m="$MAC" '{for(i=1;i<=NF;i++)if($i=="lladdr" && tolower($(i+1))==m)print $1}' > "$TEMP/ipv6"
    for family in ipv4 ipv6; do
        sort -u "$TEMP/$family" | while IFS= read -r addr; do
            [ -n "$addr" ] || continue
            # Exit 1 means no matching entries. Only PS5 addresses are deleted.
            for direction in -s -d; do
                if conntrack -D -f "$family" "$direction" "$addr" > "$TEMP/conntrack.log" 2>&1; then :
                else
                    conntrack_result=$?
                    [ "$conntrack_result" = 1 ] || { cat "$TEMP/conntrack.log" >&2; fail 'Не удалось очистить соединения PS5.'; }
                fi
            done
        done
    done
}
router_checks() {
    dnsmasq --test --conf-file="$BASE/dnsmasq.conf"
    answer=$(dig "@$ROUTER_IP" -p "$DNS_PORT" manuals.playstation.net A +short +time=2 +tries=1)
    [ "$answer" = "$ROUTER_IP" ] || fail "Выделенный DNS возвращает неверный A: $answer"
    answer=$(dig "@$ROUTER_IP" -p "$DNS_PORT" manuals.playstation.net AAAA +noall +comments +answer +time=2 +tries=1)
    printf '%s' "$answer" | grep -Eq 'status: (NOERROR|NXDOMAIN)' || fail 'Не получен корректный ответ AAAA.'
    if printf '%s' "$answer" | grep -Eq '[[:space:]]AAAA[[:space:]]'; then fail 'Выделенный DNS возвращает внешний IPv6 для руководства.'; fi
    answer=$(dig "@$ROUTER_IP" "$FQDN" A +short +time=2 +tries=1)
    [ "$answer" = "$PS5_IP" ] || fail "Основной DNS не возвращает $FQDN -> $PS5_IP."
    for request in /index.html /src/site.js /document/ru/ps5/index.html; do
        code=$(curl -k -sS -I --connect-timeout 5 --max-time 15 \
            --resolve "manuals.playstation.net:$HTTPS_PORT:$ROUTER_IP" \
            -D "$TEMP/headers" -o /dev/null -w '%{http_code}' \
            "https://manuals.playstation.net:$HTTPS_PORT$request")
        if [ "$request" = /document/ru/ps5/index.html ]; then
            [ "$code" = 302 ] || fail "Руководство возвращает HTTP $code."
            tr -d '\r' < "$TEMP/headers" | grep -Eiq '^Location: /index\.html$' || fail 'Неверный Location для руководства.'
        else
            [ "$code" = 200 ] || fail "$request возвращает HTTP $code."
        fi
        if [ "$request" = /src/site.js ]; then
            grep -Eiq '^Content-Type:.*(application|text)/(x-)?javascript' "$TEMP/headers" || fail 'Неверный MIME для JavaScript.'
        fi
    done
    if [ "$MODE" = offline ]; then
        nft list chain inet fw4 forward > "$TEMP/live-forward"
        grep -F 'PS5OW-Block-Routing' "$TEMP/live-forward" | grep -Fi "$MAC" >/dev/null || fail 'Блокирующее правило отсутствует в работающем firewall.'
        nft list chain inet fw4 "dstnat_$ZONE" > "$TEMP/live-dnat"
        for rule_name in PS5OW-Local-DNS PS5OW-Local-HTTP PS5OW-Local-HTTPS; do
            grep -F "$rule_name" "$TEMP/live-dnat" | grep -Fi "$MAC" >/dev/null || fail "Нет работающего перенаправления $rule_name."
        done
    fi
    msg 'Проверки на роутере пройдены: DNS, локальное имя, HTTPS, путь руководства и наличие правил.'
    msg 'Фактическая блокировка внешнего трафика и запуск Relapse проверяются с консоли/тестового устройства; скрипт не объявляет их проверенными.'
}
apply_setup() {
    clean_uci
    load_settings
    case "$STATE" in prepared|installed) ;; *) fail 'Сначала подготовьте пакеты и файлы.' ;; esac
    check_network
    check_ip_conflict
    owned_site "$(path "$SITE")" || fail 'Нет подготовленного сайта с маркером владельца.'
    for program in openssl curl dig conntrack dnsmasq; do command -v "$program" >/dev/null 2>&1 || fail "Не найден $program."; done
    summary
    msg 'Будут настроены адрес/имена консоли, локальный сервер и блокировка маршрутизации PS5 по MAC для IPv4 и IPv6.'
    msg 'Перед применением отключите PS5 от сети. Wi-Fi и IP роутера не меняются.'
    if ! yesno 'Применить эту настройку и включить офлайн-режим?'; then return; fi
    clean_uci
    backup
    TRANSACTION=1
    write_uci
    candidate_check
    service firewall reload
    service dnsmasq restart
    service ps5owdns enable
    service ps5owdns restart
    service uhttpd enable
    service uhttpd restart
    MODE=offline
    clear_connections
    router_checks
    keep_write
    u set ps5openwrt.main.state=installed
    u set ps5openwrt.main.mode=offline
    u commit ps5openwrt
    TRANSACTION=0
    msg "Установка завершена. PS5: IP автоматически, DNS $ROUTER_IP, прежний Wi-Fi. Затем откройте руководство пользователя."
    msg "ELF-загрузчик после успешного запуска: $FQDN:9021."
    msg "Код управления нагрузками с компьютера: $(cat "$BASE/payloads.token")"
    msg 'Самоподписанный сертификат требует возможности продолжить в браузере PS5; конкретная прошивка может этого не разрешать.'
    msg 'Все операции выполнены успешно.'
    msg 'После успешного взлома и отправки нагрузок можно вернуть обычный интернет PS5.'
    if yesno 'Взлом уже завершён и нагрузки отправлены? Включить online сейчас?'; then
        for section in ps5ow_block ps5ow_dns ps5ow_http ps5ow_https; do
            u set "firewall.$section.enabled=0"
        done
        u commit firewall
        service firewall reload
        u set ps5openwrt.main.mode=online
        u commit ps5openwrt
        msg 'Обычный интернет PS5 включён. Переподключите консоль к Wi-Fi.'
    fi
    printf '%s' 'Нажмите Enter для завершения: '
    IFS= read -r _ || true
}
switch_mode() {
    target=$1
    clean_uci
    load_settings
    [ "$STATE" = installed ] || fail 'Настройка ещё не установлена.'
    if [ "$target" = offline ]; then check_network; check_ip_conflict; fi
    summary
    if [ "$target" = online ]; then text='Вернуть обычный интернет PS5 (локальное имя и адрес сохранятся)?'; enabled=0
    else
        msg 'Перед переключением отключите PS5 от Wi-Fi. Для гарантированного удаления старых/ускоренных соединений можно перезагрузить роутер после переключения.'
        text='Включить офлайн-режим PS5 с перенаправлениями и блокировкой?'; enabled=1
    fi
    if ! yesno "$text"; then return; fi
    backup
    TRANSACTION=1
    for section in ps5ow_block ps5ow_dns ps5ow_http ps5ow_https; do u set "firewall.$section.enabled=$enabled"; done
    u commit firewall
    if [ "$target" = offline ]; then candidate_check; else fw4 check; fi
    service firewall reload
    MODE=$target
    if [ "$target" = offline ]; then clear_connections; router_checks; fi
    u set "ps5openwrt.main.mode=$target"
    u commit ps5openwrt
    TRANSACTION=0
    msg "Режим: $target. Переподключите PS5 к Wi-Fi для очистки её DNS-кэша."
}
check_setup() {
    load_settings
    temp_dir
    [ "$STATE" = installed ] || fail 'Проверка служб доступна после применения.'
    router_checks
}
inspect_setup() {
    if owned; then
        status_setup
        [ "$(get ps5openwrt.main.state)" = installed ] && router_checks
    else
        diagnose
    fi
}
update_project() {
    need_root
    temp_dir
    msg 'Загрузка актуальной версии проекта...'
    project_url='https://codeload.github.com/ant-m13/ps5-relapse-openwrt/tar.gz/main'
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 120 --max-filesize 8388608 --output "$TEMP/project.tar.gz" "$project_url"
    else
        wget -T 30 -O "$TEMP/project.tar.gz" "$project_url"
    fi
    validate_archive "$TEMP/project.tar.gz"
    mkdir "$TEMP/extracted"
    tar -xzf "$TEMP/project.tar.gz" -C "$TEMP/extracted"
    project_root="$TEMP/extracted/$ARCHIVE_ROOT"
    [ -s "$project_root/install.sh" ] && [ -d "$project_root/www" ] || fail 'В архиве нет полного проекта.'
    SOURCE="$project_root/www"
    validate_source
    sh -n "$project_root/install.sh"
    cp -R "$project_root/." "$REPO_DIR/"
    msg 'Проект обновлён. Для обновления сайта выберите пункт «Подготовить сайт».'
}
status_setup() {
    if ! owned; then msg 'Настройка PS5 ещё не создана.'; return; fi
    load_settings
    summary
    printf 'Состояние: %s; режим: %s\n' "$STATE" "$MODE"
    msg "Код управления нагрузками с компьютера: $(cat "$BASE/payloads.token" 2>/dev/null || true)"
    printf 'Последняя копия: %s\n'  "$(cat "$BASE/last-backup" 2>/dev/null || true)"
    netstat -lntup 2>/dev/null | awk -v d="$DNS_PORT" -v h="$HTTP_PORT" -v s="$HTTPS_PORT" '$4~(":(" d "|" h "|" s ")$"){print}'
}
diagnose() {
    msg "PS5 OpenWrt"
    ubus call system board
    msg "Менеджер пакетов: $PM"
    msg 'Несохранённые изменения UCI:'
    u changes
    interfaces_table
    msg 'Активные интерфейсы с IPv4 и зоной firewall:'
    cat "$TEMP/interfaces"
    devices_table
    msg 'Устройства (MAC | IP | имя | источник; аренда/сосед могут быть устаревшими):'
    cat "$TEMP/devices"
    package_plan
    msg "Недостающие пакеты:${PACKAGES:- отсутствуют}"
    df -h "$(path /)"
    msg 'Диагностика не изменяла настройки.'
}
restore_menu() {
    clean_uci
    load_settings
    temp_dir
    : > "$TEMP/backups"
    for dir in "$BACKUPS"/*; do
        [ -f "$dir/complete" ] && [ -f "$dir/owner" ] || continue
        [ "$(cat "$dir/owner")" = "$OWNER" ] || continue
        msg "$dir" >> "$TEMP/backups"
    done
    [ -s "$TEMP/backups" ] || fail 'Нет резервных копий этого мастера.'
    number=0
    while IFS= read -r dir; do
        number=$((number+1))
        printf '  %d) %s (%s)\n' "$number" "$dir" "$(cat "$dir/snapshot.info" 2>/dev/null || true)"
    done < "$TEMP/backups"
    choice=$(ask 'Номер копии для восстановления' '')
    case "$choice" in ''|*[!0-9]*) fail 'Некорректный номер.' ;; esac
    restore_dir=$(sed -n "${choice}p" "$TEMP/backups")
    [ -n "$restore_dir" ] || fail 'Нет такой копии.'
    [ "$(cat "$restore_dir/site.path")" = "$SITE" ] || fail 'Копия использует другой каталог сайта. Сначала выберите такой же путь в настройке, чтобы не оставить старый сайт.'
    msg 'Будут восстановлены только разделы/файлы мастера. Остальные настройки DHCP, firewall и uhttpd сохранятся. Установленные пакеты не удаляются.'
    if ! yesno "Восстановить $restore_dir?"; then return; fi
    backup
    TRANSACTION=1
    restore_snapshot "$restore_dir"
    TRANSACTION=0
    msg 'Сохранённая настройка восстановлена.'
}
uninstall() {
    clean_uci
    load_settings
    msg 'Будут удалены только разделы и службы этого мастера. Копии и установленные пакеты сохранятся; существующая чужая DHCP-аренда сохраняется.'
    if ! yesno 'Удалить настройку PS5 и вернуть обычный доступ через роутер?'; then return; fi
    backup
    TRANSACTION=1
    if [ -x "$(path /etc/init.d/ps5owdns)" ]; then service ps5owdns stop; service ps5owdns disable; fi
    for cfg in dhcp firewall uhttpd; do
        for section in $(managed_sections "$cfg"); do u -q delete "$cfg.$section" 2>/dev/null || true; done
        if [ -f "$(path "/etc/config/$cfg")" ]; then u commit "$cfg"; fi
    done
    fw4 check
    service firewall reload
    service dnsmasq restart
    if [ -x "$(path /etc/init.d/uhttpd)" ]; then service uhttpd restart; fi
    keep_remove
    if [ -e "$(path "$SITE")" ]; then
        owned_site "$(path "$SITE")" || fail 'Каталог сайта потерял маркер: его удаление запрещено.'
        rm -rf "$(path "$SITE")"
    fi
    rm -f "$(path /etc/init.d/ps5owdns)"
    u set ps5openwrt.main.state=removed
    u set ps5openwrt.main.mode=uninstalled
    u commit ps5openwrt
    rm -rf "$BASE"
    mkdir -p "$BASE"
    printf '%s\n' "$OWNER" > "$BASE/owner"
    printf '%s\n' "$BACKUP" > "$BASE/last-backup"
    TRANSACTION=0
    msg "Настройка удалена. Копии сохранены: $BACKUPS"
}
on_exit() {
    result=$1
    trap - 0 INT TERM
    set +e
    if [ "$result" -ne 0 ] && [ "$TRANSACTION" = 1 ] && [ -n "$BACKUP" ]; then
        msg 'Операция прервана. Восстанавливаю предыдущую настройку мастера из копии.' >&2
        if restore_snapshot "$BACKUP"; then msg 'Предыдущая настройка восстановлена.' >&2
        else
            printf 'Автоматическое восстановление не завершено. Копия: %s\n' "$BACKUP" >&2
            OLD_SITE=''
        fi
    fi
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    [ -z "$OLD_SITE" ] || rm -rf "$OLD_SITE"
    [ -z "$TEMP" ] || rm -rf "$TEMP"
    if [ "$LOCKED" = 1 ]; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; fi
    exit "$result"
}

require_space() {
    space_dir=$1
    while [ ! -d "$space_dir" ]; do space_dir=$(dirname "$space_dir"); done
    space_free=$(df -Pk "$space_dir" | awk 'NR==2 {print $4}')
    case "$space_free" in ''|*[!0-9]*) fail 'Не удалось определить свободное место.' ;; esac
    [ "$space_free" -ge "$2" ] || fail "Недостаточно места в $space_dir: нужно $2 КиБ, доступно $space_free."
}
# Reject links, devices, traversal, duplicate entries and ambiguous names BEFORE extraction.
# Accept one archive root, containing only portable paths. No strip-components is needed.
validate_archive() {
    archive_file=$1
    [ -s "$archive_file" ] || fail 'Архив пуст.'
    [ "$(wc -c < "$archive_file")" -le 8388608 ] || fail 'Архив превышает 8 МиБ.'
    archive_bytes=$(gzip -dc "$archive_file" 2>/dev/null | head -c 33554433 | wc -c)
    [ "$archive_bytes" -le 33554432 ] || fail 'Распакованный архив превышает 32 МиБ.'
    gzip -t "$archive_file" || fail 'Повреждён gzip-архив.'
    require_space "$TEMP" "$((archive_bytes / 1024 + 2048))"
    tar -tzf "$archive_file" > "$TEMP/archive.names" || fail 'Повреждён tar-архив.'
    tar -tvzf "$archive_file" > "$TEMP/archive.types" || fail 'Не удалось проверить типы файлов.'
    awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END {exit bad}' "$TEMP/archive.types" ||
        fail 'Архив содержит ссылки или специальные файлы.'
    awk '
        BEGIN {bad=0}
        {
            name=$0
            if (name !~ /^[A-Za-z0-9_.\/-]+$/ || name ~ /^\// || name ~ /\/\//) bad=1
            sub(/\/$/, "", name)
            n=split(name,a,"/")
            for(i=1;i<=n;i++) if(a[i]=="" || a[i]=="." || a[i]=="..") bad=1
            if (NR==1) root=a[1]
            if(a[1]!=root || seen[name]++) bad=1
        }
        END {if(NR==0 || NR>4096) bad=1; exit bad}
    ' "$TEMP/archive.names" || fail 'Архив содержит опасные, повторяющиеся пути или несколько корней.'
    ARCHIVE_ROOT=$(sed -n '1s,/.*,,p' "$TEMP/archive.names")
    [ -n "$ARCHIVE_ROOT" ] || fail 'Нет корня архива.'
}

BOOT_LOCK=''
BOOT_LOCKED=0
bootstrap_cleanup() {
    [ -z "$TEMP" ] || rm -rf "$TEMP"
    if [ "$BOOT_LOCKED" = 1 ]; then rm -f "$BOOT_LOCK/pid"; rmdir "$BOOT_LOCK" 2>/dev/null || true; fi
}
bootstrap() {
    [ "$(id -u)" = 0 ] || fail 'Запустите от root на OpenWrt.'
    for program in uci ubus jsonfilter; do command -v "$program" >/dev/null 2>&1 || fail "Нужен OpenWrt: нет $program."; done
    target_dir=${PS5OW_INSTALL_DIR:-/root/ps5-relapse-openwrt}
    case "$target_dir" in /root/*) ;; *) fail 'Каталог установки должен находиться внутри /root/.' ;; esac
    case "$target_dir" in *[!A-Za-z0-9_./-]*|*/../*|*/..|*/./*|*/.|*//*) fail 'Недопустимый каталог установки.' ;; esac
    [ "$target_dir" != /root/ ] && [ ! -L "$target_dir" ] || fail 'Укажите отдельный обычный каталог проекта.'
    if [ -e "$target_dir" ] && [ -f "$target_dir/install.sh" ] && [ -d "$target_dir/www" ]; then
        exec sh "$target_dir/install.sh" "$@"
    fi
    mkdir -p "$(dirname "$target_dir")"
    BOOT_LOCK="$target_dir.install-lock"
    if ! mkdir "$BOOT_LOCK" 2>/dev/null; then
        boot_pid=$(cat "$BOOT_LOCK/pid" 2>/dev/null || true)
        case "$boot_pid" in ''|*[!0-9]*) fail "Неизвестная блокировка: $BOOT_LOCK" ;; esac
        if kill -0 "$boot_pid" 2>/dev/null; then fail 'Установщик уже работает.'; fi
        rm -f "$BOOT_LOCK/pid"
        rmdir "$BOOT_LOCK"
        mkdir "$BOOT_LOCK"
    fi
    BOOT_LOCKED=1
    printf '%s\n' "$$" > "$BOOT_LOCK/pid"
    TEMP=$(mktemp -d "$(dirname "$target_dir")/.ps5-install.XXXXXX")
    trap bootstrap_cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    require_space "$TEMP" 2048
    msg 'Загрузка файлов проекта...'
    project_url='https://codeload.github.com/ant-m13/ps5-relapse-openwrt/tar.gz/main'
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 120 --max-filesize 8388608 \
            --output "$TEMP/project.tar.gz" "$project_url"
    else
        wget -T 30 -O "$TEMP/project.tar.gz" "$project_url"
    fi
    validate_archive "$TEMP/project.tar.gz"
    mkdir "$TEMP/extracted"
    tar -xzf "$TEMP/project.tar.gz" -C "$TEMP/extracted"
    project_root="$TEMP/extracted/$ARCHIVE_ROOT"
    [ -s "$project_root/install.sh" ] || fail 'В архиве нет install.sh.'
    SOURCE="$project_root/www"
    validate_source
    sh -n "$project_root/install.sh"
    if [ -e "$target_dir" ]; then
        [ -d "$target_dir" ] || fail 'Каталог установки занят не каталогом.'
        cp -R "$project_root/." "$target_dir/"
    else
        mv "$project_root" "$target_dir"
    fi
    bootstrap_cleanup
    TEMP=''
    BOOT_LOCKED=0
    trap - 0 INT TERM
    exec sh "$target_dir/install.sh" "$@"
}
help_text() {
    cat <<'EOF'
PS5 OpenWrt
  sh install.sh             последовательная установка с выбором PS5
  sh install.sh menu        меню
  sh install.sh update      обновление проекта из GitHub
  sh install.sh diagnose    диагностика без изменения настроек
  sh install.sh configure   выбор консоли и параметров
  sh install.sh prepare     установить недостающие пакеты и обновить сайт
  sh install.sh apply       применение настройки
  sh install.sh status      состояние
  sh install.sh check       проверка служб
  sh install.sh online      обычный интернет PS5
  sh install.sh offline     локальный режим PS5
  sh install.sh restore     восстановление настройки из копии
  sh install.sh uninstall   удаление настройки
EOF
}
wizard() {
    while :; do
        printf '%sPS5 OpenWrt%s\n' "$C_TITLE" "$C_RESET"
        cat <<'EOF'
  1) Установить сервер / применить настройку
  2) Обновить проект из GitHub
  3) Установить недостающие пакеты и обновить сайт
  4) Состояние и проверка служб
  5) Режим online — обычный интернет PS5
  6) Режим offline — локальный запуск Relapse
  7) Восстановить настройку
  8) Удалить настройку
  0) Выход
EOF
        choice=$(ask 'Пункт меню' 0)
        case "$choice" in
            0) return ;;
            1) action=install ;; 2) action=update ;; 3) action=prepare ;; 4) action=inspect ;;
            5) action=online ;; 6) action=offline ;; 7) action=restore ;; 8) action=uninstall ;;
            *) msg 'Нет такого пункта.'; continue ;;
        esac
        set +e
        sh "$SELF" "$action"
        result=$?
        set -e
        [ "$result" = 0 ] || msg "Операция завершилась ошибкой ($result)."
    done
}
install_setup() {
    if owned; then
        load_settings
        if [ "$STATE" = installed ]; then
            status_setup
            msg 'Установка уже выполнена. Меню: sh install.sh menu'
            return
        fi
    fi
    if [ "${STATE:-}" != prepared ]; then
        configure
        [ "$CONFIGURED" = 1 ] || { msg 'Установка отменена.'; return; }
        prepare
        [ "$PREPARED" = 1 ] || { msg 'Подготовка отменена.'; return; }
    fi
    apply_setup
}
main() {
    action=${1:-install}
    case "$action" in -h|--help|help) help_text; return ;; esac
    if [ ! -d "$REPO_DIR/www" ]; then bootstrap "$action"; return; fi
    need_root
    trap 'on_exit $?' 0
    trap 'exit 130' INT
    trap 'exit 143' TERM
    temp_dir
    case "$action" in
        menu) wizard ;; diagnose) diagnose ;; status) status_setup ;; check) check_setup ;; inspect) inspect_setup ;; update) acquire_lock; update_project ;;
        install|configure|prepare|apply|online|offline|restore|uninstall)
            acquire_lock
            case "$action" in
                install) install_setup ;; configure) configure ;; prepare) prepare ;; apply) apply_setup ;;
                online|offline) switch_mode "$action" ;; restore) restore_menu ;; uninstall) uninstall ;;
            esac ;;
        *) fail 'Неизвестная команда. Используйте --help.' ;;
    esac
}
if [ "${PS5OW_LIBRARY_ONLY:-0}" != 1 ]; then main "$@"; fi
