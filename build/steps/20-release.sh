#!/usr/bin/env bash
set -euo pipefail

dnf -y install --allowerasing generic-release generic-release-common generic-logos
if rpm -qa 'fedora-release*' | grep .; then
  echo "20-release: fedora-release packages left" >&2
  exit 1
fi
