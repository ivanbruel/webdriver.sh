#!/bin/bash
#
# webdriver.sh - bash script for managing Nvidia's web drivers
# Copyright © 2017-2018 vulgo
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

SCRIPT_VERSION="1.2.4"
BASENAME=$(/usr/bin/basename "$0")
RAW_ARGS=($@)
MACOS_PRODUCT_VERSION=$(/usr/bin/sw_vers -productVersion)
if ! /usr/bin/grep -e "10.13" <<< "$MACOS_PRODUCT_VERSION" > /dev/null 2>&1; then
	printf 'Unsupported macOS version'; exit 1; fi
if ! LOCAL_BUILD=$(/usr/bin/sw_vers -buildVersion); then
	printf 'sw_vers error'; exit $?; fi
	
# SIP
declare KEXT_ALLOWED=false FS_ALLOWED=false
KEXT_PATTERN='System Integrity Protection status: disabled|Kext Signing: disabled'
CSR_STATUS=$(/usr/bin/csrutil status)
/usr/bin/csrutil status | /usr/bin/grep -E -e "$KEXT_PATTERN" <<< "$CSR_STATUS" > /dev/null \
	&& KEXT_ALLOWED=true
/usr/bin/touch /System > /dev/null 2>&1 && FS_ALLOWED=true

# Variables
declare R='\e[0m' B='\e[1m' U='\e[4m'
TMP_DIR=$(/usr/bin/mktemp -dt webdriver)
UPDATES_PLIST="${TMP_DIR}/$(/usr/bin/uuidgen)"
INSTALLER_PKG="${TMP_DIR}/$(/usr/bin/uuidgen)"
EXTRACTED_PKG_DIR="${TMP_DIR}/$(/usr/bin/uuidgen)"
SQL_QUERY_FILE="${TMP_DIR}/$(/usr/bin/uuidgen)"
DRIVERS_PKG="${TMP_DIR}/com.nvidia.web-driver.pkg"
DRIVERS_ROOT="${TMP_DIR}/$(/usr/bin/uuidgen)"
DRIVERS_DIR_HINT="NVWebDrivers.pkg"
STARTUP_KEXT="/Library/Extensions/NVDAStartupWeb.kext"
EGPU_KEXT="/Library/Extensions/NVDAEGPUSupport.kext"
BREW_PREFIX=$(brew --prefix 2> /dev/null)
HOST_PREFIX="/usr/local"
ERR_PLIST_READ="Couldn't read a required value from a property list"
ERR_PLIST_WRITE="Couldn't set a required value in a property list"
SET_NVRAM="/usr/sbin/nvram nvda_drv=1%00"
UNSET_NVRAM="/usr/sbin/nvram -d nvda_drv"
declare CHANGES_MADE=false RESTART_REQUIRED=false REINSTALL_MESSAGE=false
declare -i EXIT_ERROR=0 COMMAND_COUNT=0
declare OPT_REINSTALL=false OPT_SYSTEM=false OPT_ALL=false

if [[ $BASENAME =~ "swebdriver" ]]; then
	[[ $1 != "-u" ]] && exit 1
	[[ -z $2 ]] && exit 1
	set -- "-u" "$2"
	OPT_SYSTEM=true
fi

function usage() {
	printf 'Usage: %s [-f] [-l|-u URL|-r|-m [BUILD]]\n' "$BASENAME"
	printf '    -l            choose which driver to install from a list\n'
	printf '    -u URL        install driver package at URL, no version checks\n'
	printf '    -r            uninstall drivers\n'
	printf "    -m [BUILD]    modify the current driver's NVDARequiredOS"'\n'
	printf '    -f            re-install the current drivers\n'
}

function version() {
	printf 'webdriver.sh %s Copyright © 2017-2018 vulgo\n' "$SCRIPT_VERSION"
	printf 'This is free software: you are free to change and redistribute it.\n'
	printf 'There is NO WARRANTY, to the extent permitted by law.\n'
	printf 'See the GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>\n'
}

