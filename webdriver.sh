#!/bin/bash
#
# webdriver.sh - bash script for managing Nvidia's web drivers
# Copyright (C) 2017 vulgo
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

BUILD=$(/usr/bin/sw_vers -buildVersion)

function usage {
	echo "Usage: "$(basename $0)" [-f] [-c] [-p|-r|-u url|-m [build]]"
	echo "          -f            Re-install"
        echo "          -c            Don't update caches"
	echo "          -p            Get the updates plist and exit"
	echo "          -r            Un-install Nvidia web drivers"
	echo "          -u url        Install driver package at url, no version checks"
	echo "          -m [build]    Modify the current driver's NVDARequiredOS"
}

PROMPT_REBOOT=true
NO_CACHE=false
REINSTALL=false
let N=0
while getopts ":hpu:rm:cf" OPTION; do
	if [ "$OPTION" == "h" ]; then
		usage
		exit 0
	elif [ "$OPTION" == "p" ]; then
		FUNC="plist"
		let N+=1
	elif [ "$OPTION" == "u" ]; then
		FUNC="url"
		U_URL=$OPTARG
		let N+=1
	elif [ "$OPTION" == "r" ]; then
		FUNC="remove"
		let N+=1
	elif [ "$OPTION" == "m" ]; then
		MOD_VER_STR=$OPTARG
		FUNC="mod"
		let N+=1
	elif [ "$OPTION" == "c" ]; then
		NO_CACHE=true
		PROMPT_REBOOT=false
	elif [ "$OPTION" == "f" ]; then
		REINSTALL=true
	elif [ "$OPTION" == "?" ]; then
		printf "Invalid option: -$OPTARG\n"
		usage
		exit 1
	elif [ "$OPTION" == ":" ]; then
		if [ $OPTARG == "m" ]; then
			MOD_VER_STR=$BUILD
			FUNC="mod"
			let N+=1
		else
			printf "Missing parameter\n"
			usage
			exit 1
		fi
	fi
done
if [ $N -gt 1 ]; then
	printf "Too many options\n"
	usage
	exit 1
fi

DIR=~/Downloads
UPDATE_PLIST="$DIR/NvidiaUpdates.plist"
PKG_DST="$DIR/.nvweb.pkg"
PKG_DIR="$DIR/.nvwebinstall"
SQL_TMP="$DIR/.nvweb.sql"
UPDATE_PLIST_REMOTE="https://gfestage.nvidia.com/mac-update"
CHECK_INSTALLED_VERSION="/Library/Extensions/GeForceWeb.kext"
MOD_PATH="/Library/Extensions/NVDAStartupWeb.kext/Contents/Info.plist"
MOD_KEY=":IOKitPersonalities:NVDAStartup:NVDARequiredOS"
DRIVERS_DIR_HINT="NVWebDrivers.pkg"
DEVELOPER_NAME="NVIDIA Corporation"
TEAM_ID="6KR3T733EC"
CHANGES_MADE=false

# Functions

function bye {
	printf "Complete."
	if $PROMPT_REBOOT; then
		printf " You should reboot now.\n"
	else
		printf "\n"
	fi
	exit 0
}

function silent {
	"$@" > /dev/null 2>&1
}

function clean {
	silent rm -rf $PKG_DIR
	silent rm -f $PKG_DST
	silent rm -f $SQL_TMP
	# silent rm -f $UPDATE_PLIST
}

function error {
	# error message exit_code
	clean
	printf "Error: $1"
	if [ $2 -ne 0 ]; then
		printf "($2)"; fi
	printf "\n"
	if [ $CHANGES_MADE == false ]; then
		printf "No changes were made\n"; fi
	exit 1
}

function warning {
	# warning message
	printf "Warning: $1\n"
}

function on_error {
	# on_error message exit_code
	if [ $2 -ne 0 ]; then
		error "$1" $2
	fi
}

function remove {
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

function caches {
	if $NO_CACHE; then
		warning "Caches are not being updated"
		return 0
	fi
	printf "Updating caches...\n"
	/usr/bin/touch /Library/Extensions /System/Library/Extensions
	/usr/sbin/kextcache -u /
	on_error "Couldn't update caches" $?
}

function sql_add_kext {
	printf "insert or replace into kext_policy " >> $SQL_TMP
	printf "(team_id, bundle_id, allowed, developer_name, flags) " >> $SQL_TMP
	printf "values (\"$TEAM_ID\",\"$1\",1,\"$DEVELOPER_NAME\",1);\n" >> $SQL_TMP
}

function ask {
	printf $1
	read -n 1 -s -r -p " [y/N]" input
	case "$input" in
	y|Y )
		printf "\n"
		return 1 ;;
	*)
		clean
		exit 0 ;;
	esac
}

function installed_version {
	INFO_PLIST="$CHECK_INSTALLED_VERSION/Contents/Info.plist"
	if [ -f $INFO_PLIST ]; then
		GETINFO=$(plistb "Print :CFBundleGetInfoString" $INFO_PLIST false)
		GETINFO="${GETINFO##* }"
		# check version string is the format we expect
		COUNT="${GETINFO//[^.]}"  # get . characters
		COUNT="${#COUNT}"  # how many?
		if [ "$COUNT" == "5" ]; then
			# 5 dots is ok
			echo "$GETINFO";
			exit 0
		fi
	fi
	echo "none"
}

