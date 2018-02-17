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

SCRIPT_VERSION="1.0.18"

R='\e[0m'	# no formatting
B='\e[1m'	# bold
U='\e[4m'	# underline

PRODUCT_VERSION=$(/usr/bin/sw_vers -productVersion)
if ! /usr/bin/grep -e "10.13" <<< "$PRODUCT_VERSION" > /dev/null 2>&1; then
	printf 'Unsupported macOS version'
	exit 1
fi


if ! BUILD=$(/usr/bin/sw_vers -buildVersion); then
	printf 'sw_vers error\n'
	exit $?
fi

KEXT_ALLOWED=false
FS_ALLOWED=false
KEXT_PATTERN='System Integrity Protection status: disabled|Kext Signing: disabled'
CSR_STATUS=$(/usr/bin/csrutil status)
/usr/bin/csrutil status | /usr/bin/grep -E -e "$KEXT_PATTERN" <<< "$CSR_STATUS" > /dev/null \
	&& KEXT_ALLOWED=true
/usr/bin/touch /System > /dev/null 2>&1 \
	&& FS_ALLOWED=true

# Variables

REMOTE_UPDATE_PLIST="https://gfestage.nvidia.com/mac-update"
SQL_DEVELOPER_NAME="NVIDIA Corporation"
SQL_TEAM_ID="6KR3T733EC"
BASENAME=$(/usr/bin/basename "$0")
RAW_ARGS="$*"

TMP_DIR=$(/usr/bin/mktemp -dt webdriver)
DOWNLOADED_UPDATE_PLIST="${TMP_DIR}/nvwebupdates.plist"
DOWNLOADED_PKG="${TMP_DIR}/nvweb.pkg"
EXTRACTED_PKG_DIR="${TMP_DIR}/nvwebinstall"
SQL_QUERY_FILE="${TMP_DIR}/nvweb.sql"
PACKAGE="${TMP_DIR}/com.nvidia.web-driver.pkg"
DRIVERS_ROOT="${TMP_DIR}/root"
DRIVERS_DIR_HINT="NVWebDrivers.pkg"
STARTUP_KEXT="/Library/Extensions/NVDAStartupWeb.kext"
MOD_INFO_PLIST_PATH="${STARTUP_KEXT}/Contents/Info.plist"
INSTALLED_VERSION="/Library/Extensions/GeForceWeb.kext/Contents/Info.plist"
EGPU_INFO_PLIST_PATH="/Library/Extensions/NVDAEGPUSupport.kext/Contents/Info.plist"
MOD_KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
BREW_PREFIX=$(brew --prefix 2> /dev/null)
HOST_PREFIX="/usr/local"

CHANGES_MADE=false
RESTART_REQUIRED=true
REINSTALL_OPTION=false
REINSTALL_MESSAGE=false
SYSTEM_OPTION=false
YES_OPTION=false
INSTALLER_OPTION=false
(( CACHES_ERROR = 0 ))
(( COMMAND_COUNT = 0 ))


if [[ $BASENAME =~ "system-update" ]]; then
	[[ $1 != "-u" ]] && exit 1
	[[ -z $2 ]] && exit 1
	set -- "-Sycu" "$2"
fi

function usage() {
	printf 'Usage: %s [-f] [-l|-u URL|-r|-m [BUILD]]\n' "$BASENAME"
	printf '          -l            choose which driver to install from a list\n'
	printf '          -u URL        install driver package at URL, no version checks\n'
	printf '          -r            uninstall drivers\n'
	printf "          -m [BUILD]    modify the current driver's NVDARequiredOS"'\n'
	printf '          -f            re-install the current drivers\n'
}

function version() {
	printf 'webdriver.sh %s Copyright © 2017-2018 vulgo\n' "$SCRIPT_VERSION"
	printf 'This is free software: you are free to change and redistribute it.\n'
	printf 'There is NO WARRANTY, to the extent permitted by law.\n'
	printf 'See the GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>\n'
}

