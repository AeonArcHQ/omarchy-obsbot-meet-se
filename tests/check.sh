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

python3 -I -m unittest discover -s tests -q
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -silent
omarchy plugin validate .
