#!/bin/bash
# Mach-O が /usr/lib と /System/Library 以外にリンクしておらず、libcurl・libssl・libcrypto も使っていないことを確かめる（PLAN §11.2）。
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "使い方: $0 <Mach-O> [<Mach-O>...]" >&2
  exit 2
fi

status=0
for bin in "$@"; do
  if [ ! -f "$bin" ]; then
    echo "ERROR: $bin がありません" >&2
    status=1
    continue
  fi
  while IFS= read -r lib; do
    case "$lib" in
      *libcurl*|*libssl*|*libcrypto*)
        echo "ERROR: $bin がネットワーク用のライブラリにリンクしています: $lib" >&2
        status=1
        ;;
      /usr/lib/*|/System/Library/*)
        ;;
      *)
        echo "ERROR: $bin が許されない場所のライブラリにリンクしています: $lib" >&2
        status=1
        ;;
    esac
  done < <(otool -L "$bin" | tail -n +2 | awk '{ print $1 }')
done
exit "$status"