while getopts ":hvlpu:rm:cfSy!" OPTION; do
	case $OPTION in
	"h")
		usage
		exit 0;;
	"v")
		version
		exit 0;;
	"l")
		COMMAND="LIST_MODE"
		(( COMMAND_COUNT += 1 ));;
	"p")
		COMMAND="GET_PLIST_AND_EXIT"
		(( COMMAND_COUNT += 1 ));;
	"u")
		COMMAND="USER_PROVIDED_URL"
		REMOTE_URL="$OPTARG"
		(( COMMAND_COUNT += 1 ));;
	"r")
		COMMAND="UNINSTALL_DRIVERS_AND_EXIT"
		(( COMMAND_COUNT += 1 ));;
	"m")
		MOD_REQUIRED_OS="$OPTARG"
		COMMAND="SET_REQUIRED_OS_AND_EXIT"
		(( COMMAND_COUNT += 1 ));;
	"c")
		printf 'Info: The no caches option -c has been removed\n';;
	"f")
		REINSTALL_OPTION=true;;
	"S")	
		SYSTEM_OPTION=true;;
	"!")
		INSTALLER_OPTION=true;;
	"y")
		YES_OPTION=true;;
	"?")
		printf 'Invalid option: -%s\n' "$OPTARG"
		usage
		exit 1;;
	":")
		if [[ $OPTARG == "m" ]]; then
			MOD_REQUIRED_OS="$BUILD"
			COMMAND="SET_REQUIRED_OS_AND_EXIT"
			(( COMMAND_COUNT += 1 ))
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

function silent() {
	# silent $@: args... 
	"$@" > /dev/null 2>&1
	return $?
}

function error() {
	# error $1: message, $2: exit_code
	delete_temporary_files
	if [[ -z $2 ]]; then
		printf '%bError%b: %s\n' "$U" "$R" "$1"
	else
		printf '%bError%b: %s (%s)\n' "$U" "$R" "$1" "$2"
	fi
	if $CHANGES_MADE; then
		unset_nvram
	else
		printf 'No changes were made\n'
	fi
	exit 1
}

function delete_temporary_files() {
	silent rm -rf "$TMP_DIR"
}

function exit_ok() {
	delete_temporary_files
	exit 0
}

# COMMAND GET_PLIST_AND_EXIT

if [[ $COMMAND == "GET_PLIST_AND_EXIT" ]]; then
	(( i = 0 ))
	DOWNLOAD_PATH=~/Downloads/NvidiaUpdates
	while (( i < 49 )); do
		if (( i == 0 )); then
			DESTINATION="${DOWNLOAD_PATH}.plist"
		else
			DESTINATION="${DOWNLOAD_PATH}-${i}.plist"
		fi
		if [[ ! -f "$DESTINATION" ]]; then
			break
		fi
		(( i += 1 ))
	done
	printf '%bDownloading...%b\n' "$B" "$R"
	/usr/bin/curl -s --connect-timeout 15 -m 45 -o "$DESTINATION" "$REMOTE_UPDATE_PLIST" \
		|| error "Couldn't get updates data from Nvidia" $?
	printf '%s\n' "$DESTINATION"
	/usr/bin/open -R "$DESTINATION"
	delete_temporary_files
	exit 0
fi

# Check root

if [[ $(/usr/bin/id -u) != "0" ]]; then
	printf 'Run it as root: sudo %s %s' "$BASENAME" "$RAW_ARGS"
	exit 0
fi

