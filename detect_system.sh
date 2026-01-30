#!/bin/sh

# Скрипт для определения системы и подсистемы
# Основан на логике из install_easy.sh и common/installer.sh

# Режимы вывода:
# - по умолчанию: человекочитаемый (текущий формат)
# - --machine: компактный key=value вывод для парсинга установщиком/скриптами

# Вспомогательные функции
which()
{
	# on some systems 'which' command is considered deprecated and not installed by default
	OLD_IFS="$IFS"
	IFS=:
	for p in $PATH; do
	    [ -x "$p/$1" ] && {
		IFS="$OLD_IFS"
		echo "$p/$1"
		return 0
	    }
	done
	IFS="$OLD_IFS"
	return 1
}

exists()
{
	which "$1" >/dev/null 2>/dev/null
}

whichq()
{
	which $1 2>/dev/null
}

# Проверка наличия Entware
check_entware()
{
	ENTWARE=
	# Entware устанавливается в /opt
	# Основные признаки:
	# 1. opkg находится в /opt/bin или /opt/sbin
	# 2. Наличие /opt/etc/opkg.conf
	# 3. Наличие структуры /opt/bin, /opt/etc, /opt/sbin
	
	if [ -x "/opt/bin/opkg" ] || [ -x "/opt/sbin/opkg" ]; then
		ENTWARE=1
		return 0
	fi
	
	# Дополнительная проверка: наличие конфигурации opkg в /opt
	if [ -f "/opt/etc/opkg.conf" ]; then
		ENTWARE=1
		return 0
	fi
	
	# Проверка структуры директорий Entware
	if [ -d "/opt/bin" ] && [ -d "/opt/etc" ] && [ -d "/opt/sbin" ] && [ -d "/opt/var" ]; then
		# Проверяем, что это не просто случайные директории
		# Entware обычно имеет /opt/var/opkg-lists или /opt/share
		if [ -d "/opt/var/opkg-lists" ] || [ -d "/opt/share" ] || [ -f "/opt/etc/profile" ]; then
			ENTWARE=1
			return 0
		fi
	fi
	
	return 1
}

# Определение директорий systemd
SYSTEMD_DIR=/lib/systemd
[ -d "$SYSTEMD_DIR" ] || SYSTEMD_DIR=/usr/lib/systemd
[ -d "$SYSTEMD_DIR" ] && SYSTEMD_SYSTEM_DIR="$SYSTEMD_DIR/system"

# Переменные для результатов
SYSTEM=
SUBSYS=
ENTWARE=
UNAME=$(uname)

MACHINE_MODE=0
case "${1:-}" in
	--machine|-m)
		MACHINE_MODE=1
		;;
esac

if [ "$MACHINE_MODE" != "1" ]; then
	echo "=== Определение системы ==="
	echo "UNAME: $UNAME"
	echo
fi