while getopts ":hvlu:rm:fa" OPTION; do
	case $OPTION in
	"h")
		usage
		exit 0;;
	"v")
		version
		exit 0;;
	"l")
		COMMAND="CMD_LIST"
		OPT_REINSTALL=true
		COMMAND_COUNT+=1;;
	"u")
		COMMAND="CMD_USER_URL"
		REMOTE_URL="$OPTARG"
		COMMAND_COUNT+=1;;
	"r")
		COMMAND="CMD_UNINSTALL"
		COMMAND_COUNT+=1;;
	"m")
		COMMAND="CMD_REQUIRED_OS"
		OPT_REQUIRED_OS="$OPTARG"
		COMMAND_COUNT+=1;;
	"f")
		OPT_REINSTALL=true;;
	"a")
		OPT_ALL=true;;
	"?")
		printf 'Invalid option: -%s\n' "$OPTARG"
		usage
		exit 1;;
	":")
		if [[ $OPTARG == "m" ]]; then
			OPT_REQUIRED_OS="$LOCAL_BUILD"
			COMMAND="CMD_REQUIRED_OS"
			COMMAND_COUNT+=1
		else
			printf 'Missing parameter for -%s\n' "$OPTARG"
			usage
			exit 1
		fi;;
	esac
	if (( COMMAND_COUNT > 1)); then
		printf 'Too many options\n'
		usage
		exit 1
	fi
done

