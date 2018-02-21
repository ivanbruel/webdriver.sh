# webdriver.sh

<p align="center">
<picture>
<source srcset="https://github.com/vulgo/webdriver.sh/raw/master/Images/screenshot.png, https://github.com/vulgo/webdriver.sh/raw/master/Images/screenshot@2x.png 2x" />
<img src="https://github.com/vulgo/webdriver.sh/raw/master/Images/screenshot@2x.png" alt="webdriver.sh screenshot" width="800" />
</picture>
</p>

Bash script for managing Nvidia's web drivers on macOS High Sierra.

<br/>

## Installing

Install webdriver.sh with [Homebrew](https://brew.sh)

```
brew tap vulgo/repo
brew install webdriver.sh
```

Update to the latest release

```
brew upgrade webdriver.sh
```

<br/>

# Example Usage

<p align="center">
<img src="https://raw.githubusercontent.com/vulgo/webdriver.sh/master/Images/egpu.svg?sanitize=true" alt="Macbook Pro Nvidia EGPU" width="50%">
</p>

## Install the latest drivers

```
sudo webdriver
```

Installs/updates to the latest available Nvidia web drivers for your current version of macOS.

<br/>

## Choose from a list of drivers

```
sudo webdriver -l
```

Displays a list of driver versions, choose one to download and install it.

<br />

#### Install from local package or URL

```
sudo webdriver FILE
```

Installs the drivers from package FILE on the local filesystem.

```
sudo webdriver -u URL
```

Downloads the package at URL and install the drivers inside. There is a nice list of available URLs maintained [here](http://www.macvidcards.com/drivers.html).

<br />

#### Uninstall drivers

```
sudo webdriver -r
```

Removes Nvidia's web drivers from your system.

<br />

#### Patch drivers to load on a different version of macOS

```
sudo webdriver -m [BUILD]
```

Modifies the installed driver's NVDARequiredOS. If no [BUILD] is provided for option -m, the installed macOS's build version string will be used.

<br />

#### Show help

```
webdriver -h
```

Displays help, lists options

<br />
<br />

## Frequently Asked Questions

#### Is webdriver.sh compatible with regular, or other third-party methods of driver installation?

Yes, you can use webdriver.sh before or after using any other method of driver installation.

#### Does webdriver.sh install the Nvidia preference pane?

No, you can install it at any point via Nvidia's installer package - webdriver.sh works fine with or without it.

#### Do I need to disable SIP?

No, but you'll want to if you are modifying the drivers to load - making changes to a kext's Info.plist excludes it from the prelinked kernel the next time it's built. Clover users may try [this kext patch](https://github.com/vulgo/webdriver.sh/blob/master/etc/clover-patch.plist) which disables Nvidia's OS checks. See also: [WebDriverStartup](https://github.com/vulgo/WebDriverStartup).

#### Will webdriver.sh mess with Nvidia's installer or 'repackage' the driver?

No, there are [other tools](https://www.google.com/search?q=nvidia+web+driver+repackager) available for doing this. For example,  [NvidiaWebDriverRepackager](https://github.com/Pavo-IM/NvidiaWebDriverRepackager)

#### Won't there be problems without repackaging?

No, the drivers are installed in exactly the same way (yes, it's just copying files) - and Nvidia's own installer removes anything installed by webdriver.sh.

#### Can't I just uninstall the drivers using webdriver.sh?

Yes, ```webdriver -r```

#### Does webdriver.sh install things to the wrong place?

No.

<br />

## License

webdriver.sh is free software licensed under the terms of the GPL version 3 or later.

<br />
