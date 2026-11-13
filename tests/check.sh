#!/bin/sh
# Every check this repo has. The pre-commit hook runs it; run it by hand too.
set -e
cd "$(dirname "$0")/.."

# QML injects these names into signal handlers (MouseArea.onClicked gets
# `mouse`), so an id with one of them is silently shadowed inside handlers.
if grep -nE '^\s*id:\s*(mouse|wheel|event|drag|touch)\s*$' *.qml; then
  echo "check: rename the id above; QML injects that name into signal handlers" >&2
  exit 1
fi

# The bar entry draws its icon through the shell's renderer, so it matches
# the icons around it (shell/plugins/bar/README.md, "Icon geometry").
bar=$(python3 -I -c 'import json; print(json.load(open("manifest.json"))["entryPoints"]["barWidget"])')
if ! grep -qE '(BarIconButton|WidgetButton) *[{]' "$bar"; then
  echo "check: $bar must draw the bar icon with BarIconButton or WidgetButton (shell/plugins/bar/README.md, Icon geometry)" >&2
  exit 1
fi

python3 -I -m unittest discover -s tests -q
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -silent
# CI has no omarchy; everywhere else a missing omarchy is an error.
if [ -n "$CI" ] && ! command -v omarchy >/dev/null; then
  echo "check: omarchy is not installed in CI, skipping plugin validate" >&2
else
  omarchy plugin validate .
fi
