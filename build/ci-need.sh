#!/usr/bin/env bash
set -euo pipefail

bb=${BUSYBOX:-/bin/busybox}

present() {
  if [[ $1 == busybox ]]; then
    [[ -x $bb && $(file -b "$bb") == *statically\ linked* ]]
  else
    command -v "$1" > /dev/null
  fi
}

(( $# )) || { echo "usage: ci-need.sh <command>:<package>..." >&2; exit 2; }
for pair in "$@"; do
  cmd=${pair%%:*}
  pkg=${pair#*:}
  [[ $pair == *:* && -n $cmd && -n $pkg && $pkg != *:* ]] || { echo "::error::ci-need: bad pair '$pair'"; exit 2; }
done
missing=()
for pair in "$@"; do
  present "${pair%%:*}" || missing+=("$pair")
done
if (( ${#missing[@]} == 0 )); then
  echo "ci-need: present: ${*%%:*}"
  exit 0
fi
echo "ci-need: installing ${missing[*]#*:}"
sudo apt-get update
sudo apt-get install -y "${missing[@]#*:}"
left=()
for pair in "${missing[@]}"; do
  present "${pair%%:*}" || left+=("$pair")
done
(( ${#left[@]} == 0 )) || { echo "::error::ci-need: still missing after apt-get: ${left[*]}"; exit 1; }
echo "ci-need: installed ${missing[*]#*:}"
