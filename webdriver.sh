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

SCRIPT_VERSION="1.2.18"
grep="/usr/bin/grep"
shopt -s nullglob extglob
BASENAME=$(/usr/bin/basename "$0")
RAW_ARGS=("$@")
MACOS_PRODUCT_VERSION=$(/usr/bin/sw_vers -productVersion)
if ! $grep -qe "10.13" <<< "$MACOS_PRODUCT_VERSION"; then
	printf 'Unsupported macOS version'; exit 1; fi
if ! LOCAL_BUILD=$(/usr/bin/sw_vers -buildVersion); then
	printf 'sw_vers error'; exit $?; fi
$grep -qiE -e "nvdastartupweb.*allowed" <(/usr/sbin/ioreg -p IODeviceTree -c IOService -k boot-log -d 1 -r \
	| $grep boot-log | /usr/bin/awk -v FS="(<|>)" '{print $2}' | /usr/bin/xxd -r -p) && CLOVER_PATCH=1
	
# SIP
declare KEXT_ALLOWED=false FS_ALLOWED=false
$grep -qiE -e "status: disabled|signing: disabled" <(/usr/bin/csrutil status) && KEXT_ALLOWED=true
/usr/bin/touch /System 2> /dev/null && FS_ALLOWED=true

if test -t 0; then
	declare R='\e[0m' B='\e[1m' U='\e[4m'
fi
DRIVERS_DIR_HINT="NVWebDrivers.pkg"
STARTUP_KEXT="/Library/Extensions/NVDAStartupWeb.kext"
EGPU_KEXT="/Library/Extensions/NVDAEGPUSupport.kext"
ERR_PLIST_READ="Couldn't read a required value from a property list"
ERR_PLIST_WRITE="Couldn't set a required value in a property list"
SET_NVRAM="/usr/sbin/nvram nvda_drv=1%00"
UNSET_NVRAM="/usr/sbin/nvram -d nvda_drv"
declare CHANGES_MADE=false RESTART_REQUIRED=false REINSTALL_MESSAGE=false
declare -i EXIT_ERROR=0 COMMAND_COUNT=0
declare OPT_REINSTALL=false OPT_SYSTEM=false OPT_ALL=false OPT_YES=false

if [[ $BASENAME =~ "swebdriver" ]]; then
	[[ $1 != "-u" ]] && exit 1
	[[ -z $2 ]] && exit 1
	set -- "-u" "$2"
	OPT_SYSTEM=true
	OPT_YES=true
else
	set --
	for arg in "${RAW_ARGS[@]}"
	do
		case "$arg" in
		@(|-|--)help)
			set -- "$@" "-h";;
		@(|-|--)list)
			set -- "$@" "-l";;
		@(|-|--)url)
			set -- "$@" "-u";;
		@(|-|--)remove)
			set -- "$@" "-r";;
		@(|-|--)uninstall)
			set -- "$@" "-r";;
		@(|-|--)version)
			set -- "$@" "-v";;
		*)
			set -- "$@" "$arg";;
		esac
	done
fi

function usage() {
	printf 'Usage: %s [-f] [-l|-u|-r|-m|FILE]\n' "$BASENAME"
	printf '   --list    or  -l          choose which driver to install from a list\n'
	printf '   --url     or  -u URL      download package from URL and install drivers\n'
	printf '   --remove  or  -r          uninstall NVIDIA web drivers\n'
	printf "                 -m [BUILD]  apply Info.plist patch for NVDARequiredOS"'\n'
	printf '                 -f          continue when same version already installed\n'
}

function version() {
	printf 'webdriver.sh %s Copyright © 2017-2018 vulgo\n' "$SCRIPT_VERSION"
	printf 'This is free software: you are free to change and redistribute it.\n'
	printf 'There is NO WARRANTY, to the extent permitted by law.\n'
	printf 'See the GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>\n'
}