function plistb {
	# plistb command file fatal
	/usr/libexec/PlistBuddy -c "$1" "$2" 2> /dev/null
	if [ $? -ne 0 ] && [ $3 == true ]; then
		error "plistbuddy" $?
	fi
}

# getopts -p -> get the plist then exit

if [ "$FUNC" == "plist" ]; then
	printf "Downloading '$UPDATE_PLIST'\n"
	curl -o "$UPDATE_PLIST" -# $UPDATE_PLIST_REMOTE
	on_error "Couldn't get updates data from Nvidia" $?
	open -R "$UPDATE_PLIST"
	exit 0
fi

# Check root

if [ "$(id -u)" != "0" ]; then
	error "Run it as root: sudo $(basename $0) $@" 0; fi

# Check SIP

CSRUTIL=$(/usr/bin/csrutil status)
P="Filesystem Protections: disabled|System Integrity Protection status: disabled."
silent /usr/bin/grep -E "$P" <<< "$CSRUTIL"
on_error "Is SIP enabled?" $?

# getopts -m -> modify NVDARequireOS then exit

if [ "$FUNC" == "mod" ]; then
	if [ -f "$MOD_PATH" ]; then
		CHANGES_MADE=true
		printf "Setting NVDARequiredOS to $MOD_VER_STR...\n"
		plistb "Set $MOD_KEY $MOD_VER_STR" "$MOD_PATH" true
		caches
		exit 0
	else
		error "$MOD_PATH not found" 0
	fi
fi

# getopts -r -> uninstall then exit

if [ "$FUNC" == "remove" ]; then
	ask "Uninstall Nvidia web drivers?"
	printf "Removing files...\n"
	CHANGES_MADE=true
	remove
	caches
	bye
fi

# Clean

clean

if [ "$FUNC" != "url" ]; then

	# No URL specified, get installed web driver verison

	VER=$(installed_version)

	# Get updates file

	printf 'Checking for updates...\n'
	curl -o $UPDATE_PLIST -s $UPDATE_PLIST_REMOTE
	on_error "Couldn't get updates data from Nvidia" $?

	# Check for an update

	let i=0
	while true; do
		U_BUILD=$(plistb "Print :updates:$i:OS" "$UPDATE_PLIST" false)
		if [ $? -ne 0 ]; then
			U_BUILD="none"
			U_URL="none"
			U_VER="none"
			break
		fi
		if [ "$U_BUILD" == "$BUILD" ]; then
			U_URL=$(plistb "Print :updates:$i:downloadURL" "$UPDATE_PLIST" false)
			if [ $? -ne 0 ]; then
				U_URL="none"; fi
			U_VER=$(plistb "Print :updates:$i:version" "$UPDATE_PLIST" false)
			if [ $? -ne 0 ]; then
				U_VER="none"; fi
			break
		fi
		let i+=1
	done;

	# Determine next action

	if [ "$U_URL" == "none" ] || [ "$U_VER" == "none" ]; then
		# no driver available, or error during check, exit
		printf "No driver available for $BUILD\n"
		clean
		exit 0
	elif [ "$U_VER" == "$VER" ]; then
		# latest already installed, exit
		printf "$VER for $BUILD already installed\n"
		if $REINSTALL; then
			:
		else
			clean
			exit 0
		fi
	else
		# found an update, proceed to installation
		printf "Web driver $U_VER available...\n"
	fi

else

	# invoked with -u option, proceed to installation

	printf "User provided URL: $U_URL\n"
	PROMPT_REBOOT=false

fi

# Start

if [ $REINSTALL == true ]; then
	ask "Re-install?"
else
	ask "Install?"
fi

# Download

printf "Downloading package...\n"
/usr/bin/curl -o $PKG_DST -# $U_URL
on_error "Couldn't download package" $?

# Extract

printf "Extracting...\n"
/usr/sbin/pkgutil --expand $PKG_DST $PKG_DIR
cd $PKG_DIR/*$DRIVERS_DIR_HINT
cat Payload | gunzip -dc | cpio -i
on_error "Couldn't extract package" $?

# Make SQL

printf "Approving kexts...\n"
cd $PKG_DIR/*$DRIVERS_DIR_HINT
KEXTS=(./Library/Extensions/*kext/)
for KEXT in "${KEXTS[@]}"; do
	PLIST="$KEXT/Contents/Info.plist"
	BUNDLE_ID=$(plistb "Print :CFBundleIdentifier" $PLIST true)
	sql_add_kext "$BUNDLE_ID"
done
sql_add_kext "com.nvidia.CUDA"

CHANGES_MADE=true

# Allow kexts

/usr/bin/sqlite3 /var/db/SystemPolicyConfiguration/KextPolicy < $SQL_TMP
if [ $? -ne 0 ]; then
	warning "sqlite3 exit code $?, extensions may not be loadable"; fi

# Install

printf "Installing...\n"
remove
cd $PKG_DIR/*$DRIVERS_DIR_HINT
cp -r ./Library/Extensions/* /Library/Extensions
cp -r ./System/Library/Extensions/* /System/Library/Extensions

# Update caches and exit

caches
clean
bye
