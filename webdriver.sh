#!/bin/bash
#
# webdriver.sh - bash script for managing Nvidia's web drivers
# Copyright © 2017 vulgo
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

VERSION="1.0.7"

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
REINSTALL=false
DOWNLOADED_UPDATE_PLIST="$DOWNLOADS_DIR/.nvwebupdates.plist"
DOWNLOADED_PKG="$DOWNLOADS_DIR/.nvweb.pkg"
EXTRACTED_PKG_DIR="$DOWNLOADS_DIR/.nvwebinstall"
SQL_QUERY_FILE="$DOWNLOADS_DIR/.nvweb.sql"
SQL_DEVELOPER_NAME="NVIDIA Corporation"
SQL_TEAM_ID="6KR3T733EC"
INSTALLED_VERSION="/Library/Extensions/GeForceWeb.kext/Contents/Info.plist"
DRIVERS_DIR_HINT="NVWebDrivers.pkg"
BREW_PREFIX=$(brew --prefix 2> /dev/null)
(( CACHES_ERROR = 0 ))
(( COMMAND_COUNT = 0 ))

function usage {
	echo "Usage: $(basename "$0") [-f] [-c] [-h|-p|-r|-u url|-m [build]]"
	echo "          -f            re-install"
        echo "          -c            don't update caches"
	echo "          -h            print usage and exit"
	echo "          -p            download the updates property list and exit"
	echo "          -r            uninstall Nvidia web drivers"
	echo "          -u url        install driver package at url, no version checks"
	echo "          -m [build]    modify the current driver's NVDARequiredOS"
}

function version {
	echo "webdriver.sh $VERSION Copyright © 2017-2018 vulgo"
	echo "This is free software: you are free to change and redistribute it."
	echo "There is NO WARRANTY, to the extent permitted by law."
	echo "See the GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>"
}

while getopts ":hvpu:rm:cf" OPTION; do
	if [ "$OPTION" = "h" ]; then
		usage
		exit 0
	elif [ "$OPTION" = "v" ]; then
		version
		exit 0
	elif [ "$OPTION" = "p" ]; then
		COMMAND="GET_PLIST_AND_EXIT"
		(( COMMAND_COUNT += 1 ))
	elif [ "$OPTION" = "u" ]; then
		COMMAND="USER_PROVIDED_URL"
		REMOTE_URL="$OPTARG"
		(( COMMAND_COUNT += 1 ))
	elif [ "$OPTION" = "r" ]; then
		COMMAND="UNINSTALL_DRIVERS_AND_EXIT"
		(( COMMAND_COUNT += 1 ))
	elif [ "$OPTION" = "m" ]; then
		MOD_REQUIRED_OS="$OPTARG"
		COMMAND="SET_REQUIRED_OS_AND_EXIT"
		(( COMMAND_COUNT += 1 ))
	elif [ "$OPTION" = "c" ]; then
		NO_CACHE_UPDATE=true
		PROMPT_REBOOT=false
	elif [ "$OPTION" = "f" ]; then
		REINSTALL=true
	elif [ "$OPTION" = "?" ]; then
		printf 'Invalid option: -%s\n' "$OPTARG"
		usage
		exit 1
	elif [ "$OPTION" = ":" ]; then
		if [ "$OPTARG" = "m" ]; then
			MOD_REQUIRED_OS="$MAC_OS_BUILD"
			COMMAND="SET_REQUIRED_OS_AND_EXIT"
			(( COMMAND_COUNT += 1 ))
		else
			printf 'Missing parameter\n'
			usage
			exit 1
		fi
	fi
	if (( COMMAND_COUNT > 1)); then
		printf 'Too many options\n'
		usage
		exit 1
	fi
done

function silent {
	"$@" > /dev/null 2>&1
}

function error {
	# error message exit_code
	delete_temporary_files
	printf 'Error: %s (%s)\n' "$1" "$2"
	if $CHANGES_MADE; then
		unset_nvram
	else
		printf 'No changes were made\n'
	fi
	exit 1
}

