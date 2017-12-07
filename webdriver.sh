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

/usr/bin/sw_vers -productVersion | grep "10.13" > /dev/null 2>&1
if [ $? -ne 0 ]; then
	printf "Unsupported macOS version"
	exit 1
fi

MAC_OS_BUILD=$(/usr/bin/sw_vers -buildVersion)
DOWNLOADS_DIR=~/Downloads
REMOTE_UPDATE_PLIST="https://gfestage.nvidia.com/mac-update"
CHANGES_MADE=false
PROMPT_REBOOT=true
NO_CACHE_UPDATE=false
REINSTALL=false

function usage {
	echo "Usage: "$(basename $0)" [-f] [-c] [-p|-r|-u url|-m [build]]"
	echo "          -f            Re-install"
        echo "          -c            Don't update caches"
	echo "          -p            Get the updates plist and exit"
	echo "          -r            Un-install Nvidia web drivers"
	echo "          -u url        Install driver package at url, no version checks"
	echo "          -m [build]    Modify the current driver's NVDARequiredOS"
}

let COMMAND_COUNT=0; while getopts ":hpu:rm:cf" OPTION; do
	if [ "$OPTION" = "h" ]; then
		usage
		exit 0
	elif [ "$OPTION" = "p" ]; then
		COMMAND="GET_PLIST_AND_EXIT"
		let COMMAND_COUNT+=1
	elif [ "$OPTION" = "u" ]; then
		COMMAND="USER_PROVIDED_URL"
		REMOTE_URL="$OPTARG"
		let COMMAND_COUNT+=1
	elif [ "$OPTION" = "r" ]; then
		COMMAND="UNINSTALL_DRIVERS_AND_EXIT"
		let COMMAND_COUNT+=1
	elif [ "$OPTION" = "m" ]; then
		MOD_REQUIRED_OS="$OPTARG"
		COMMAND="SET_REQUIRED_OS_AND_EXIT"
		let COMMAND_COUNT+=1
	elif [ "$OPTION" = "c" ]; then
		NO_CACHE_UPDATE=true
		PROMPT_REBOOT=false
	elif [ "$OPTION" = "f" ]; then
		REINSTALL=true
	elif [ "$OPTION" = "?" ]; then
		printf "Invalid option: -$OPTARG\n"
		usage
		exit 1
	elif [ "$OPTION" = ":" ]; then
		if [ $OPTARG = "m" ]; then
			MOD_REQUIRED_OS="$MAC_OS_BUILD"
			COMMAND="SET_REQUIRED_OS_AND_EXIT"
			let COMMAND_COUNT+=1
		else
			printf "Missing parameter\n"
			usage
			exit 1
		fi
	fi
	if [ $COMMAND_COUNT -gt 1 ]; then
		printf "Too many options\n"
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
	printf "Error: $1 ($2)\n"
	if [ $CHANGES_MADE = false ]; then
		printf "No changes were made\n"
	else
		unset_nvram
	fi
	exit 1
}

function on_error {
	# on_error message exit_code
	if [ $2 -ne 0 ]; then
		error "$1" $2
	fi
}

# COMMAND GET_PLIST_AND_EXIT

if [ "$COMMAND" = "GET_PLIST_AND_EXIT" ]; then
	DESTINATION="$DOWNLOADS_DIR/NvidiaUpdates.plist"
	printf "Downloading '$DESTINATION'\n"
	curl --connect-timeout 15 -s -m 45 -o "$DESTINATION" "$REMOTE_UPDATE_PLIST"
	on_error "Couldn't get updates data from Nvidia" $?
	open -R "$DESTINATION"
	exit 0
fi

# Check root

if [ "$(id -u)" != "0" ]; then
	printf "Run it as root: sudo $(basename $0) $@"
	exit 0
fi

# Check SIP/file system permissions

silent touch /System
on_error "Is SIP enabled?" $?

#

function bye {
	printf "Complete."
	if [ $PROMPT_REBOOT = true ]; then
		printf " You should reboot now.\n"
	else
		printf "\n"
	fi
	exit 0
}

