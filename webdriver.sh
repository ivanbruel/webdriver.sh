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

SCRIPT_VERSION="1.0.10"

R='\e[0m'	# no formatting
B='\e[1m'	# bold
U='\e[4m'	# underline

if ! /usr/bin/sw_vers -productVersion | grep "10.13" > /dev/null 2>&1; then
	printf 'Unsupported macOS version'
	exit 1
fi

MAC_OS_BUILD=$(/usr/bin/sw_vers -buildVersion)
DOWNLOADS_DIR=~/Downloads
REMOTE_UPDATE_PLIST="https://gfestage.nvidia.com/mac-update"
CHANGES_MADE=false
PROMPT_REBOOT=true
NO_CACHE_UPDATE=false
REINSTALL_OPTION=false
REINSTALL_MESSAGE=false
DOWNLOADED_UPDATE_PLIST="$DOWNLOADS_DIR/.nvwebupdates.plist"
DOWNLOADED_PKG="$DOWNLOADS_DIR/.nvweb.pkg"
EXTRACTED_PKG_DIR="$DOWNLOADS_DIR/.nvwebinstall"
SQL_QUERY_FILE="$DOWNLOADS_DIR/.nvweb.sql"
SQL_DEVELOPER_NAME="NVIDIA Corporation"
SQL_TEAM_ID="6KR3T733EC"
INSTALLED_VERSION="/Library/Extensions/GeForceWeb.kext/Contents/Info.plist"
DRIVERS_DIR_HINT="NVWebDrivers.pkg"
(( CACHES_ERROR = 0 ))
(( COMMAND_COUNT = 0 ))

function usage() {
	echo "Usage: $(basename "$0") [-f] [-c] [-h|-p|-r|-u url|-m [build]]"
	echo "          -f            re-install"
        echo "          -c            don't update caches"
	echo "          -h            print usage and exit"
	echo "          -p            download the updates property list and exit"
	echo "          -r            uninstall Nvidia web drivers"
	echo "          -u URL        install driver package at URL, no version checks"
	echo "          -m [build]    modify the current driver's NVDARequiredOS"
}

function version() {
	echo "webdriver.sh $SCRIPT_VERSION Copyright © 2017-2018 vulgo"
	echo "This is free software: you are free to change and redistribute it."
	echo "There is NO WARRANTY, to the extent permitted by law."
	echo "See the GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>"
}

while getopts ":hvpu:rm:cf" OPTION; do
	case $OPTION in
	"h")
		usage
		exit 0;;
	"v")
		version
		exit 0;;
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
		NO_CACHE_UPDATE=true
		PROMPT_REBOOT=false;;
	"f")
		REINSTALL_OPTION=true;;
	"?")
		printf 'Invalid option: -%s\n' "$OPTARG"
		usage
		exit 1;;
	":")
		if [[ $OPTARG == "m" ]]; then
			MOD_REQUIRED_OS="$MAC_OS_BUILD"
			COMMAND="SET_REQUIRED_OS_AND_EXIT"
			(( COMMAND_COUNT += 1 ))
		else
			printf 'Missing parameter\n'
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
	local REMOVE_LIST="$EXTRACTED_PKG_DIR \
		$DOWNLOADED_UPDATE_PLIST \
		$DOWNLOADED_PKG \
		$SQL_QUERY_FILE"
	silent rm -rf $REMOVE_LIST
}

function exit_ok() {
	delete_temporary_files
	exit 0
}

# COMMAND GET_PLIST_AND_EXIT

if [[ $COMMAND == "GET_PLIST_AND_EXIT" ]]; then
	DESTINATION="$DOWNLOADS_DIR/NvidiaUpdates.plist"
	printf '%bDownloading...%b\n' "$B" "$R"
	curl -s --connect-timeout 15 -m 45 -o "$DESTINATION" "$REMOTE_UPDATE_PLIST" \
		|| error "Couldn't get updates data from Nvidia" $?
	printf '%s\n' "$DESTINATION"
	open -R "$DESTINATION"
	exit 0
fi

# Check root

USER_ID=$(id -u)
if [[ $USER_ID != "0" ]]; then
	printf 'Run it as root: sudo %s %s' "$(basename "$0")" "$@"
	exit 0
fi

# Check SIP/file system permissions