function delete_temporary_files {
	silent rm -rf "$EXTRACTED_PKG_DIR"
	silent rm -f "$DOWNLOADED_PKG"
	silent rm -f "$SQL_QUERY_FILE"
	silent rm -f "$DOWNLOADED_UPDATE_PLIST"
}

function exit_ok {
	delete_temporary_files
	exit 0
}

# COMMAND GET_PLIST_AND_EXIT

if [ "$COMMAND" = "GET_PLIST_AND_EXIT" ]; then
	DESTINATION="$DOWNLOADS_DIR/NvidiaUpdates.plist"
	printf 'Downloading %s\n' "$DESTINATION"
	curl -s --connect-timeout 15 -m 45 -o "$DESTINATION" "$REMOTE_UPDATE_PLIST" \
		|| error "Couldn't get updates data from Nvidia" $?
	open -R "$DESTINATION"
	exit 0
fi

# Check root

if [ "$(id -u)" != "0" ]; then
	printf 'Run it as root: sudo %s %s' "$(basename "$0")" "$@"
	exit 0
fi

# Check SIP/file system permissions

silent touch /System || error "Is SIP enabled?" $?


function bye {
	printf "Complete."
	if $PROMPT_REBOOT; then
		printf ' You should reboot now.\n'
	else
		printf '\n'
	fi
	exit $CACHES_ERROR
}

function warning {
	# warning message
	printf 'Warning: %s\n' "$1"
}

function uninstall_drivers {
	# Remove drivers
	silent mv /Library/Extensions/NVDAEGPUSupport.kext /Library/Extensions/EGPUSupport.kext
	silent rm -rf /Library/Extensions/GeForce*
	silent rm -rf /Library/Extensions/NVDA*
	silent rm -rf /Library/GPUBundles/GeForce*Web.bundle
	silent rm -rf /System/Library/Extensions/GeForce*Web*
	silent rm -rf /System/Library/Extensions/NVDA*Web*
	silent mv /Library/Extensions/EGPUSupport.kext /Library/Extensions/NVDAEGPUSupport.kext
	if [ -f "$BREW_PREFIX/etc/webdriver.sh/uninstall.conf" ]; then
		"$BREW_PREFIX/etc/webdriver.sh/uninstall.conf"
	elif [ -f /usr/local/etc/webdriver.sh/uninstall.conf ]; then
		/usr/local/etc/webdriver.sh/uninstall.conf
	fi
}

function update_caches {
	if $NO_CACHE_UPDATE; then
		warning "Caches are not being updated"
		return 0
	fi
	printf 'Updating caches...\n'
	KERNEL_CACHE=$(/usr/sbin/kextcache -v 2 -i / 2>&1)
	if ! echo "$KERNEL_CACHE" | grep "Created prelinked kernel" > /dev/null 2>&1; then
		warning "There was a problem creating the prelinked kernel"
		(( CACHES_ERROR = 1 ))
	fi
	if ! echo "$KERNEL_CACHE" | grep "caches updated for /System/Library/Extensions" > /dev/null 2>&1; then
		warning "There was a problem updating directory caches for /System/Library/Extensions"
		(( CACHES_ERROR = 1 ))
	fi
	if ! echo "$KERNEL_CACHE" | grep "caches updated for /Library/Extensions" > /dev/null 2>&1; then
		warning "There was a problem updating directory caches for /Library/Extensions"
		(( CACHES_ERROR = 1 ))
	fi
	if (( CACHES_ERROR != 0 )); then
		printf '\nTo try again use:\nsudo kextcache -i /\n\n'
		PROMPT_REBOOT=false
	fi	 
}

function ask {
	printf "%s" "$1"
	read -n 1 -srp " [y/N]" INPUT
	if [ "$INPUT" = "y" ] || [ "$INPUT" = "Y" ]; then
		printf '\n'
		return 1
	else
		exit_ok
	fi
}