while getopts ":hvlu:rm:fa!:#:Y" OPTION; do
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
	"!")
		# shellcheck disable=SC2034
		CONFIG_ARGS="$OPTARG";;
	"#")
		REMOTE_CHECKSUM="$OPTARG";;
	"Y")
		OPT_YES=true;;
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
uuidgen="/usr/bin/uuidgen"
TMP_DIR=$(/usr/bin/mktemp -dt webdriver)
# shellcheck disable=SC2064
trap "rm -rf $TMP_DIR; stty echo echok; exit" SIGINT SIGTERM SIGHUP
UPDATES_PLIST="${TMP_DIR}/$($uuidgen)"
INSTALLER_PKG="${TMP_DIR}/$($uuidgen)"
EXTRACTED_PKG_DIR="${TMP_DIR}/$($uuidgen)"
DRIVERS_PKG="${TMP_DIR}/com.nvidia.web-driver.pkg"
DRIVERS_ROOT="${TMP_DIR}/$($uuidgen)"
if /bin/ls -la "$0" | $grep -qi cellar && HOST_PREFIX=$(brew --prefix 2> /dev/null); then
	true
else
	HOST_PREFIX=/usr/local
fi

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

function exit_after_changes() {
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
	# etc $1: path_to_script
	if [[ -f "${HOST_PREFIX}${1}" ]]; then
		# shellcheck source=/dev/null
		source "${HOST_PREFIX}${1}"
	fi
}

function scpt() {
	# scpt $1: path_to_script
	if [[ -f "${HOST_PREFIX}${1}" ]]; then
		/usr/bin/osascript  "${HOST_PREFIX}${1}" > /dev/null 2>&1
	fi
}