if [ "$UNAME" = "Linux" ]; then
	if [ "$MACHINE_MODE" != "1" ]; then
		echo "Проверка Linux системы..."
	fi
	
	# Определение init процесса
	INIT="$(sed 's/\x0/\n/g' /proc/1/cmdline 2>/dev/null | head -n 1)"
	[ -L "$INIT" ] && INIT=$(readlink "$INIT" 2>/dev/null)
	INIT="$(basename "$INIT")"
	if [ "$MACHINE_MODE" != "1" ]; then
		echo "Init процесс: $INIT"
	fi
	
	# Проверка systemd
	SYSTEMCTL="$(whichq systemctl)"
	if [ "$MACHINE_MODE" != "1" ]; then
		echo "systemctl: ${SYSTEMCTL:-не найден}"
		echo "SYSTEMD_DIR: ${SYSTEMD_DIR:-не найден}"
	fi
	
	if [ -d "$SYSTEMD_DIR" ] && [ -x "$SYSTEMCTL" ] && [ "$INIT" = "systemd" ]; then
		SYSTEM=systemd
		if [ "$MACHINE_MODE" != "1" ]; then
			echo ">>> Определено: SYSTEM=systemd"
			echo "   - Директория systemd найдена: $SYSTEMD_DIR"
			echo "   - systemctl найден: $SYSTEMCTL"
			echo "   - Init процесс: systemd"
		fi
	
	# Проверка OpenWrt
	elif [ -f "/etc/openwrt_release" ] && (exists opkg || exists apk) && exists uci && [ "$INIT" = "procd" ]; then
		SYSTEM=openwrt
		OPENWRT_PACKAGER=opkg
		if exists apk; then
			OPENWRT_PACKAGER=apk
		fi
		if [ "$MACHINE_MODE" != "1" ]; then
			echo ">>> Определено: SYSTEM=openwrt"
			echo "   - Файл /etc/openwrt_release найден"
			echo "   - Пакетный менеджер: $OPENWRT_PACKAGER"
			echo "   - uci найден"
			echo "   - Init процесс: procd"
		fi
		
		# Проверка версии файрвола
		if [ "$MACHINE_MODE" != "1" ]; then
			if [ ! -x /sbin/fw4 ] && [ -x /sbin/fw3 ]; then
				echo "   - Firewall: fw3"
			elif [ -x /sbin/fw4 ]; then
				echo "   - Firewall: fw4"
			fi
		fi
	
	# Проверка OpenRC
	elif exists rc-update && ([ "$INIT" = "openrc-init" ] || grep -qE "sysinit.*openrc" /etc/inittab 2>/dev/null); then
		SYSTEM=openrc
		if [ "$MACHINE_MODE" != "1" ]; then
			echo ">>> Определено: SYSTEM=openrc"
			echo "   - rc-update найден"
			if [ "$INIT" = "openrc-init" ]; then
				echo "   - Init процесс: openrc-init"
			else
				echo "   - OpenRC найден в /etc/inittab"
			fi
		fi
	
	# Generic Linux
	else
		SYSTEM=linux
		if [ "$MACHINE_MODE" != "1" ]; then
			echo ">>> Определено: SYSTEM=linux (generic)"
			echo "   - Система не определена как systemd, openwrt или openrc"
			echo "   - Будет использован generic Linux режим"
		fi
	fi
	
	# Определение подсистемы
	if [ "$MACHINE_MODE" != "1" ]; then
		echo
		echo "=== Определение подсистемы ==="
	fi
	
	# Повторное определение INIT для подсистемы
	INIT_SUBSYS="$(sed 's/\x0/\n/g' /proc/1/cmdline 2>/dev/null | head -n 1)"
	[ -L "$INIT_SUBSYS" ] && INIT_SUBSYS=$(readlink "$INIT_SUBSYS" 2>/dev/null)
	INIT_SUBSYS="$(basename "$INIT_SUBSYS")"
	
	if [ -f "/etc/openwrt_release" ] && [ "$INIT_SUBSYS" = "procd" ]; then
		SUBSYS=openwrt
		if [ "$MACHINE_MODE" != "1" ]; then
			echo ">>> Определено: SUBSYS=openwrt"
		fi
	elif [ -x "/bin/ndm" ]; then
		SUBSYS=keenetic
		if [ "$MACHINE_MODE" != "1" ]; then
			echo ">>> Определено: SUBSYS=keenetic"
			echo "   - Найден /bin/ndm (Keenetic маркер)"
		fi
	else
		SUBSYS=
		if [ "$MACHINE_MODE" != "1" ]; then
			echo ">>> Определено: SUBSYS=(пусто, generic Linux)"
		fi
	fi

elif [ "$UNAME" = "Darwin" ]; then
	SYSTEM=macos
	if [ "$MACHINE_MODE" != "1" ]; then
		echo ">>> Определено: SYSTEM=macos"
	fi
	SUBSYS=
	if [ "$MACHINE_MODE" != "1" ]; then
		echo ">>> Определено: SUBSYS=(не применимо для macOS)"
	fi

else
	echo ">>> Система не поддерживается: $UNAME" >&2
	echo "   Поддерживаются только Linux и macOS" >&2
	exit 1
fi

# Проверка Entware
if [ "$UNAME" = "Linux" ]; then
	check_entware
fi

ENTWARE_TEXT="нет"
[ "$ENTWARE" = "1" ] && ENTWARE_TEXT="да"