if (( COMMAND_COUNT == 0 )); then
	shift $(( OPTIND - 1 ))
	while (( $# > 0)); do
		if [[ -f "$1" ]]; then
			COMMAND="CMD_FILE"
			OPT_FILEPATH="$1"
			break
		fi
	shift
	done
fi

[[ $(/usr/bin/id -u) != "0" ]] && exec /usr/bin/sudo -u root "$0" "${RAW_ARGS[@]}"

function s() {
	# s $@: args... 
	"$@" > /dev/null 2>&1
	return $?
}

function e() {
	# e $1: message, $2: exit_code
	s rm -rf "$TMP_DIR"
	if [[ -z $2 ]]; then
		printf '%bError%b: %s\n' "$U" "$R" "$1"
	else
		printf '%bError%b: %s (%s)\n' "$U" "$R" "$1" "$2"
	fi
	$CHANGES_MADE && $UNSET_NVRAM
	! $CHANGES_MADE && printf 'No changes were made\n'
	exit 1
}

function exit_quietly() {
	s rm -rf "$TMP_DIR"
	exit $EXIT_ERROR
}

function exit_after_update() {
	s rm -rf "$TMP_DIR"
	[[ $EXIT_ERROR -eq 0 ]] && printf 'Complete.\n'
	exit $EXIT_ERROR
}

function exit_after_install() {
	printf 'Installation complete.'
	$RESTART_REQUIRED && printf ' You should reboot now.'
	printf '\n'
	s rm -rf "$TMP_DIR"
	exit $EXIT_ERROR
}

function warning() {
	# warning $1: message
	printf '%bWarning%b: %s\n' "$U" "$R" "$1" 
}

function etc() {
	# exec_conf $1: path_to_script $2: arg_1
	if [[ -f "${BREW_PREFIX}${1}" ]]; then
		"${BREW_PREFIX}${1}" "$2"
	elif [[ -f "${HOST_PREFIX}${1}" ]]; then
		"${HOST_PREFIX}${1}" "$2"
	fi
}

function uninstall_drivers() {
	local REMOVE_LIST="/Library/Extensions/GeForce* \
		/Library/Extensions/NVDA* \
		/System/Library/Extensions/GeForce*Web* \
		/System/Library/Extensions/NVDA*Web*"
	s mv "$EGPU_KEXT" "~$EGPU_KEXT"
	# shellcheck disable=SC2086
	s rm -rf $REMOVE_LIST
	s pkgutil --forget com.nvidia.web-driver
	s mv "~$EGPU_KEXT" "$EGPU_KEXT"
	etc "/etc/webdriver.sh/uninstall.conf"
}

function caches_error() {
	# caches_error $1: warning_message
	warning "$1"
	EXIT_ERROR=1
	RESTART_REQUIRED=false
}

function update_caches() {
	if $OPT_SYSTEM; then
		warning "Caches are not being updated"
		return 0
	fi
	local PLK="Created prelinked kernel"
	local ERR_PLK="There was a problem creating the prelinked kernel"
	local SLE="caches updated for /System/Library/Extensions"
	local ERR_SLE="There was a problem updating directory caches for /S/L/E"
	local LE="caches updated for /Library/Extensions"
	local ERR_LE="There was a problem updating directory caches for /L/E"
	local RESULT
	printf '%bUpdating caches...%b\n' "$B" "$R"
	RESULT=$(/usr/sbin/kextcache -v 2 -i / 2>&1)
	s /usr/bin/grep "$PLK" <<< "$RESULT" || caches_error "$ERR_PLK"
	s /usr/bin/grep "$SLE" <<< "$RESULT" || caches_error "$ERR_SLE"
	s /usr/bin/grep "$LE" <<< "$RESULT" || caches_error "$ERR_LE"
	(( EXIT_ERROR != 0 )) && printf '\nTo try again use:\n%bsudo kextcache -i /%b\n\n' "$B" "$R"	 
}

function ask() {
	# ask $1: message
	local ASK
	printf '%b%s%b' "$B" "$1" "$R"
	read -n 1 -srp " [y/N]" ASK
	printf '\n'
	if [[ $ASK == "y" || $ASK == "Y" ]]; then
		return 0
	else
		return 1
	fi
}

function plistb() {
	# plistb $1: command, $2: file
	local RESULT
	if [[ ! -f "$2" ]]; then
		return 1
	else 
		! RESULT=$(/usr/libexec/PlistBuddy -c "$1" "$2" 2> /dev/null) && return 1
	fi
	[[ $RESULT ]] && printf "%s" "$RESULT"
	return 0
}

function sha512() {
	# checksum $1: file
	local RESULT
	RESULT=$(/usr/bin/shasum -a 512 "$1" | /usr/bin/awk '{print $1}')
	[[ $RESULT ]] && printf '%s' "$RESULT"
}

function set_required_os() {
	# set_required_os $1: target_version
	local RESULT
	local TARGET_BUILD="$1"
	local KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
	RESULT=$(plistb "Print $KEY" "${STARTUP_KEXT}/Contents/Info.plist") || e "$ERR_PLIST_READ"
	if [[ $RESULT == "$TARGET_BUILD" ]]; then
		printf 'NVDARequiredOS already set to %s\n' "$TARGET_BUILD"
	else 
		CHANGES_MADE=true
		printf '%bSetting NVDARequiredOS to %s...%b\n' "$B" "$TARGET_BUILD" "$R"
		plistb "Set $KEY $TARGET_BUILD" "${STARTUP_KEXT}/Contents/Info.plist" || e "$ERR_PLIST_WRITE"
	fi
	if [[ -f "${EGPU_KEXT}/Contents/Info.plist" ]]; then
		RESULT=$(plistb "Print $KEY" "${EGPU_KEXT}/Contents/Info.plist") || e "$ERR_PLIST_READ"
		if [[ $RESULT == "$TARGET_BUILD" ]]; then
			printf 'Found NVDAEGPUSupport.kext, already set to %s\n' "$TARGET_BUILD"
		else
			CHANGES_MADE=true
			printf '%bFound NVDAEGPUSupport.kext, setting NVDARequiredOS to %s...%b\n' "$B" "$TARGET_BUILD" "$R"
			plistb "Set $KEY $TARGET_BUILD" "${EGPU_KEXT}/Contents/Info.plist"  || e "$ERR_PLIST_WRITE"
		fi
	fi
}

function check_required_os() {
	$OPT_SYSTEM && return 0
	local RESULT
	local KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
	if [[ -f ${STARTUP_KEXT}/Contents/Info.plist ]]; then
		RESULT=$(plistb "Print $KEY" "${STARTUP_KEXT}/Contents/Info.plist") || e "$ERR_PLIST_READ"
		if [[ $RESULT != "$LOCAL_BUILD" ]]; then
			ask "Modify installed driver for the current macOS version?" || return 0
			set_required_os "$LOCAL_BUILD"
			RESTART_REQUIRED=true
			$KEXT_ALLOWED || warning "Disable SIP, run 'kextcache -i /' to allow modified drivers to load"
			return 1
		fi
	fi
}

function installed_version() {
	local PLIST="/Library/Extensions/GeForceWeb.kext/Contents/Info.plist"
	if [[ -f $PLIST ]]; then
		GET_INFO_STRING=$(plistb "Print :CFBundleGetInfoString" "$PLIST")
		GET_INFO_STRING="${GET_INFO_STRING##* }"
		printf "%s" "$GET_INFO_STRING"
	fi
}

function sql_add_kext() {
	# sql_add_kext $1:bundle_id
	printf 'insert or replace into kext_policy '
	printf '(team_id, bundle_id, allowed, developer_name, flags) '
	printf 'values (\"%s\",\"%s\",1,\"%s\",1);\n' "6KR3T733EC" "$1" "NVIDIA Corporation"
} >> "$SQL_QUERY_FILE"

function match_build() {
	# match_build $1:local $2:remote
	local -i LOCAL=$1
	local -i REMOTE=$2
	[[ $REMOTE -eq $(( LOCAL + 1 )) ]] && return 0
	[[ $REMOTE -ge 17 && $REMOTE -eq $(( LOCAL - 1 )) ]] && return 0
	return 1
}

# COMMAND CMD_REQUIRED_OS

if [[ $COMMAND == "CMD_REQUIRED_OS" ]]; then
	EXIT_ERROR=0
	if [[ ! -f "${STARTUP_KEXT}/Contents/Info.plist" ]]; then
		printf 'Nvidia driver not found\n'
		EXIT_ERROR=1
	else
		set_required_os "$OPT_REQUIRED_OS"
	fi
	if $CHANGES_MADE; then
		update_caches
	else
		printf 'No changes were made\n'
	fi
	if [[ $EXIT_ERROR == 0 ]]; then
		$SET_NVRAM
	else
		$UNSET_NVRAM
	fi
	exit_after_update
fi

# COMMAND CMD_UNINSTALL

if [[ $COMMAND == "CMD_UNINSTALL" ]]; then
	ask "Uninstall Nvidia web drivers?"
	printf '%bRemoving files...%b\n' "$B" "$R"
	CHANGES_MADE=true
	uninstall_drivers
	update_caches
	$UNSET_NVRAM
	exit_after_install
fi

# UPDATER/INSTALLER

if [[ $COMMAND == "CMD_USER_URL" ]]; then
	# Invoked with -u option, proceed to installation
	printf 'URL: %s\n' "$REMOTE_URL"
elif [[ $COMMAND == "CMD_FILE" ]]; then
	# Parsed file path, proceed to installation
	printf 'File: %s\n' "$OPT_FILEPATH"
else
	# No URL / filepath
	if [[ $COMMAND == "CMD_LIST" ]]; then
		LOCAL_MAJAOR=${LOCAL_BUILD:0:2}
		declare -a LIST_URLS LIST_VERSIONS LIST_CHECKSUMS LIST_BUILDS
		declare -i VERSION_MAX_WIDTH
	fi
	INSTALLED_VERSION=$(installed_version)
	# Get updates file
	printf '%bChecking for updates...%b\n' "$B" "$R"
	/usr/bin/curl -s --connect-timeout 15 -m 45 -o "$UPDATES_PLIST" "https://gfestage.nvidia.com/mac-update" \
		|| e "Couldn't get updates data from Nvidia" $?
	# shellcheck disable=SC2155
	declare -i c=$(/usr/bin/grep -c "<dict>" "$UPDATES_PLIST")
	(( c -= 1, i = 0 ))
	while (( i < c )); do
		unset -v REMOTE_BUILD REMOTE_MAJOR REMOTE_URL REMOTE_VERSION REMOTE_CHECKSUM
		! REMOTE_BUILD=$(plistb "Print :updates:${i}:OS" "$UPDATES_PLIST") && break			
		if [[ $REMOTE_BUILD == "$LOCAL_BUILD" || $COMMAND == "CMD_LIST" ]]; then
			REMOTE_MAJOR=${REMOTE_BUILD:0:2}
			REMOTE_URL=$(plistb "Print :updates:${i}:downloadURL" "$UPDATES_PLIST")
			REMOTE_VERSION=$(plistb "Print :updates:${i}:version" "$UPDATES_PLIST")
			REMOTE_CHECKSUM=$(plistb "Print :updates:${i}:checksum" "$UPDATES_PLIST")
			if [[ $COMMAND == "CMD_LIST" ]]; then
				if [[ $LOCAL_MAJAOR == "$REMOTE_MAJOR" ]] || ( $OPT_ALL && match_build "$LOCAL_MAJAOR" "$REMOTE_MAJOR" ); then
					LIST_URLS+=("$REMOTE_URL")
					LIST_VERSIONS+=("$REMOTE_VERSION")
					LIST_CHECKSUMS+=("$REMOTE_CHECKSUM")
					LIST_BUILDS+=("$REMOTE_BUILD")
					[[ ${#REMOTE_VERSION} -gt $VERSION_MAX_WIDTH ]] && VERSION_MAX_WIDTH=${#REMOTE_VERSION}
				fi
				(( ${#LIST_VERSIONS[@]} > 47 )) && break
				(( i += 1 ))
				continue
			fi	
			break
		fi
		(( i += 1 ))
	done;
	if [[ $COMMAND == "CMD_LIST" ]]; then
		while true; do
			printf '%bRunning on:%b macOS %s (%s)\n\n' "$B" "$R" "$MACOS_PRODUCT_VERSION" "$LOCAL_BUILD"
			count=${#LIST_VERSIONS[@]}
			FORMAT_COMMAND="/usr/bin/tee"
			tl=$(tput lines)
			[[ $count > $(( tl - 5 )) || $count -gt 15 ]] && FORMAT_COMMAND="/usr/bin/column"
			(( i = 0 ))
			VERSION_FORMAT_STRING="%-${VERSION_MAX_WIDTH}s"
			while (( i < count )); do
				(( n = i + 1 ))
				PADDED_INDEX=$(printf '%4s |  ' $n)
				ROW="$PADDED_INDEX"
				# shellcheck disable=SC2059
				PADDED_VERSION=$(printf "$VERSION_FORMAT_STRING" "${LIST_VERSIONS[$i]}")
				ROW+="$PADDED_VERSION  "
				ROW+="${LIST_BUILDS[$i]}"
				printf '%s\n' "$ROW"
				(( i += 1 ))
			done | $FORMAT_COMMAND
			printf '\n'
			printf '%bWhat now?%b [1-%s] : ' "$B" "$R" "$count"
			read -r int
			[[ -z $int ]] && exit_quietly
			if [[ $int =~ ^[0-9] ]] && (( int >= 1 )) && (( int <= count )); then
				(( int -= 1 ))
				REMOTE_URL=${LIST_URLS[$int]}
				REMOTE_VERSION=${LIST_VERSIONS[$int]}
				REMOTE_BUILD=${LIST_BUILDS[$int]}
				REMOTE_CHECKSUM=${LIST_CHECKSUMS[$int]}
				break
			fi
			printf '\nTry again...\n\n'
			tput bel
		done
	fi
	# Determine next action
	if [[ -z $REMOTE_URL || -z $REMOTE_VERSION ]]; then
		# No driver available, or error during check, exit
		printf 'No driver available for %s\n' "$LOCAL_BUILD"
		if ! check_required_os; then
			update_caches
			$SET_NVRAM
			exit_after_update
		fi
		exit_quietly
	elif [[ $REMOTE_VERSION == "$INSTALLED_VERSION" ]]; then
		# Latest already installed, exit
		printf '%s for %s already installed\n' "$REMOTE_VERSION" "$LOCAL_BUILD"
		if ! check_required_os; then
			update_caches
			$SET_NVRAM
			exit_after_update
		fi
		if $OPT_REINSTALL; then
			REINSTALL_MESSAGE=true
		else
			exit_quietly
		fi
	else
		if [[ $COMMAND != "CMD_LIST" ]]; then
			# Found an update, proceed to installation
			printf 'Web driver %s available...\n' "$REMOTE_VERSION"
		else
			# Chosen from a list
			printf 'Selected: %s for %s\n' "$REMOTE_VERSION" "$REMOTE_BUILD"
		fi
	fi
fi

# Prompt install y/n

if ! $OPT_SYSTEM; then
	if $REINSTALL_MESSAGE; then
		ask "Re-install?" || exit_quietly
	else
		ask "Install?" || exit_quietly
	fi
fi

if [[ $COMMAND != "CMD_FILE" ]]; then
	# Check URL
	REMOTE_HOST=$(printf '%s' "$REMOTE_URL" | /usr/bin/awk -F/ '{print $3}')
	if ! s /usr/bin/host "$REMOTE_HOST"; then
		[[ $COMMAND == "CMD_USER_URL" ]] && e "Unable to resolve host, check your URL"
		REMOTE_URL="https://images.nvidia.com/mac/pkg/"
		REMOTE_URL+="${REMOTE_VERSION%%.*}"
		REMOTE_URL+="/WebDriver-${REMOTE_VERSION}.pkg"
	fi
	HEADERS=$(/usr/bin/curl -I "$REMOTE_URL" 2>&1) || e "Failed to download HTTP headers"
	s /usr/bin/grep "octet-stream" <<< "$HEADERS" || warning "Unexpected HTTP content type"
	[[ $COMMAND != "CMD_USER_URL" ]] && printf 'URL: %s\n' "$REMOTE_URL"

	# Download
	printf '%bDownloading package...%b\n' "$B" "$R"
	/usr/bin/curl --connect-timeout 15 -# -o "$INSTALLER_PKG" "$REMOTE_URL" || e "Failed to download package" $?

	# Checksum
	LOCAL_CHECKSUM=$(sha512 "$INSTALLER_PKG")
	if [[ $REMOTE_CHECKSUM ]]; then
		if [[ $LOCAL_CHECKSUM == "$REMOTE_CHECKSUM" ]]; then
			printf 'SHA512: Verified\n'
		else
			e "SHA512 verification failed"
		fi
	else
		printf 'SHA512: %s\n' "$LOCAL_CHECKSUM"
	fi
else
	/bin/cp "$OPT_FILEPATH" "$INSTALLER_PKG"
fi

# Unflatten

printf '%bExtracting...%b\n' "$B" "$R"
/usr/sbin/pkgutil --expand "$INSTALLER_PKG" "$EXTRACTED_PKG_DIR" || e "Failed to extract package" $?
DIRS=("$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT")
# shellcheck disable=SC2076,SC2049
if [[ ${#DIRS[@]} == 1 ]] && [[ ! ${DIRS[0]} =~ "*" ]]; then
        DRIVERS_COMPONENT_DIR=${DIRS[0]}
else
        e "Failed to find pkgutil output directory"
fi

# Extract drivers

mkdir "$DRIVERS_ROOT"
/usr/bin/gunzip -dc < "${DRIVERS_COMPONENT_DIR}/Payload" > "${DRIVERS_ROOT}/tmp.cpio" \
	|| e "Failed to extract package" $?
cd "$DRIVERS_ROOT" || e "Failed to find drivers root directory" $?
/usr/bin/cpio -i < "${DRIVERS_ROOT}/tmp.cpio" || e "Failed to extract package" $?
s rm -f "${DRIVERS_ROOT}/tmp.cpio"
if [[ ! -d ${DRIVERS_ROOT}/Library/Extensions || ! -d ${DRIVERS_ROOT}/System/Library/Extensions ]]; then
	e "Unexpected directory structure after extraction"; fi

# Make SQL and allow kexts

if $FS_ALLOWED; then
	printf '%bApproving kexts...%b\n' "$B" "$R"
	cd "$DRIVERS_ROOT" || e "Failed to find drivers root directory" $?
	KEXT_INFO_PLISTS=(./Library/Extensions/*.kext/Contents/Info.plist)
	for PLIST in "${KEXT_INFO_PLISTS[@]}"; do
		BUNDLE_ID=$(plistb "Print :CFBundleIdentifier" "$PLIST") || e "$ERR_PLIST_READ"
		[[ $BUNDLE_ID ]] && sql_add_kext "$BUNDLE_ID"
	done
	sql_add_kext "com.nvidia.CUDA"
	/usr/bin/sqlite3 /private/var/db/SystemPolicyConfiguration/KextPolicy < "$SQL_QUERY_FILE" \
		|| warning "sqlite3 exit code $?"
fi

# Install

uninstall_drivers
declare CHANGES_MADE=true NEEDS_KEXTCACHE=false RESTART_REQUIRED=true
if ! $FS_ALLOWED; then
	s /usr/bin/pkgbuild --identifier com.nvidia.web-driver --root "$DRIVERS_ROOT" "$DRIVERS_PKG"
	# macOS prompts to restart after Nvidia Corporation has been initially allowed, without
	# rebuilding caches, which should be done AFTER team_id has been added to kext_policy
	$KEXT_ALLOWED || warning "Don't restart until this process has completed"
	printf '%bInstalling...%b\n' "$B" "$R"
	s /usr/sbin/installer -allowUntrusted -pkg "$DRIVERS_PKG" -target / || e "installer error" $?
else
	printf '%bInstalling...%b\n' "$B" "$R"
	cp -r "${DRIVERS_ROOT}"/Library/Extensions/* /Library/Extensions
	cp -r "${DRIVERS_ROOT}"/System/Library/Extensions/* /System/Library/Extensions
	NEEDS_KEXTCACHE=true
fi
etc "/etc/webdriver.sh/post-install.conf" "$DRIVERS_ROOT"

# Check extensions are loadable

s /sbin/kextload "$STARTUP_KEXT" # kextload returns 27 when a kext hasn't been approved yet
if [[ $? -eq 27 ]]; then
	s /usr/bin/osascript -e "beep"
	printf 'Allow NVIDIA Corporation in security preferences to continue...\n'
	NEEDS_KEXTCACHE=true
	while ! s /usr/bin/kextutil -tn "$STARTUP_KEXT"; do
		s /usr/bin/osascript "${BREW_PREFIX}/etc/webdriver.sh/open-security-preferences.scpt"
		sleep 5
	done
fi

# Update caches, set nvram variable

check_required_os || NEEDS_KEXTCACHE=true
$NEEDS_KEXTCACHE && update_caches
$SET_NVRAM

# Exit

if $OPT_SYSTEM; then
	s rm -rf "$TMP_DIR"
	printf '%bSystem update...%b\n' "$B" "$R"
	s /usr/sbin/softwareupdate -ir
	exit_quietly
fi
exit_after_install