function delete_temporary_files {
	silent rm -rf "$EXTRACTED_PKG_DIR"
	silent rm -f "$DOWNLOADED_PKG"
	silent rm -f "$SQL_QUERY_FILE"
	silent rm -f "$DOWNLOADED_UPDATE_PLIST"
}

function warning {
	# warning message
	printf "Warning: $1\n"
}

function uninstall_drivers {
	# Remove drivers
	silent rm -rf /Library/Extensions/GeForce*
	silent rm -rf /Library/Extensions/NVDA*
	silent rm -rf /System/Library/Extensions/GeForce*Web*
	silent rm -rf /System/Library/Extensions/NVDA*Web*
	# Un-comment the following lines to remove monitor preferences
	# silent rm -f /Users/*/Library/Preferences/ByHost/com.apple.windowserver*
	# silent rm -f ~/Library/Preferences/ByHost/com.apple.windowserver*
	# Un-comment the following lines to remove additional files
	# silent launchctl unload /Library/LaunchDaemons/com.nvidia.nvroothelper.plist
	# silent rm -f /Library/LaunchDaemons/com.nvidia.nvroothelper.plist
	# silent rm -f /Library/LaunchAgents/com.nvidia.nvagent.plist
	# silent rm -rf '/Library/PreferencePanes/NVIDIA Driver Manager.prefPane'
}

function update_caches {
	if [ $NO_CACHE_UPDATE = true ]; then
		warning "Caches are not being updated"
		return 0
	fi
	printf "Updating caches...\n"
	/usr/bin/touch /Library/Extensions /System/Library/Extensions
	/usr/sbin/kextcache -u /
	on_error "Couldn't update caches" $?
}

function ask {
	printf "$1"
	read -n 1 -s -r -p " [y/N]" INPUT
	if [ "$INPUT" = "y" ] || [ "$INPUT" = "Y" ]; then
		printf "\n"
		return 1
	else
		delete_temporary_files
		exit 0
	fi
}

