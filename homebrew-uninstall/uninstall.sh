#!/bin/bash

# Removes webdriver.sh + configuration files

BREW_PREFIX="$(brew --prefix)"
rm -rf "${BREW_PREFIX}/etc/webdriver.sh"
brew remove -f webdriver.sh
