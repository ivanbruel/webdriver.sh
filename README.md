# webdriver.sh

Bash script for managing Nvidia's web drivers on macOS High Sierra.

## Usage

For the script to do anything useful, 'System Integrity Protection' should be turned off.

Call the script without options to check for driver updates. If a driver is available you will be given the option to download and install it. Only the drivers will be installed and/or removed, the Nvidia status app/preference pane/root helper is excluded from all operations.

A 'Use Nvidia drivers' NVRAM variable will be set during installation, and unset upon driver removal.

```
sudo webdriver.sh [options]

-f            Re-install

-c            Don't update caches

-p            Download the updates property list and exit

-r            Uninstall web drivers

-u url        Use driver package at url, no version checks

-m [build]    Modify the current driver's NVDARequiredOS
```

If no [build] is provided for option -m, the installed macOS's build version string will be used. The -m [build] option is provided as a convenience only and should be avoided where possible.

Current drivers will be uninstalled as part of any installation, you can customise the list of files that are removed by editing the script (also affecting option -r).

## Installing

Install webdriver.sh with [Homebrew](https://brew.sh)

```
brew tap vulgo/repo
brew install webdriver.sh
sudo webdriver [options]
```

## License

This project is licensed under the terms of the GPL version 3