function plistb {
	# plistb command file fatal
	/usr/libexec/PlistBuddy -c "$1" "$2" 2> /dev/null
	if [ $? -ne 0 ] && [ $3 = true ]; then
		error "PlistBuddy error treated as fatal" $?
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
	MOD_KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
	if [ -f "$MOD_INFO_PLIST_PATH" ]; then
		CHANGES_MADE=true
		printf "Setting NVDARequiredOS to $MOD_REQUIRED_OS...\n"
		plistb "Set $MOD_KEY $MOD_REQUIRED_OS" "$MOD_INFO_PLIST_PATH" true
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
	printf "Removing files...\n"
	CHANGES_MADE=true
	uninstall_drivers
	update_caches
	unset_nvram
	bye
fi

# UPDATER/INSTALLER

DOWNLOADED_UPDATE_PLIST="$DOWNLOADS_DIR/.nvwebupdates.plist"
DOWNLOADED_PKG="$DOWNLOADS_DIR/.nvweb.pkg"
EXTRACTED_PKG_DIR="$DOWNLOADS_DIR/.nvwebinstall"
SQL_QUERY_FILE="$DOWNLOADS_DIR/.nvweb.sql"
SQL_DEVELOPER_NAME="NVIDIA Corporation"
SQL_TEAM_ID="6KR3T733EC"
INSTALLED_VERSION="/Library/Extensions/GeForceWeb.kext/Contents/Info.plist"
DRIVERS_DIR_HINT="NVWebDrivers.pkg"

function installed_version {
	if [ -f $INSTALLED_VERSION ]; then
		GET_INFO_STRING=$(plistb "Print :CFBundleGetInfoString" "$INSTALLED_VERSION" false)
		GET_INFO_STRING="${GET_INFO_STRING##* }"
		# check version string is the format we expect
		TEST="${GET_INFO_STRING//[^.]}"  # get . characters
		TEST="${#TEST}"  # how many?
		if [ "$TEST" = "5" ]; then
			# 5 dots is ok
			echo "$GET_INFO_STRING";
			exit 0
		fi
	fi
	echo "none"
}

function sql_add_kext {
	printf "insert or replace into kext_policy " >> "$SQL_QUERY_FILE"
	printf "(team_id, bundle_id, allowed, developer_name, flags) " >> "$SQL_QUERY_FILE"
	printf "values (\"$SQL_TEAM_ID\",\"$1\",1,\"$SQL_DEVELOPER_NAME\",1);\n" >> "$SQL_QUERY_FILE"
}

delete_temporary_files

if [ "$COMMAND" != "USER_PROVIDED_URL" ]; then

	# No URL specified, get installed web driver verison

	VERSION=$(installed_version)

	# Get updates file

	printf 'Checking for updates...\n'
	curl --connect-timeout 15 -s -m 45 -o "$DOWNLOADED_UPDATE_PLIST" "$REMOTE_UPDATE_PLIST"
	on_error "Couldn't get updates data from Nvidia" $?

	# Check for an update

	let i=0
	while true; do
		REMOTE_MAC_OS_BUILD=$(plistb "Print :updates:$i:OS" "$DOWNLOADED_UPDATE_PLIST" false)
		if [ $? -ne 0 ]; then
			REMOTE_MAC_OS_BUILD="none"
			REMOTE_URL="none"
			REMOTE_VERSION="none"
			break
		fi
		if [ "$REMOTE_MAC_OS_BUILD" = "$MAC_OS_BUILD" ]; then
			REMOTE_URL=$(plistb "Print :updates:$i:downloadURL" "$DOWNLOADED_UPDATE_PLIST" false)
			if [ $? -ne 0 ]; then
				REMOTE_URL="none"; fi
			REMOTE_VERSION=$(plistb "Print :updates:$i:version" "$DOWNLOADED_UPDATE_PLIST" false)
			if [ $? -ne 0 ]; then
				REMOTE_VERSION="none"; fi
			break
		fi
		let i+=1
	done;

	# Determine next action

	if [ "$REMOTE_URL" = "none" ] || [ "$REMOTE_VERSION" = "none" ]; then
		# no driver available, or error during check, exit
		printf "No driver available for $MAC_OS_BUILD\n"
		delete_temporary_files
		exit 0
	elif [ "$REMOTE_VERSION" = "$VERSION" ]; then
		# latest already installed, exit
		printf "$REMOTE_VERSION for $MAC_OS_BUILD already installed\n"
		if [ $REINSTALL = true ]; then
			:
		else
			delete_temporary_files
			exit 0
		fi
	else
		# found an update, proceed to installation
		printf "Web driver $REMOTE_VERSION available...\n"
	fi

else

	# invoked with -u option, proceed to installation

	printf "User provided URL: $REMOTE_URL\n"
	PROMPT_REBOOT=false

fi

# Start

if [ $REINSTALL = true ]; then
	ask "Re-install?"
else
	ask "Install?"
fi

# Download

printf "Downloading package...\n"
/usr/bin/curl --connect-timeout 15 -# -o "$DOWNLOADED_PKG" "$REMOTE_URL"
on_error "Couldn't download package" $?

# Extract

printf "Extracting...\n"
/usr/sbin/pkgutil --expand "$DOWNLOADED_PKG" "$EXTRACTED_PKG_DIR"
cd "$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT"
cat Payload | gunzip -dc | cpio -i
on_error "Couldn't extract package" $?

# Make SQL

printf "Approving kexts...\n"
cd "$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT"
KEXT_INFO_PLISTS=(./Library/Extensions/*.kext/Contents/Info.plist)
for PLIST in "${KEXT_INFO_PLISTS[@]}"; do
	BUNDLE_ID=$(plistb "Print :CFBundleIdentifier" "$PLIST" true)
	sql_add_kext "$BUNDLE_ID"
done
sql_add_kext "com.nvidia.CUDA"

CHANGES_MADE=true

# Allow kexts

/usr/bin/sqlite3 /var/db/SystemPolicyConfiguration/KextPolicy < "$SQL_QUERY_FILE"
if [ $? -ne 0 ]; then
	warning "sqlite3 exit code $?, extensions may not be loadable"; fi

# Install

printf "Installing...\n"
uninstall_drivers
cd "$EXTRACTED_PKG_DIR"/*"$DRIVERS_DIR_HINT"
cp -r ./Library/Extensions/* /Library/Extensions
cp -r ./System/Library/Extensions/* /System/Library/Extensions

# Update caches and exit

update_caches
set_nvram
delete_temporary_files
bye
