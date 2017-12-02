#!/bin/bash
FILE="webdriver.sh"
INSTALLPATH="/usr/local/bin/"
COMMAND="webdriver"
cd $(dirname $0)
cp -f "./$FILE" "$INSTALLPATH$COMMAND"
if [ $? -eq 0 ]; then
	echo "Installed $COMMAND to $INSTALLPATH"
else
	echo "Error installing $COMMAND to $INSTALLPATH"
	exit 1
fi
chmod +x "$INSTALLPATH"
exit $?