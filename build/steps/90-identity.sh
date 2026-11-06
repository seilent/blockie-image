#!/usr/bin/env bash
set -euo pipefail

v=${BLOCKIE_VERSION:-}
[[ $v =~ ^[0-9]{8}\.[0-9a-z]+$ ]] || { echo "90-identity: BLOCKIE_VERSION '$v' is not YYYYMMDD.<id>" >&2; exit 1; }

cat > /usr/lib/os-release <<OS
NAME=Blockie
ID=blockie
ID_LIKE=fedora
VERSION_ID=44
PRETTY_NAME="Blockie"
IMAGE_VERSION=$v
DEFAULT_HOSTNAME=blockie
HOME_URL=https://github.com/seilent/blockie-image
OS

install -d /usr/lib/blockie
printf 'IMAGE_VERSION=%s\n' "$v" > /usr/lib/blockie/version

[[ $(readlink /etc/os-release) == ../usr/lib/os-release ]] || { echo "90-identity: /etc/os-release is not ../usr/lib/os-release" >&2; exit 1; }