silent touch /System || error "Is SIP enabled?" $?

function bye() {
	printf 'Complete.'
	if $PROMPT_REBOOT; then
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

function uninstall_extra() {
	local BREW_PREFIX
	BREW_PREFIX=$(brew --prefix 2> /dev/null)
	local HOST_PREFIX="/usr/local"
	local UNINSTALL_CONF="etc/webdriver.sh/uninstall.conf"
	if [[ -f "$BREW_PREFIX/$UNINSTALL_CONF" ]]; then
		"$BREW_PREFIX/$UNINSTALL_CONF"
	elif [[ -f "$HOST_PREFIX/$UNINSTALL_CONF" ]]; then
		"$HOST_PREFIX/$UNINSTALL_CONF"
	fi
}

function uninstall_drivers() {
	local EGPU_DEFAULT="/Library/Extensions/NVDAEGPUSupport.kext"
	local EGPU_RENAMED="/Library/Extensions/EGPUSupport.kext"
	local REMOVE_LIST="/Library/Extensions/GeForce* \
		/Library/Extensions/NVDA* \
		/Library/GPUBundles/GeForce*Web.bundle \
		/System/Library/Extensions/GeForce*Web* \
		/System/Library/Extensions/NVDA*Web*"
	# Remove drivers
	silent mv "$EGPU_DEFAULT" "$EGPU_RENAMED"
	silent rm -rf $REMOVE_LIST
	silent mv "$EGPU_RENAMED" "$EGPU_DEFAULT"
	uninstall_extra
}

function caches_error() {
	# caches_error $1: warning_message
	warning "$1"
	(( CACHES_ERROR = 1 ))
}

function update_caches() {
	if $NO_CACHE_UPDATE; then
		warning "Caches are not being updated"
		return 0
	fi
	printf '%bUpdating caches...%b\n' "$B" "$R"
	local PLK="Created prelinked kernel"
	local SLE="caches updated for /System/Library/Extensions"
	local LE="caches updated for /Library/Extensions"
	local RESULT
	RESULT=$(/usr/sbin/kextcache -v 2 -i / 2>&1)
	echo "$RESULT" | grep "$PLK" > /dev/null 2>&1 \
		|| caches_error "There was a problem creating the prelinked kernel"
	echo "$RESULT" | grep "$SLE" > /dev/null 2>&1 \
		|| caches_error "There was a problem updating directory caches for /S/L/E"
	echo "$RESULT" | grep "$LE" > /dev/null 2>&1 \
		|| caches_error "There was a problem updating directory caches for /L/E"
	if (( CACHES_ERROR != 0 )); then
		printf '\nTo try again use:\n%bsudo kextcache -i /%b\n\n' "$B" "$R"
		PROMPT_REBOOT=false
	fi	 
}

function ask() {
	# ask $1: message
	local INPUT=
	printf '%b%s%b' "$B" "$1" "$R"
	read -n 1 -srp " [y/N]" INPUT
	if [[ $INPUT == "y" || $INPUT == "Y" ]]; then
		printf '\n'
		return 0
	else
		exit_ok
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
	if [[ $RESULT ]]; then
		echo "$RESULT"
		return 0
	fi
	return 1
}

function sha512() {
	# checksum $1: file
	local RESULT=
	RESULT=$(/usr/bin/shasum -a 512 "$1" | awk '{print $1;}')
	if [[ $RESULT ]]; then
		printf '%s' "$RESULT"
	fi
}

function set_nvram() {
	/usr/sbin/nvram nvda_drv=1%00
}

function unset_nvram() {
	/usr/sbin/nvram -d nvda_drv
}

# COMMAND SET_REQUIRED_OS_AND_EXIT

if [[ $COMMAND == "SET_REQUIRED_OS_AND_EXIT" ]]; then
	(( ERROR = 0 ))
	MOD_INFO_PLIST_PATH="/Library/Extensions/NVDAStartupWeb.kext/Contents/Info.plist"
	EGPU_INFO_PLIST_PATH="/Library/Extensions/NVDAEGPUSupport.kext/Contents/Info.plist"
	MOD_KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
	if [[ ! -f $MOD_INFO_PLIST_PATH ]]; then
		printf 'Nvidia driver not found\n'
		(( ERROR = 1 ))
	else
		RESULT=$(plistb "Print $MOD_KEY" "$MOD_INFO_PLIST_PATH") || plist_read_error
		if [[ "$RESULT" == "$MOD_REQUIRED_OS" ]]; then
			printf 'NVDARequiredOS already set to %s\n' "$MOD_REQUIRED_OS"
		else 
			CHANGES_MADE=true
			printf '%bSetting NVDARequiredOS to %s...%b\n' "$B" "$MOD_REQUIRED_OS" "$R"
			plistb "Set $MOD_KEY $MOD_REQUIRED_OS" "$MOD_INFO_PLIST_PATH" || plist_write_error
		fi
	fi
	if [[ -f $EGPU_INFO_PLIST_PATH ]]; then
		RESULT=$(plistb "Print $MOD_KEY" "$EGPU_INFO_PLIST_PATH") || plist_read_error
		if [[ "$RESULT" == "$MOD_REQUIRED_OS" ]]; then
			printf 'Found NVDAEGPUSupport.kext, already set to %s\n' "$MOD_REQUIRED_OS"
		else
			CHANGES_MADE=true
			printf '%bFound NVDAEGPUSupport.kext, setting NVDARequiredOS to %s...%b\n' "$B" "$MOD_REQUIRED_OS" "$R"
			plistb "Set $MOD_KEY $MOD_REQUIRED_OS" "$EGPU_INFO_PLIST_PATH"  || plist_write_error
		fi
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
	bye
fi

function installed_version() {
	if [[ -f $INSTALLED_VERSION ]]; then
		GET_INFO_STRING=$(plistb "Print :CFBundleGetInfoString" "$INSTALLED_VERSION")
		GET_INFO_STRING="${GET_INFO_STRING##* }"
		echo "$GET_INFO_STRING"
	fi
}

function sql_add_kext() {
	# sql_add_kext $1:bundle_id
	printf 'insert or replace into kext_policy '
	printf '(team_id, bundle_id, allowed, developer_name, flags) '
	printf 'values (\"%s\",\"%s\",1,\"%s\",1);\n' "$SQL_TEAM_ID" "$1" "$SQL_DEVELOPER_NAME"
} >> "$SQL_QUERY_FILE"

# UPDATER/INSTALLER

delete_temporary_files

if [[ $COMMAND != "USER_PROVIDED_URL" ]]; then
	
	if [[ -z $MAC_OS_BUILD ]]; then
		error "macOS build should have been set by now"; fi

	# No URL specified, get installed web driver verison
	VERSION=$(installed_version)

	# Get updates file
	printf '%bChecking for updates...%b\n' "$B" "$R"
	curl -s --connect-timeout 15 -m 45 -o "$DOWNLOADED_UPDATE_PLIST" "$REMOTE_UPDATE_PLIST" \
		|| error "Couldn't get updates data from Nvidia" $?

	# Check for an update
	(( i = 0 ))
	while (( i < 200 )); do
		if ! REMOTE_MAC_OS_BUILD=$(plistb "Print :updates:$i:OS" "$DOWNLOADED_UPDATE_PLIST"); then
			unset REMOTE_MAC_OS_BUILD
			break
		fi
		if [[ $REMOTE_MAC_OS_BUILD == "$MAC_OS_BUILD" ]]; then
			if ! REMOTE_URL=$(plistb "Print :updates:$i:downloadURL" "$DOWNLOADED_UPDATE_PLIST"); then
				unset REMOTE_URL; fi
			if ! REMOTE_VERSION=$(plistb "Print :updates:$i:version" "$DOWNLOADED_UPDATE_PLIST"); then
				unset REMOTE_VERSION; fi
			if ! REMOTE_CHECKSUM=$(plistb "Print :updates:$i:checksum" "$DOWNLOADED_UPDATE_PLIST"); then
				unset REMOTE_CHECKSUM; fi
			break
		fi
		(( i += 1 ))
	done;
	
	# Determine next action
	if [[ -z $REMOTE_URL || -z $REMOTE_VERSION ]]; then
		# No driver available, or error during check, exit
		printf 'No driver available for %s\n' "$MAC_OS_BUILD"
		exit_ok
	elif [[ $REMOTE_VERSION == "$VERSION" ]]; then
		# Latest already installed, exit
		printf '%s for %s already installed\n' "$REMOTE_VERSION" "$MAC_OS_BUILD"
		$REINSTALL_OPTION || exit_ok
		REINSTALL_MESSAGE=true
	else
		# Found an update, proceed to installation
		printf 'Web driver %s available...\n' "$REMOTE_VERSION"
	fi

else
	
	# Invoked with -u option, proceed to installation
	printf 'URL: %s\n' "$REMOTE_URL"
	PROMPT_REBOOT=false
	
fi

# Prompt install y/n

if $REINSTALL_MESSAGE; then
	ask "Re-install?"
else
	ask "Install?"
fi

# Check URL

REMOTE_HOST=$(printf '%s' "$REMOTE_URL" | awk -F/ '{print $3}')
if ! silent /usr/bin/host "$REMOTE_HOST"; then
	if [[ $COMMAND == "USER_PROVIDED_URL" ]]; then
		error "Unable to resolve host, check your URL"; fi
	REMOTE_URL="https://images.nvidia.com/mac/pkg/${REMOTE_VERSION%%.*}/WebDriver-$REMOTE_VERSION.pkg"
fi
HEADERS=$(/usr/bin/curl -I "$REMOTE_URL" 2>&1) \
	|| error "Failed to download HTTP headers"
echo "$HEADERS" | grep "content-type: application/octet-stream" > /dev/null 2>&1 \
	|| error "Unexpected HTTP content type"
if [[ $COMMAND != "USER_PROVIDED_URL" ]]; then
	printf 'URL: %s\n' "$REMOTE_URL"; fi

# Download

printf '%bDownloading package...%b\n' "$B" "$R"
/usr/bin/curl --connect-timeout 15 -# -o "$DOWNLOADED_PKG" "$REMOTE_URL" \
	|| error "Couldn't download package" $?

# Checksum

LOCAL_CHECKSUM=$(sha512 "$DOWNLOADED_PKG")
if [[ $REMOTE_CHECKSUM ]]; then
	if [[  "$LOCAL_CHECKSUM" == "$REMOTE_CHECKSUM" ]]; then
		printf 'SHA512: Verified\n'
	else
		error "SHA512 verification failed"
	fi
else
	printf 'SHA512: %s\n' "$LOCAL_CHECKSUM"
fi


# Extract

printf '%bExtracting...%b\n' "$B" "$R"
/usr/sbin/pkgutil --expand "$DOWNLOADED_PKG" "$EXTRACTED_PKG_DIR" \
	|| error "Couldn't extract package" $?
cd "$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT" \
	|| error "Couldn't find pkgutil output directory" $?
/usr/bin/gunzip -dc < ./Payload > ./tmp.cpio \
	|| error "Couldn't extract package" $?
/usr/bin/cpio -i < ./tmp.cpio \
	|| error "Couldn't extract package" $?
if [[ ! -d ./Library/Extensions || ! -d ./System/Library/Extensions ]]; then
	error "Unexpected directory structure after extraction" 1; fi

# Make SQL

printf '%bApproving kexts...%b\n' "$B" "$R"
cd "$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT" \
	|| error "Couldn't find pkgutil output directory" $?
KEXT_INFO_PLISTS=(./Library/Extensions/*.kext/Contents/Info.plist)
for PLIST in "${KEXT_INFO_PLISTS[@]}"; do
	BUNDLE_ID=$(plistb "Print :CFBundleIdentifier" "$PLIST") || plist_read_error
	if [[ $BUNDLE_ID ]]; then
		sql_add_kext "$BUNDLE_ID"
	fi
done
sql_add_kext "com.nvidia.CUDA"

CHANGES_MADE=true

# Allow kexts

/usr/bin/sqlite3 /var/db/SystemPolicyConfiguration/KextPolicy < "$SQL_QUERY_FILE" \
	|| warning "sqlite3 exit code $?, extensions may not be loadable"

# Install

printf '%bInstalling...%b\n' "$B" "$R"
uninstall_drivers
cd "$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT" \
	|| error "Couldn't find pkgutil output directory" $?
cp -r ./Library/Extensions/* /Library/Extensions
cp -r ./System/Library/Extensions/GeForce*Web.bundle /Library/GPUBundles
cp -r ./System/Library/Extensions/* /System/Library/Extensions

# Update caches and exit

update_caches
set_nvram
delete_temporary_files
bye
