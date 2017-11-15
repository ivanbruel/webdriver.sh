# webdriver.sh

Bash script for managing Nvidia's web drivers on macOS High Sierra: download, install, update and patch between macOS versions.

## Usage

Call the script without options to update to the latest driver for the currently installed macOS build.

```
webdriver [options]

-p            Just get the updates plist

-u <url>      Use driver package at <url>, no version checks

-R            Un-install Nvidia web drivers

-m <build>    Modify the current driver's NVDARequiredOS

-f            Re-install

-c            Don't update caches
```
The default for option -m is the currently installed macOS build. See the script itself for tuning uninstall/removal of files.

## License

This project is licensed under the terms of the GPL 3.0
