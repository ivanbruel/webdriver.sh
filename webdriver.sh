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

/usr/bin/sw_vers | grep "10.13" > /dev/null 2>&1
if [ $? -ne 0 ]; then
	printf "Unsupported macOS version"
	exit 1
fi

TMP=$(/usr/bin/sw_vers | grep BuildVersion)
BUILD=${TMP:(-5)}

function usage {
	echo ""
	echo "   "`basename "$0"`" [options]"
	echo ""
	echo "          -p            Just get the updates plist"
	echo ""
	echo "          -u <url>      Use driver package at <url>, no version checks"
	echo ""
	echo "          -R            Un-install Nvidia web drivers"
	echo ""
	echo "          -m <build>    Modify the current driver's NVDARequiredOS"
        echo ""
	echo "          -f            Re-install"
	echo ""
        echo "          -c            Don't update caches"
	echo ""
}

PROMPT_REBOOT=true
NO_CACHE=false
REINSTALL=false
let N=0
while getopts ":hpu:Rm:cf" OPTION; do
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
	elif [ "$OPTION" == "R" ]; then
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

Z="/dev/null"
PLISTB="/usr/libexec/PlistBuddy -c"
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
	silent rm -f $UPDATE_PLIST
}

function error {
	clean
	printf "Error: $1\n"
	exit 1
}

function warning {
	printf "Warning: $1\n"
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
	if [ $? -ne 0 ]; then
		error "kextcache exit code $?"; fi
}

function sql_add_kext {
	printf "insert or replace into kext_policy " >> $SQL_TMP
	printf "(team_id, bundle_id, allowed, developer_name, flags) " >> $SQL_TMP
	printf "values (\"$TEAM_ID\",\"$1\",1,\"$DEVELOPER_NAME\",1);\n" >> $SQL_TMP
}

# getopts -p -> get the plist then exit

if [ "$FUNC" == "plist" ]; then
	printf "Downloading '$UPDATE_PLIST'\n"
	curl -o "$UPDATE_PLIST" -# $UPDATE_PLIST_REMOTE
	if [ $? -ne 0 ]; then
		error "curl exit code $?"; fi
	open -R "$UPDATE_PLIST"
	exit 0
fi

# Check root

if [ "$(id -u)" != "0" ]; then
	error "Run it as root: sudo $0"; fi

# Check SIP

CSRUTIL=$(/usr/bin/csrutil status)
P="Filesystem Protections: disabled|System Integrity Protection status: disabled."
silent /usr/bin/grep -E "$P" <<< "$CSRUTIL"
if [ $? -ne 0 ]; then
	error "Is SIP enabled? No changes were made"; fi

# getopts -m -> modify NVDARequireOS then exit

if [ "$FUNC" == "mod" ]; then
	if [ -f "$MOD_PATH" ]; then
		printf "Setting NVDARequiredOS to $MOD_VER_STR...\n"
		$PLISTB "Set $MOD_KEY $MOD_VER_STR" $MOD_PATH
		if [ $? -ne 0 ]; then
			error "plistbuddy exit code $?"
		else
			caches
			exit 0
		fi
	else
		error "$MOD_PATH not found"
	fi
fi

# getopts -R -> uninstall then exit

if [ "$FUNC" == "remove" ]; then
	read -n 1 -s -r -p "Uninstall Nvidia web drivers? y/N" input
	case "$input" in
	y|Y )
		printf "\n" ;;
	*)
		exit 0 ;;
	esac
	printf "Removing files...\n"
	remove
	caches
	bye
fi

# Clean

clean
PROMPT="Install? y/N"

if [ "$FUNC" != "url" ]; then

	# No URL specified, get installed web driver verison

	VER="none"
	INFO_PLIST="$CHECK_INSTALLED_VERSION/Contents/Info.plist"
	if [ -f $INFO_PLIST ]; then
		GETINFO=$($PLISTB "Print :CFBundleGetInfoString" $INFO_PLIST 2> $Z)
		GETINFO="${GETINFO##* }"
		# check if we have a valid version string
		COUNT="${GETINFO//[^.]}"  # get . characters
		COUNT="${#COUNT}"  # how many?
		if [ "$COUNT" == "5" ]; then
			VER=$GETINFO; fi  # 5 dots is ok
	fi

	# Get updates file

	printf 'Checking for updates...\n'
	curl -o $UPDATE_PLIST -s $UPDATE_PLIST_REMOTE
	if [ $? -ne 0 ]; then
		error "Couldn't get updates data from Nvidia"; fi

	# Check for an update

	let i=0
	while true; do
		U_BUILD=$($PLISTB "Print :updates:$i:OS" $UPDATE_PLIST 2> $Z)
		if [ $? -ne 0 ]; then
			U_BUILD="none"
			U_URL="none"
			U_VER="none"
			break
		fi
		if [ "$U_BUILD" == "$BUILD" ]; then
			U_URL=$($PLISTB "Print :updates:$i:downloadURL" $UPDATE_PLIST 2> $Z)
			if [ $? -ne 0 ]; then
				U_URL="none"; fi
			U_VER=$($PLISTB "Print :updates:$i:version" $UPDATE_PLIST 2> $Z)
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
			PROMPT="Re-install? y/N"
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

read -n 1 -s -r -p "$PROMPT" INPUT
case "$INPUT" in
y|Y)
	printf "\n" ;;
*)
	clean
	exit 0 ;;
esac

# Download

printf "Downloading package...\n"
/usr/bin/curl -o $PKG_DST -# $U_URL
if [ $? -ne 0 ]; then
	error "curl exit code $?, no changes were made"; fi

# Extract

printf "Extracting...\n"
/usr/sbin/pkgutil --expand $PKG_DST $PKG_DIR
cd $PKG_DIR/*$DRIVERS_DIR_HINT
cat Payload | gunzip -dc | cpio -i
if [ $? -ne 0 ]; then
	error "Unpack failed, no changes were made"; fi

# Make SQL

cd $PKG_DIR/*$DRIVERS_DIR_HINT
KEXTS=(./Library/Extensions/*kext/)
for KEXT in "${KEXTS[@]}"; do
	PLIST="$KEXT/Contents/Info.plist"
	BUNDLE_ID=$($PLISTB "Print :CFBundleIdentifier" $PLIST 2> /dev/null)
	if [ $? -ne 0 ]; then
		error "plistbuddy exit code $?, no changes were made"; fi
	sql_add_kext "$BUNDLE_ID"
done
sql_add_kext "com.nvidia.CUDA"

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
