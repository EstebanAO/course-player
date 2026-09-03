#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
"$SCRIPT_DIR/build-app.sh"

pkill -x CoursePlayer 2>/dev/null || true
ditto "$SCRIPT_DIR/.build/Course Player.app" "/Applications/Course Player.app"
touch "/Applications/Course Player.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Course Player.app"
codesign --verify --deep --strict "/Applications/Course Player.app"
open "/Applications/Course Player.app"

echo "/Applications/Course Player.app"
