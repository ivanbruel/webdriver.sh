# webdriver.sh

<p align="center">
<picture>
<source srcset="https://github.com/vulgo/webdriver.sh/raw/master/Images/screenshot.png, https://github.com/vulgo/webdriver.sh/raw/master/Images/screenshot@2x.png 2x" />
<img src="https://github.com/vulgo/webdriver.sh/raw/master/Images/screenshot@2x.png" alt="webdriver.sh screenshot" width="850" />
</picture>
</p>

Bash script for managing NVIDIA's web drivers on macOS High Sierra and later with an option to set the required build number in NVDAStartupWeb.kext and NVDAEGPUSupport.kext.

<pre><code>bash&nbsp;<(curl&nbsp;-s&nbsp;https://raw.githubusercontent.com/vulgo/webdriver.sh/v1.5.1/get)</code></pre>

#### Changes in 1.5

- Preferred method of running incompatible drivers is the [NvidiaGraphicFixup](https://github.com/lvs1974/NvidiaGraphicsFixup) ngfxcompat=1 boot argument
- Auto-adding of the Clover patch has been moved to the [GUI app here](https://github.com/vulgo/WebDriverManager) where it is a better fit
- Auto-staging of GPU companion bundles is deterministic based on your current configuration
- New --stage option to override deterministic behaviour
- Single file to download, run and modify
- Runs on 10.14 Mojave beta, now wait for [drivers](https://vulgo.github.io/nvidia-drivers) from NVIDIA

## Installing

Install webdriver.sh with [Homebrew](https://brew.sh)

```shell-script
brew tap vulgo/repo
brew install webdriver.sh
```

Update to the latest release

```shell-script
brew upgrade webdriver.sh
```

<br/>

# Example Usage

<p align="center">
<img src="https://raw.githubusercontent.com/vulgo/webdriver.sh/master/Images/egpu.svg?sanitize=true" alt="Macbook Pro NVIDIA EGPU" width="50%">
</p>

## Install the latest drivers

```shell-script
webdriver
```

Installs/updates to the latest available NVIDIA web drivers for your current version of macOS.

<br/>

## Choose from a list of drivers

```shell-script
webdriver --list
```

Displays a list of driver versions, choose one to download and install it.

<br />

#### Install from local package or URL

```shell-script
webdriver FILE
```

Installs the drivers from package <em>FILE</em> on the local filesystem.

```shell-script
webdriver -u URL
```

Downloads the package at <em>URL</em> and installs the drivers within. There is a nice list of available URLs maintained [here](http://www.macvidcards.com/drivers.html).

<br />

#### Uninstall drivers

```shell-script
webdriver --remove
```

Removes NVIDIA's web drivers from your system.

<br />

#### Patch NVDAStartupWeb Info.plist for a different version of macOS

```shell-script
webdriver -m [BUILD]
```

Modifies the installed driver's NVDARequiredOS Info.plist property. If no [BUILD] is provided for option -m, the installed macOS's build version string will be used.

<br />

#### Show help

```shell-script
webdriver --help
```

Displays help, lists options.

<br />
<br />

## Web Interface

[https://vulgo.github.io/nvidia-drivers](https://vulgo.github.io/nvidia-drivers)

<br />
<br />

## License

webdriver.sh is free software licensed under the terms of the GPL version 3 or later.

<br />