function plistb {
	# plistb command file fatal
	if ! /usr/libexec/PlistBuddy -c "$1" "$2" 2> /dev/null; then
		if $3; then
			error "PlistBuddy error treated as fatal" $?
		fi
	fi
}

function set_nvram {
	/usr/sbin/nvram nvda_drv=1%00
}

function unset_nvram {
	/usr/sbin/nvram -d nvda_drv
}

# COMMAND SET_REQUIRED_OS_AND_EXIT

if [ "$COMMAND" = "SET_REQUIRED_OS_AND_EXIT" ]; then
	MOD_INFO_PLIST_PATH="/Library/Extensions/NVDAStartupWeb.kext/Contents/Info.plist"
	EGPU_INFO_PLIST_PATH="/Library/Extensions/NVDAEGPUSupport.kext/Contents/Info.plist"
	MOD_KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
	if [ -f "$MOD_INFO_PLIST_PATH" ]; then
		CHANGES_MADE=true
		printf 'Setting NVDARequiredOS to %s...\n' "$MOD_REQUIRED_OS"
		plistb "Set $MOD_KEY $MOD_REQUIRED_OS" "$MOD_INFO_PLIST_PATH" true
		if [ -f "$EGPU_INFO_PLIST_PATH" ]; then
			printf 'Found NVDAEGPUSupport.kext, setting NVDARequiredOS to %s...\n' "$MOD_REQUIRED_OS"
			plistb "Set $MOD_KEY $MOD_REQUIRED_OS" "$EGPU_INFO_PLIST_PATH" true
		fi
		update_caches
		set_nvram
		bye
	else
		error "$MOD_INFO_PLIST_PATH not found" 2
	fi
fi

# COMMAND UNINSTALL_DRIVERS_AND_EXIT

if [ "$COMMAND" = "UNINSTALL_DRIVERS_AND_EXIT" ]; then
	ask "Uninstall Nvidia web drivers?"
	printf 'Removing files...\n'
	CHANGES_MADE=true
	uninstall_drivers
	update_caches
	unset_nvram
	bye
fi

function installed_version {
	if [ -f $INSTALLED_VERSION ]; then
		GET_INFO_STRING=$(plistb "Print :CFBundleGetInfoString" "$INSTALLED_VERSION" false)
		GET_INFO_STRING="${GET_INFO_STRING##* }"
		echo "$GET_INFO_STRING";
	else
		echo "none"
	fi
}

function sql_add_kext {
	printf 'insert or replace into kext_policy '
	printf '(team_id, bundle_id, allowed, developer_name, flags) '
	printf 'values (\"%s\",\"%s\",1,\"%s\",1);\n' "$SQL_TEAM_ID" "$1" "$SQL_DEVELOPER_NAME"
} >> "$SQL_QUERY_FILE"

# UPDATER/INSTALLER

delete_temporary_files