function exit_after_install() {
	printf 'Complete.'
	if $RESTART_REQUIRED; then
		printf ' You should reboot now.\n'
	else
		printf '\n'
	fi
	exit $CACHES_ERROR
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

function post_install() {
	# post_install $1: extracted_package_dir
	local SCRIPT="/etc/webdriver.sh/post-install.conf"
	etc "$SCRIPT" "$1"
}

function uninstall_extra() {
	local SCRIPT="/etc/webdriver.sh/uninstall.conf"
	etc "$SCRIPT"
}

function uninstall_drivers() {
	local EGPU_DEFAULT="/Library/Extensions/NVDAEGPUSupport.kext"
	local EGPU_RENAMED="/Library/Extensions/EGPUSupport.kext"
	local REMOVE_LIST="/Library/Extensions/GeForce* \
		/Library/Extensions/NVDA* \
		/System/Library/Extensions/GeForce*Web* \
		/System/Library/Extensions/NVDA*Web*"
	# Remove drivers
	silent mv "$EGPU_DEFAULT" "$EGPU_RENAMED"
	silent rm -rf $REMOVE_LIST
	# Remove driver flat package receipt
	silent pkgutil --forget com.nvidia.web-driver
	silent mv "$EGPU_RENAMED" "$EGPU_DEFAULT"
	uninstall_extra
}

function caches_error() {
	# caches_error $1: warning_message
	warning "$1"
	(( CACHES_ERROR = 1 ))
}

function update_caches() {
	if $SYSTEM_OPTION; then
		warning "Caches are not being updated"
		return 0
	fi
	printf '%bUpdating caches...%b\n' "$B" "$R"
	local PLK="Created prelinked kernel"
	local SLE="caches updated for /System/Library/Extensions"
	local LE="caches updated for /Library/Extensions"
	local RESULT=
	RESULT=$(/usr/sbin/kextcache -v 2 -i / 2>&1)
	silent /usr/bin/grep "$PLK" <<< "$RESULT" \
		|| caches_error "There was a problem creating the prelinked kernel"
	silent /usr/bin/grep "$SLE" <<< "$RESULT" \
		|| caches_error "There was a problem updating directory caches for /S/L/E"
	silent /usr/bin/grep "$LE" <<< "$RESULT" \
		|| caches_error "There was a problem updating directory caches for /L/E"
	if (( CACHES_ERROR != 0 )); then
		printf '\nTo try again use:\n%bsudo kextcache -i /%b\n\n' "$B" "$R"
		RESTART_REQUIRED=false
	fi	 
}

function ask() {
	# ask $1: message
	local ASK=
	printf '%b%s%b' "$B" "$1" "$R"
	read -n 1 -srp " [y/N]" ASK
	printf '\n'
	if [[ $ASK == "y" || $ASK == "Y" ]]; then
		return 0
	else
		return 1
	fi
}

function plist_read_error() {
	error "Couldn't read a required value from a property list"
}

function plist_write_error() {
	error "Couldn't set a required value in a property list"
}

function plistb() {
	# plistb $1: command, $2: file
	local RESULT=
	if ! [[ -f "$2" ]]; then
		return 1;
	else 
		if ! RESULT=$(/usr/libexec/PlistBuddy -c "$1" "$2" 2> /dev/null); then
			return 1; fi
	fi
	[[ $RESULT ]] && printf "%s" "$RESULT"
	return 0
}

function sha512() {
	# checksum $1: file
	local RESULT=
	RESULT=$(/usr/bin/shasum -a 512 "$1" | /usr/bin/awk '{print $1}')
	[[ $RESULT ]] && printf '%s' "$RESULT"
}

function set_nvram() {
	/usr/sbin/nvram nvda_drv=1%00
}

function unset_nvram() {
	/usr/sbin/nvram -d nvda_drv
}

function set_required_os() {
	# set_required_os $1: target_version
	local RESULT=
	local BUILD="$1"
	RESULT=$(plistb "Print $MOD_KEY" "$MOD_INFO_PLIST_PATH") || plist_read_error
	if [[ $RESULT == "$BUILD" ]]; then
		printf 'NVDARequiredOS already set to %s\n' "$BUILD"
	else 
		CHANGES_MADE=true
		printf '%bSetting NVDARequiredOS to %s...%b\n' "$B" "$BUILD" "$R"
		plistb "Set $MOD_KEY $BUILD" "$MOD_INFO_PLIST_PATH" || plist_write_error
	fi
	if [[ -f $EGPU_INFO_PLIST_PATH ]]; then
		RESULT=$(plistb "Print $MOD_KEY" "$EGPU_INFO_PLIST_PATH") || plist_read_error
		if [[ $RESULT == "$BUILD" ]]; then
			printf 'Found NVDAEGPUSupport.kext, already set to %s\n' "$BUILD"
		else
			CHANGES_MADE=true
			printf '%bFound NVDAEGPUSupport.kext, setting NVDARequiredOS to %s...%b\n' "$B" "$BUILD" "$R"
			plistb "Set $MOD_KEY $BUILD" "$EGPU_INFO_PLIST_PATH"  || plist_write_error
		fi
	fi
}

function check_required_os() {
	$YES_OPTION && return 0
	local RESULT=
	if [[ -f $MOD_INFO_PLIST_PATH ]]; then
		RESULT=$(plistb "Print $MOD_KEY" "$MOD_INFO_PLIST_PATH") || plist_read_error
		if [[ $RESULT != "$BUILD" ]]; then
			ask "Modify installed driver for the current macOS version?" || return 0
			set_required_os "$BUILD"
			RESTART_REQUIRED=true
			$KEXT_ALLOWED || warning "Disable SIP, run 'kextcache -i /' to allow modified drivers to load"
			return 1
		fi
	fi
}

# COMMAND SET_REQUIRED_OS_AND_EXIT

if [[ $COMMAND == "SET_REQUIRED_OS_AND_EXIT" ]]; then
	(( ERROR = 0 ))
	if [[ ! -f $MOD_INFO_PLIST_PATH ]]; then
		printf 'Nvidia driver not found\n'
		(( ERROR = 1 ))
	else
		set_required_os "$MOD_REQUIRED_OS"
	fi
	if $CHANGES_MADE; then
		update_caches
	else
		printf 'No changes were made\n'
	fi
	if [[ $ERROR == 0 ]]; then
		set_nvram
	else
		unset_nvram
	fi
	delete_temporary_files
	exit $ERROR
fi

# COMMAND UNINSTALL_DRIVERS_AND_EXIT

if [[ $COMMAND == "UNINSTALL_DRIVERS_AND_EXIT" ]]; then
	ask "Uninstall Nvidia web drivers?"
	printf '%bRemoving files...%b\n' "$B" "$R"
	CHANGES_MADE=true
	uninstall_drivers
	update_caches
	unset_nvram
	exit_after_install
fi

function installed_version() {
	if [[ -f $INSTALLED_VERSION ]]; then
		GET_INFO_STRING=$(plistb "Print :CFBundleGetInfoString" "$INSTALLED_VERSION")
		GET_INFO_STRING="${GET_INFO_STRING##* }"
		printf "%s" "$GET_INFO_STRING"
	fi
}

function sql_add_kext() {
	# sql_add_kext $1:bundle_id
	printf 'insert or replace into kext_policy '
	printf '(team_id, bundle_id, allowed, developer_name, flags) '
	printf 'values (\"%s\",\"%s\",1,\"%s\",1);\n' "$SQL_TEAM_ID" "$1" "$SQL_DEVELOPER_NAME"
} >> "$SQL_QUERY_FILE"

# UPDATER/INSTALLER

if [[ $COMMAND != "USER_PROVIDED_URL" ]]; then
	
	if [[ $COMMAND == "LIST_MODE" ]]; then
		LM_MAJOR=${BUILD:0:2}
		declare -a LM_URLS
		declare -a LM_VERSIONS
		declare -a LM_CHECKSUMS
		declare -a LM_BUILDS
	fi

	# No URL specified, get installed web driver verison
	VERSION=$(installed_version)

	# Get updates file
	printf '%bChecking for updates...%b\n' "$B" "$R"
	/usr/bin/curl -s --connect-timeout 15 -m 45 -o "$DOWNLOADED_UPDATE_PLIST" "$REMOTE_UPDATE_PLIST" \
		|| error "Couldn't get updates data from Nvidia" $?

	# Check for an update
	c=$(/usr/bin/grep -c "<dict>" "$DOWNLOADED_UPDATE_PLIST")
	(( c -= 1, i = 0 ))
	while (( i < c )); do
		unset -v REMOTE_BUILD REMOTE_MAJOR REMOTE_URL REMOTE_VERSION REMOTE_CHECKSUM
		if ! REMOTE_BUILD=$(plistb "Print :updates:${i}:OS" "$DOWNLOADED_UPDATE_PLIST"); then
			break
		fi			
		if [[ $REMOTE_BUILD == "$BUILD" || $COMMAND == "LIST_MODE" ]]; then
			REMOTE_MAJOR=${REMOTE_BUILD:0:2}
			REMOTE_URL=$(plistb "Print :updates:${i}:downloadURL" "$DOWNLOADED_UPDATE_PLIST")
			REMOTE_VERSION=$(plistb "Print :updates:${i}:version" "$DOWNLOADED_UPDATE_PLIST")
			REMOTE_CHECKSUM=$(plistb "Print :updates:${i}:checksum" "$DOWNLOADED_UPDATE_PLIST")
			if [[ $COMMAND == "LIST_MODE" ]]; then
				if [[ $LM_MAJOR == $REMOTE_MAJOR ]]; then
					LM_URLS+=("$REMOTE_URL")
					LM_VERSIONS+=("$REMOTE_VERSION")
					LM_CHECKSUMS+=("$REMOTE_CHECKSUM")
					LM_BUILDS+=("$REMOTE_BUILD")
				fi
				(( i += 1 ))
				continue
			fi	
			break
		fi
		(( i += 1 ))
	done;
	
	if [[ $COMMAND == "LIST_MODE" ]]; then
		while true; do
			printf '%bRunning on:%b macOS %s (%s)\n\n' "$B" "$R" "$PRODUCT_VERSION" "$BUILD"
			count=${#LM_VERSIONS[@]}
			FORMAT="/usr/bin/tee"
			tl=$(tput lines)
			(( count > tl - 5 )) && FORMAT="/usr/bin/column"
			(( i = 0 ))
			while (( i < count )); do
				(( n = i + 1 ))
				INDEX=$(printf '%4s  ' $n)
				ROW="$INDEX"
				ROW+="${LM_VERSIONS[$i]}  "
				ROW+="${LM_BUILDS[$i]}"
				printf '%s\n' "$ROW"
				(( i += 1 ))
			done | $FORMAT
			printf '\n'
			printf '%bWhat now?%b [1-%s] : ' "$B" "$R" "$count"
			read int
			[[ -z $int ]] && exit_ok
			if [[ $int =~ ^[0-9] ]] && (( int >= 1 )) && (( int <= count )); then
				(( int -= 1 ))
				REMOTE_URL=${LM_URLS[$int]}
				REMOTE_VERSION=${LM_VERSIONS[$int]}
				REMOTE_BUILD=${LM_BUILDS[$int]}
				REMOTE_CHECKSUM=${LM_CHECKSUMS[$int]}
				break
			fi
			printf '\nTry again...\n\n' "$int"
			tput bel
		done
	fi
	
	# Determine next action
	if [[ -z $REMOTE_URL || -z $REMOTE_VERSION ]]; then
		# No driver available, or error during check, exit
		printf 'No driver available for %s\n' "$BUILD"
		check_required_os
		if $CHANGES_MADE; then
			update_caches
			set_nvram
		fi
		exit_ok
	elif [[ $REMOTE_VERSION == "$VERSION" ]]; then
		# Latest already installed, exit
		printf '%s for %s already installed\n' "$REMOTE_VERSION" "$BUILD"
		if ! $REINSTALL_OPTION; then
			# printf 'To re-install use -f\n' "$BASENAME"
			check_required_os
			if $CHANGES_MADE; then
				update_caches
				set_nvram
			fi
			exit_ok
		fi
		REINSTALL_MESSAGE=true
	else
		if [[ $COMMAND != "LIST_MODE" ]]; then
			# Found an update, proceed to installation
			printf 'Web driver %s available...\n' "$REMOTE_VERSION"
		else
			# Chosen from a list
			printf 'Selected: %s for %s\n' "$REMOTE_VERSION" "$REMOTE_BUILD"
		fi
	fi

else
	
	# Invoked with -u option, proceed to installation
	printf 'URL: %s\n' "$REMOTE_URL"
	RESTART_REQUIRED=false
	
fi

# Prompt install y/n

if ! $YES_OPTION; then
	if $REINSTALL_MESSAGE; then
		ask "Re-install?" || exit_ok
	else
		ask "Install?" || exit_ok
	fi
fi

# Check URL

REMOTE_HOST=$(printf '%s' "$REMOTE_URL" | /usr/bin/awk -F/ '{print $3}')
if ! silent /usr/bin/host "$REMOTE_HOST"; then
	if [[ $COMMAND == "USER_PROVIDED_URL" ]]; then
		error "Unable to resolve host, check your URL"; fi
	REMOTE_URL="https://images.nvidia.com/mac/pkg/"
	REMOTE_URL+="${REMOTE_VERSION%%.*}"
	REMOTE_URL+="/WebDriver-${REMOTE_VERSION}.pkg"
fi
HEADERS=$(/usr/bin/curl -I "$REMOTE_URL" 2>&1) \
	|| error "Failed to download HTTP headers"
silent /usr/bin/grep "octet-stream" <<< "$HEADERS" \
	|| warning "Unexpected HTTP content type"
if [[ $COMMAND != "USER_PROVIDED_URL" ]]; then
	printf 'URL: %s\n' "$REMOTE_URL"; fi

# Download

printf '%bDownloading package...%b\n' "$B" "$R"
/usr/bin/curl --connect-timeout 15 -# -o "$DOWNLOADED_PKG" "$REMOTE_URL" \
	|| error "Failed to download package" $?

# Checksum

LOCAL_CHECKSUM=$(sha512 "$DOWNLOADED_PKG")
if [[ $REMOTE_CHECKSUM ]]; then
	if [[ $LOCAL_CHECKSUM == "$REMOTE_CHECKSUM" ]]; then
		printf 'SHA512: Verified\n'
	else
		error "SHA512 verification failed"
	fi
else
	printf 'SHA512: %s\n' "$LOCAL_CHECKSUM"
fi

# Unflatten

printf '%bExtracting...%b\n' "$B" "$R"
/usr/sbin/pkgutil --expand "$DOWNLOADED_PKG" "$EXTRACTED_PKG_DIR" \
	|| error "Failed to extract package" $?
DIRS=("$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT")
if [[ ${#DIRS[@]} == 1 ]] && [[ ! ${DIRS[0]} =~ "*" ]]; then
        DRIVERS_COMPONENT_DIR=${DIRS[0]}
else
        error "Failed to find pkgutil output directory"
fi

# Extract drivers

mkdir "$DRIVERS_ROOT"
/usr/bin/gunzip -dc < "${DRIVERS_COMPONENT_DIR}/Payload" > "${DRIVERS_ROOT}/tmp.cpio" \
	|| error "Failed to extract package" $?
cd "$DRIVERS_ROOT" \
	|| error "Failed to find drivers root directory" $?
/usr/bin/cpio -i < "${DRIVERS_ROOT}/tmp.cpio" \
	|| error "Failed to extract package" $?
silent rm -f "${DRIVERS_ROOT}/tmp.cpio"
if [[ ! -d ${DRIVERS_ROOT}/Library/Extensions || ! -d ${DRIVERS_ROOT}/System/Library/Extensions ]]; then
	error "Unexpected directory structure after extraction"; fi

# Make SQL and allow kexts

if $FS_ALLOWED; then
	printf '%bApproving kexts...%b\n' "$B" "$R"
	cd "$DRIVERS_ROOT" || error "Failed to find drivers root directory" $?
	KEXT_INFO_PLISTS=(./Library/Extensions/*.kext/Contents/Info.plist)
	for PLIST in "${KEXT_INFO_PLISTS[@]}"; do
		BUNDLE_ID=$(plistb "Print :CFBundleIdentifier" "$PLIST") || plist_read_error
		[[ $BUNDLE_ID ]] && sql_add_kext "$BUNDLE_ID"
	done
	sql_add_kext "com.nvidia.CUDA"
	/usr/bin/sqlite3 /private/var/db/SystemPolicyConfiguration/KextPolicy < "$SQL_QUERY_FILE" \
		|| warning "sqlite3 exit code $?"
fi

# Install

printf '%bInstalling...%b\n' "$B" "$R"
CHANGES_MADE=true
uninstall_drivers
NEEDS_KEXTCACHE=false
if ! $FS_ALLOWED || $INSTALLER_OPTION; then
	silent /usr/bin/pkgbuild --identifier com.nvidia.web-driver --root "$DRIVERS_ROOT" "$PACKAGE"
	silent /usr/sbin/installer -allowUntrusted -pkg "$PACKAGE" -target / || error "installer error" $?
else
	cp -r "${DRIVERS_ROOT}"/Library/Extensions/* /Library/Extensions
	cp -r "${DRIVERS_ROOT}"/System/Library/Extensions/* /System/Library/Extensions
	NEEDS_KEXTCACHE=true
fi
post_install "$DRIVERS_ROOT"

# Check extensions are loadable, update caches, set nvram variable

if ! silent /usr/bin/kextutil -tn "$STARTUP_KEXT"; then
	silent /usr/bin/osascript -e "beep"
	warning 'Do not restart until this process has completed!'
	printf 'Allow %s in security preferences to continue...\n' "$SQL_DEVELOPER_NAME"
	NEEDS_KEXTCACHE=true
	REVEAL='tell app "System Preferences" to reveal anchor "General"'
	REVEAL+=' of pane id "com.apple.preference.security"'
	ACTIVATE='tell app "System Preferences" to activate'
	while ! silent /usr/bin/kextutil -tn "$STARTUP_KEXT"; do
		silent /usr/bin/osascript -e "$REVEAL" -e "$ACTIVATE"
		sleep 5
	done
fi
check_required_os || NEEDS_KEXTCACHE=true
$NEEDS_KEXTCACHE && update_caches
set_nvram

# Exit

delete_temporary_files
if $SYSTEM_OPTION; then
	printf '%bSystem update...%b\n' "$B" "$R"
	silent /usr/sbin/softwareupdate -ir
fi
exit_after_install
