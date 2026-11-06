#!/usr/bin/env bash
set -euo pipefail

find /tmp -mindepth 1 -delete
rm -rf /run/dnf /var/log/dnf5.log* /var/cache/libdnf5 /var/lib/dnf/repos /var/cache/ldconfig/aux-cache