if [ "$COMMAND" != "USER_PROVIDED_URL" ]; then

	# No URL specified, get installed web driver verison

	VERSION=$(installed_version)

	# Get updates file

	printf 'Checking for updates...\n'
	curl -s --connect-timeout 15 -m 45 -o "$DOWNLOADED_UPDATE_PLIST" "$REMOTE_UPDATE_PLIST" \
		|| error "Couldn't get updates data from Nvidia" $?

	# Check for an update

	(( i = 0 ))
	while true; do
		if ! REMOTE_MAC_OS_BUILD=$(plistb "Print :updates:$i:OS" "$DOWNLOADED_UPDATE_PLIST" false); then
			REMOTE_MAC_OS_BUILD="none"
			REMOTE_URL="none"
			REMOTE_VERSION="none"
			break
		fi
		if [ "$REMOTE_MAC_OS_BUILD" = "$MAC_OS_BUILD" ]; then
			if ! REMOTE_URL=$(plistb "Print :updates:$i:downloadURL" "$DOWNLOADED_UPDATE_PLIST" false); then
				REMOTE_URL="none"; fi
			if ! REMOTE_VERSION=$(plistb "Print :updates:$i:version" "$DOWNLOADED_UPDATE_PLIST" false); then
				REMOTE_VERSION="none"; fi
			break
		fi
		if (( i > 200 )); then
			REMOTE_MAC_OS_BUILD="none"
			REMOTE_URL="none"
			REMOTE_VERSION="none"
			break;
		fi
		(( i += 1 ))
	done;

	# Determine next action

	if [ "$REMOTE_URL" = "none" ] || [ "$REMOTE_VERSION" = "none" ]; then
		# no driver available, or error during check, exit
		printf 'No driver available for %s\n' "$MAC_OS_BUILD"
		exit_ok
	elif [ "$REMOTE_VERSION" = "$VERSION" ]; then
		# latest already installed, exit
		printf '%s for %s already installed\n' "$REMOTE_VERSION" "$MAC_OS_BUILD"
		$REINSTALL || exit_ok
	else
		# found an update, proceed to installation
		printf 'Web driver %s available...\n' "$REMOTE_VERSION"
	fi

else

	# invoked with -u option, proceed to installation

	printf 'User provided URL: %s\n' "$REMOTE_URL"
	PROMPT_REBOOT=false

fi

# Start

if $REINSTALL; then
	ask "Re-install?"
else
	ask "Install?"
fi

# Check URL

REMOTE_HOST=$(printf '%s' "$REMOTE_URL" | awk -F/ '{print $3}')
if ! silent /usr/bin/host "$REMOTE_HOST"; then
	if [ "$COMMAND" = "USER_PROVIDED_URL" ]; then
		error "Unable to resolve host, check your URL" 400; fi
	REMOTE_URL="https://images.nvidia.com/mac/pkg/${REMOTE_VERSION%%.*}/WebDriver-$REMOTE_VERSION.pkg"
fi
silent /usr/bin/curl -I $REMOTE_URL \
	|| error "Error downloading package headers" $?
if [ "$COMMAND" != "USER_PROVIDED_URL" ]; then
	printf 'Using URL: %s\n' "$REMOTE_URL"; fi

# Download

printf 'Downloading package...\n'
/usr/bin/curl --connect-timeout 15 -# -o "$DOWNLOADED_PKG" "$REMOTE_URL" \
	|| error "Couldn't download package" $?

# Extract

printf 'Extracting...\n'
/usr/sbin/pkgutil --expand "$DOWNLOADED_PKG" "$EXTRACTED_PKG_DIR" \
	|| error "Couldn't extract package" $?
cd "$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT" \
	|| error "Couldn't find pkgutil output directory" $?
/usr/bin/gunzip -dc < ./Payload > ./tmp.cpio \
	|| error "Couldn't extract package" $?
/usr/bin/cpio -i < ./tmp.cpio \
	|| error "Couldn't extract package" $?
if [ ! -d ./Library/Extensions ] || [ ! -d ./System/Library/Extensions ]; then
	error "Unexpected directory structure after extraction" 1; fi

# Make SQL

printf 'Approving kexts...\n'
cd "$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT" \
	|| error "Couldn't find pkgutil output directory" $?
KEXT_INFO_PLISTS=(./Library/Extensions/*.kext/Contents/Info.plist)
for PLIST in "${KEXT_INFO_PLISTS[@]}"; do
	if [ -f "$PLIST" ]; then
		BUNDLE_ID=$(plistb "Print :CFBundleIdentifier" "$PLIST" true)
		sql_add_kext "$BUNDLE_ID"
	fi
done
sql_add_kext "com.nvidia.CUDA"

CHANGES_MADE=true

# Allow kexts

/usr/bin/sqlite3 /var/db/SystemPolicyConfiguration/KextPolicy < "$SQL_QUERY_FILE" \
	|| warning "sqlite3 exit code $?, extensions may not be loadable"

# Install

printf 'Installing...\n'
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
