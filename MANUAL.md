# Ручная установка PS5 Relapse на OpenWrt

Этот файл описывает действия, которые выполняет `install.sh`, без использования мастера. Команды выполняются в SSH от `root`. Значения IP, MAC, интерфейса и зоны нужно заменить на свои.

## 1. Проверка сети

Роутер должен быть шлюзом PS5. Узнайте интерфейс, мост, IPv4 и firewall-зону:

```sh
ubus call network.interface dump
ubus call network.interface.lan status
uci show firewall | grep -E 'config zone|\.name=|\.network=|\.input='
```

Запишите:

- MAC PS5, например `02:00:00:00:00:01`;
- закреплённый IP PS5, например `192.168.1.105`;
- IP роутера, например `192.168.1.1`;
- интерфейс `lan` и мост, например `br-lan`;
- firewall-зону, например `lan`.

Если для PS5 уже есть DHCP-резервирование, используйте его IP и имя, не создавая вторую запись.

## 2. Установка пакетов

Установите недостающие компоненты:

```sh
opkg update
opkg install uhttpd openssl-util curl bind-dig conntrack libustream-mbedtls20201210
```

На системах с `apk` используйте `apk update` и `apk add` с теми же пакетами.

## 3. Копирование сайта

Создайте каталог сайта и скопируйте содержимое `www` проекта:

```sh
mkdir -p /srv/ps5
cp -R ./www/. /srv/ps5/
chmod 755 /srv/ps5 /srv/ps5/cgi-bin
chmod 755 /srv/ps5/cgi-bin/payloads
```

Сайт должен содержать `index.html`, основной payload, ELF loader и `payloads/optional/`.

## 4. Токен управления нагрузками

Создайте токен:

```sh
mkdir -p /etc/ps5-openwrt
openssl rand -hex 32 > /etc/ps5-openwrt/payloads.token
chmod 600 /etc/ps5-openwrt/payloads.token
```

При необходимости можно задать собственный код длиной не менее 16 символов:

```sh
printf '%s\n' 'PS5-relapse-2026' > /etc/ps5-openwrt/payloads.token
chmod 600 /etc/ps5-openwrt/payloads.token
```

## 5. Локальный DNS

Создайте отдельную конфигурацию dnsmasq, которая слушает порт `1053` на интерфейсе PS5:

```sh
cat > /etc/ps5-openwrt/dnsmasq.conf <<'EOF'
port=1053
interface=br-lan
except-interface=lo
bind-dynamic
user=nobody
no-resolv
no-hosts
cache-size=0
no-dhcp-interface=br-lan
address=/manuals.playstation.net/192.168.1.1
local=/manuals.playstation.net/
host-record=ps5pro,ps5pro.lan,192.168.1.105
local=/#/
EOF
```

Для запуска этой конфигурации создайте службу `/etc/init.d/ps5owdns`, включите её и запустите после проверки `dnsmasq --test --conf-file=/etc/ps5-openwrt/dnsmasq.conf`.

## 6. HTTPS и uhttpd

Создайте сертификат для `manuals.playstation.net` и настройте экземпляр `uhttpd` на адресе роутера. Используйте отдельные порты, например HTTP `8080` и HTTPS `8443`, каталог `/srv/ps5`, CGI-путь `/cgi-bin` и сертификат с ключом из `/etc/ps5-openwrt/`.

После настройки проверьте:

```sh
uhttpd -t
curl -k -I https://192.168.1.1:8443/
```

## 7. Правила firewall

Создайте правила только для MAC PS5:

- блокировка маршрутизации PS5 для IPv4 и IPv6;
- перенаправление DNS с порта `53` на локальный DNS `1053`;
- перенаправление HTTP `80` на локальный `8080`;
- перенаправление HTTPS `443` на локальный `8443`.

Проверьте конфигурацию и примените её:

```sh
fw4 check
/etc/init.d/firewall reload
```

## 8. Запуск Relapse

Включите локальный режим, подключите PS5 к Wi-Fi роутера, оставьте автоматический IP и откройте «Руководство пользователя». Запустите Relapse и дождитесь ELF loader. Нагрузки можно загрузить через раздел «Дополнительные нагрузки» или скопировать в:

```text
/srv/ps5/payloads/optional/
```

Список автозапуска хранится в `manifest.json`, например:

```json
["pldmgr.elf"]
```

## 9. Возврат обычного интернета

После отправки нагрузок отключите созданные firewall-правила, перезагрузите firewall и переподключите PS5 к Wi-Fi. Это соответствует команде:

```sh
sh install.sh online
```

Запущенные нагрузки от переключения режима не отменяются.

Ручная настройка не создаёт резервные копии автоматически и не выполняет защитные проверки установщика. Перед изменением UCI сохраните копии `/etc/config/dhcp`, `/etc/config/firewall`, `/etc/config/uhttpd` и каталога `/srv/ps5`.
