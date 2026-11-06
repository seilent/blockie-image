#!/usr/bin/env bash
set -euo pipefail

read -ra opts <<< "${BLOCKIE_DNF_OPTS:-}"
dnf -y "${opts[@]}" install --allowerasing generic-release generic-release-common generic-logos
if rpm -qa 'fedora-release*' | grep .; then
  echo "20-release: fedora-release packages left" >&2
  exit 1
fi