function uninstall_drivers() {
	local REMOVE_LIST=(/Library/Extensions/GeForce* \
		/Library/Extensions/NVDA* \
		/System/Library/Extensions/GeForce*Web* \
		/System/Library/Extensions/NVDA*Web*)
	REMOVE_LIST=("${REMOVE_LIST[@]/$EGPU_KEXT}")
	# shellcheck disable=SC2086
	s rm -rf "${REMOVE_LIST[@]}"
	s pkgutil --forget com.nvidia.web-driver
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
	$grep -qe "$PLK" <<< "$RESULT" || caches_error "$ERR_PLK"
	$grep -qe "$SLE" <<< "$RESULT" || caches_error "$ERR_SLE"
	$grep -qe "$LE" <<< "$RESULT" || caches_error "$ERR_LE"
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

function set_required_os() {
	# set_required_os $1: target_version
	local RESULT TARGET_BUILD="$1" KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
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
	if $OPT_YES || [[ $DONT_INVALIDATE_KEXTS -eq 1 ]] || [[ $CLOVER_PATCH -eq 1 ]]; then
		return 0; fi
	local RESULT KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
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

function sql_add_kext() {
	# sql_add_kext $1:bundle_id
	SQL+="insert or replace into kext_policy (team_id, bundle_id, allowed, developer_name, flags) "
	SQL+="values (\"6KR3T733EC\",\"${1}\",1,\"NVIDIA Corporation\",1); "
}

function match_build() {
	# match_build $1:local $2:remote
	local -i LOCAL=$1 REMOTE=$2
	[[ $REMOTE -eq $(( LOCAL + 1 )) ]] && return 0
	[[ $REMOTE -ge 17 && $REMOTE -eq $(( LOCAL - 1 )) ]] && return 0
	return 1
}

# COMMAND CMD_REQUIRED_OS

if [[ $COMMAND == "CMD_REQUIRED_OS" ]]; then
	if [[ ! -f "${STARTUP_KEXT}/Contents/Info.plist" ]]; then
		printf 'NVIDIA driver not found\n'
		$UNSET_NVRAM
		exit_quietly
	else
		if [[ $CLOVER_PATCH -eq 1 ]]; then
			warning 'NVDAStartupWeb is already being patched by Clover'
			ask 'Continue?' || exit_quietly
		fi
		set_required_os "$OPT_REQUIRED_OS"
	fi
	if $CHANGES_MADE; then
		update_caches
		$SET_NVRAM
		exit_after_changes
	else
		exit_quietly
	fi
fi

# COMMAND CMD_UNINSTALL

if [[ $COMMAND == "CMD_UNINSTALL" ]]; then
	ask "Uninstall NVIDIA web drivers?" || exit_quietly
	printf '%bRemoving files...%b\n' "$B" "$R"
	CHANGES_MADE=true
	uninstall_drivers
	update_caches
	$UNSET_NVRAM
	exit_after_install
fi

# Load settings

etc "/etc/webdriver.sh/settings.conf"

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
	# Get installed version
	INFO_STRING=$(plistb "Print :CFBundleGetInfoString" "/Library/Extensions/GeForceWeb.kext/Contents/Info.plist")
	[[ $INFO_STRING ]] && INSTALLED_VERSION="${INFO_STRING##* }"
	# Get updates file
	printf '%bChecking for updates...%b\n' "$B" "$R"
	/usr/bin/curl -s --connect-timeout 15 -m 45 -o "$UPDATES_PLIST" "https://gfestage.nvidia.com/mac-update" \
		|| e "Couldn't get updates data from NVIDIA" $?
	# shellcheck disable=SC2155
	declare -i c=$($grep -c "<dict>" "$UPDATES_PLIST")
	(( c -= 1, i = 0 ))
	while (( i < c )); do
		unset -v "REMOTE_BUILD" "REMOTE_MAJOR" "REMOTE_URL" "REMOTE_VERSION" "REMOTE_CHECKSUM"
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
			printf '%bCurrent driver:%b ' "$B" "$R"
			if [[ $INSTALLED_VERSION ]]; then
				printf '%s\n' "$INSTALLED_VERSION"
			else
				printf 'Not installed\n'
			fi
			printf '%bRunning on:%b macOS %s (%s)\n\n' "$B" "$R" "$MACOS_PRODUCT_VERSION" "$LOCAL_BUILD"
			count=${#LIST_VERSIONS[@]}
			FORMAT_COMMAND="/usr/bin/tee"
			tl=$(/usr/bin/tput lines)
			[[ $count -gt $(( tl - 5 )) || $count -gt 15 ]] && FORMAT_COMMAND="/usr/bin/column"
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
			/usr/bin/tput bel
		done
	fi
	# Determine next action
	if [[ -z $REMOTE_URL || -z $REMOTE_VERSION ]]; then
		# No driver available, or error during check, exit
		printf 'No driver available for %s\n' "$LOCAL_BUILD"
		if ! check_required_os; then
			update_caches
			$SET_NVRAM
			exit_after_changes
		fi
		exit_quietly
	elif [[ $REMOTE_VERSION == "$INSTALLED_VERSION" ]]; then
		# Chosen version already installed
		if [[ -f ${STARTUP_KEXT}/Contents/Info.plist ]]; then
			REQUIRED_OS_KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
			LOCAL_REQUIRED_OS=$(plistb "Print $REQUIRED_OS_KEY" "${STARTUP_KEXT}/Contents/Info.plist"); fi
		if [[ $LOCAL_REQUIRED_OS ]]; then
			printf '%s for %s already installed\n' "$REMOTE_VERSION" "$LOCAL_REQUIRED_OS"
		else
			printf '%s already installed\n' "$REMOTE_VERSION"
			OPT_REINSTALL=true
		fi
		if ! s codesign -v "$STARTUP_KEXT"; then
			printf 'Invalid signature: '
			$KEXT_ALLOWED && printf 'Allowed\n'
			! $KEXT_ALLOWED && printf 'Not allowed\n'
		fi		
		if ! check_required_os; then
			update_caches
			$SET_NVRAM
			exit_after_changes
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

if ! $OPT_YES; then
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
	$grep -qe "octet-stream" <<< "$HEADERS" || warning "Unexpected HTTP content type"
	[[ $COMMAND != "CMD_USER_URL" ]] && printf 'URL: %s\n' "$REMOTE_URL"

	# Download
	printf '%bDownloading package...%b\n' "$B" "$R"
	/usr/bin/curl --connect-timeout 15 -# -o "$INSTALLER_PKG" "$REMOTE_URL" || e "Failed to download package" $?

	# Checksum
	LOCAL_CHECKSUM=$(/usr/bin/shasum -a 512 "$INSTALLER_PKG" 2> /dev/null | /usr/bin/awk '{print $1}')
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
if [[ ${#DIRS[@]} -eq 1 ]] && [[ -d ${DIRS[0]} ]]; then
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
	e "Unexpected directory structure after extraction"
fi

# User-approved kernel extension loading

cd "$DRIVERS_ROOT" || e "Failed to find drivers root directory" $?
KEXT_INFO_PLISTS=(./Library/Extensions/*.kext/Contents/Info.plist)
declare -a BUNDLES APPROVED_BUNDLES
for PLIST in "${KEXT_INFO_PLISTS[@]}"; do
	BUNDLE_ID=$(plistb "Print :CFBundleIdentifier" "$PLIST")
	[[ $BUNDLE_ID ]] && BUNDLES+=("$BUNDLE_ID")
done
if $FS_ALLOWED; then
	# Approve kexts
	printf '%bApproving extensions...%b\n' "$B" "$R"
	for BUNDLE_ID in "${BUNDLES[@]}"; do
		sql_add_kext "$BUNDLE_ID"
	done
	sql_add_kext "com.nvidia.CUDA"
	/usr/bin/sqlite3 /private/var/db/SystemPolicyConfiguration/KextPolicy <<< "$SQL" \
		|| warning "sqlite3 exit code $?"
else
	# Get unapproved bundle IDs
	printf '%bExamining extensions...%b\n' "$B" "$R"
	QUERY="select bundle_id from kext_policy where team_id=\"6KR3T733EC\" and (flags=1 or flags=8)"
	while IFS= read -r LINE; do
		APPROVED_BUNDLES+=("$LINE")
	done < <(/usr/bin/sqlite3 /private/var/db/SystemPolicyConfiguration/KextPolicy "$QUERY" 2> /dev/null)
	for MATCH in "${APPROVED_BUNDLES[@]}"; do
		for index in "${!BUNDLES[@]}"; do
			if [[ ${BUNDLES[index]} == "$MATCH" ]]; then
				unset "BUNDLES[index]";
			fi;
		done;
	done
	UNAPPROVED_BUNDLES=$(printf "%s" "${BUNDLES[@]}")
fi
		
# Install

uninstall_drivers
declare CHANGES_MADE=true NEEDS_KEXTCACHE=false RESTART_REQUIRED=true
if ! $FS_ALLOWED; then
	s /usr/bin/pkgbuild --identifier com.nvidia.web-driver --root "$DRIVERS_ROOT" "$DRIVERS_PKG"
	# macOS prompts to restart after NVIDIA Corporation has been initially allowed, without
	# rebuilding caches, which should be done AFTER team_id has been added to kext_policy
	if ! $KEXT_ALLOWED && [[ ! -z $UNAPPROVED_BUNDLES ]]; then
		warning "Don't restart until this process is complete."; fi
	printf '%bInstalling...%b\n' "$B" "$R"
	s /usr/sbin/installer -allowUntrusted -pkg "$DRIVERS_PKG" -target / || e "installer error" $?
else
	printf '%bInstalling...%b\n' "$B" "$R"
	/usr/bin/rsync -r "${DRIVERS_ROOT}"/* /
	NEEDS_KEXTCACHE=true
fi
etc "/etc/webdriver.sh/post-install.conf"

# Check extensions are loadable

s /sbin/kextload "$STARTUP_KEXT" # kextload returns 27 when a kext hasn't been approved yet
if [[ $? -eq 27 ]]; then
	/usr/bin/tput bel
	printf 'Allow NVIDIA Corporation in security preferences to continue...\n'
	NEEDS_KEXTCACHE=true
	while ! s /usr/bin/kextutil -tn "$STARTUP_KEXT"; do
		scpt "/etc/webdriver.sh/open-security-preferences.scpt"
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
	$grep -iE -e "no updates|restart" <(/usr/sbin/softwareupdate -ir 2>&1) | /usr/bin/tail -1
fi
exit_after_install