# Получаем версию NDM/firmware на Keenetic (если доступен ndmc)
NDM_RELEASE=""
NDM_TITLE=""
NDM_ARCH=""
NDM_MODEL=""
if [ "$SUBSYS" = "keenetic" ] && exists ndmc; then
	# ndmc выводит поля с двоеточием, используем awk и берем первое совпадение
	NDM_RELEASE="$(ndmc -c "show version" 2>/dev/null | awk -F': *' '/^[[:space:]]*release:/{print $2; exit}')"
	NDM_TITLE="$(ndmc -c "show version" 2>/dev/null | awk -F': *' '/^[[:space:]]*title:/{print $2; exit}')"
	NDM_ARCH="$(ndmc -c "show version" 2>/dev/null | awk -F': *' '/^[[:space:]]*arch:/{print $2; exit}')"
	NDM_MODEL="$(ndmc -c "show version" 2>/dev/null | awk -F': *' '/^[[:space:]]*model:/{print $2; exit}')"
fi

if [ "$MACHINE_MODE" = "1" ]; then
	echo "SYSTEM=$SYSTEM"
	[ -n "$SUBSYS" ] && echo "SUBSYS=$SUBSYS" || echo "SUBSYS="
	echo "ENTWARE=$ENTWARE_TEXT"
	[ -n "$NDM_RELEASE" ] && echo "NDM_RELEASE=$NDM_RELEASE"
	[ -n "$NDM_TITLE" ] && echo "NDM_TITLE=$NDM_TITLE"
	[ -n "$NDM_ARCH" ] && echo "NDM_ARCH=$NDM_ARCH"
	[ -n "$NDM_MODEL" ] && echo "NDM_MODEL=$NDM_MODEL"
	exit 0
fi

echo
echo "=== Итоговый результат ==="
echo "SYSTEM=$SYSTEM"
[ -n "$SUBSYS" ] && echo "SUBSYS=$SUBSYS" || echo "SUBSYS=(пусто)"
echo "ENTWARE=$ENTWARE_TEXT"
if [ -n "$NDM_RELEASE" ] || [ -n "$NDM_TITLE" ]; then
	echo "NDM_RELEASE=${NDM_RELEASE:-}"
	echo "NDM_TITLE=${NDM_TITLE:-}"
fi

# Дополнительная информация
echo
echo "=== Дополнительная информация ==="
if [ "$UNAME" = "Linux" ]; then
	echo "Проверка наличия пакетных менеджеров:"
	for pm in opkg apk apt yum dnf pacman; do
		if exists $pm; then
			echo "  - $pm: найден ($(whichq $pm))"
		fi
	done
	
	echo
	echo "Проверка наличия init систем:"
	[ -d "$SYSTEMD_DIR" ] && echo "  - systemd: директория найдена"
	exists rc-update && echo "  - openrc: rc-update найден"
	[ -f "/etc/openwrt_release" ] && echo "  - openwrt: /etc/openwrt_release найден"
	
	echo
	echo "Проверка специфичных маркеров:"
	[ -x "/bin/ndm" ] && echo "  - Keenetic: /bin/ndm найден"
	exists uci && echo "  - OpenWrt UCI: найден"
	[ -x /sbin/fw3 ] && echo "  - OpenWrt fw3: найден"
	[ -x /sbin/fw4 ] && echo "  - OpenWrt fw4: найден"
	
	echo
	echo "Проверка Entware:"
	if check_entware; then
		echo "  - Entware: ОБНАРУЖЕН"
		[ -x "/opt/bin/opkg" ] && echo "    - /opt/bin/opkg найден"
		[ -x "/opt/sbin/opkg" ] && echo "    - /opt/sbin/opkg найден"
		[ -f "/opt/etc/opkg.conf" ] && echo "    - /opt/etc/opkg.conf найден"
		[ -d "/opt/var/opkg-lists" ] && echo "    - /opt/var/opkg-lists найден"
		[ -d "/opt/bin" ] && echo "    - /opt/bin существует"
		[ -d "/opt/etc" ] && echo "    - /opt/etc существует"
		[ -d "/opt/sbin" ] && echo "    - /opt/sbin существует"
		
		# Проверка, где находится opkg (системный или entware)
		OPKG_PATH="$(whichq opkg)"
		if [ -n "$OPKG_PATH" ]; then
			case "$OPKG_PATH" in
				/opt/*)
					echo "    - opkg из PATH указывает на Entware: $OPKG_PATH"
					;;
				*)
					echo "    - opkg из PATH: $OPKG_PATH (не Entware)"
					;;
			esac
		fi
	else
		echo "  - Entware: не обнаружен"
		[ -d "/opt" ] && echo "    - /opt существует, но не похоже на Entware"
	fi
fi

exit 0

