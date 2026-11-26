#!/usr/bin/env bash
# Visual Studio Code. Example app: copy this file for another app, then add it to
# apps in an image param file (images/) with its installer. $1 is the installer's local path. Runs as root.
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$1"
