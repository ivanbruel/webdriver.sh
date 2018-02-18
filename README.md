# webdriver.sh

![webdriver.sh screenshot](https://github.com/vulgo/webdriver.sh/raw/master/Images/screenshot.png "webdriver.sh screenshot")

Bash script for managing Nvidia's web drivers on macOS High Sierra.

## Install

Installing webdriver.sh is easy with [Homebrew](https://brew.sh)

```
brew tap vulgo/repo
brew install webdriver.sh
```

Update to the latest release

```
brew upgrade webdriver.sh
```

## Example Usage

#### Install or update drivers

```
sudo webdriver
```

Installs/updates to the latest available Nvidia web drivers for your current version of macOS.

#### Choose from a list of drivers

```
sudo webdriver -l
```

Displays a list of driver versions, choose one to download and install it

#### Install a specific driver version

```
sudo webdriver FILE
```

Installs the drivers from the package located at FILE.

```
sudo webdriver -u URL
```

Downloads and installs the drivers from the package at URL. There is a nice list of available drivers/URLs maintained [here](http://www.macvidcards.com/drivers.html)

#### Uninstall

```
sudo webdriver -r
```

Removes Nvidia's web drivers from your system.

#### Patch drivers to load on a different version of macOS

```
sudo webdriver -m [BUILD]
```

Modifies the installed driver's NVDARequiredOS. If no [BUILD] is provided for option -m, the installed macOS's build version string will be used.

#### Show help

```
webdriver -h
```

Displays help, lists options

## Configuration

The current web drivers will be uninstalled when you install new drivers, you can remove additional files by editing \<homebrew prefix\>/etc/webdriver.sh/uninstall.conf

## F.A.Q.

#### Is webdriver.sh compatible with regular, or other third-party methods of driver installation?

Yes, you can use webdriver.sh before or after using any other method of driver installation.

#### Does webdriver.sh install the Nvidia preference pane?

No, you can install it at any point via Nvidia's installer package - webdriver.sh works fine alongside it or without it.

#### Will webdriver.sh mess with Nvidia's installer or 'repackage' the driver?

No, there are [other tools](https://www.google.com/search?q=nvidia+web+driver+repackager) available for doing this. For example,  [NvidiaWebDriverRepackager](https://github.com/Pavo-IM/NvidiaWebDriverRepackager)

#### What about uninstalling, won't there be problems without repackaging?

No, Nvidia's own installer runs a perl script that removes anything that was installed by webdriver.sh

#### Can't I just uninstall the drivers using webdriver.sh?

Yes, sudo webdriver -r

#### Does webdriver.sh install things to the wrong place?

No.

## License

webdriver.sh is free software licensed under the terms of the GPL version 3 or later
