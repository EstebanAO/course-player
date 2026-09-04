#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
BUILD_DIR="$SCRIPT_DIR/.build"
APP_DIR="$BUILD_DIR/Course Player.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"
mkdir -p "$SCRIPT_DIR/.build-cache"

typeset -a BUILD_ARCHS BINARIES
if [[ -n "${COURSE_PLAYER_ARCHS:-}" ]]; then
  BUILD_ARCHS=(${=COURSE_PLAYER_ARCHS})
else
  BUILD_ARCHS=("$(uname -m)")
fi

for ARCH in "${BUILD_ARCHS[@]}"; do
  BINARY="$BUILD_DIR/CoursePlayer-$ARCH"
  /usr/bin/swiftc \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -target "$ARCH-apple-macos13.0" \
    -module-cache-path "$SCRIPT_DIR/.build-cache/$ARCH" \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreServices \
    -framework AVKit \
    -framework AVFoundation \
    "$SCRIPT_DIR/CoursePlayerApp.swift" \
    "$SCRIPT_DIR/Models.swift" \
    "$SCRIPT_DIR/LibraryModel.swift" \
    "$SCRIPT_DIR/LiveMarkdownEditor.swift" \
    "$SCRIPT_DIR/ContentView.swift" \
    -o "$BINARY"
  BINARIES+=("$BINARY")
done

if (( ${#BINARIES[@]} > 1 )); then
  lipo -create "${BINARIES[@]}" -output "$MACOS_DIR/CoursePlayer"
else
  cp "${BINARIES[1]}" "$MACOS_DIR/CoursePlayer"
fi

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$SCRIPT_DIR/Assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
if [[ -d "$SCRIPT_DIR/Resources" ]]; then
  ditto "$SCRIPT_DIR/Resources" "$RESOURCES_DIR"
fi

if [[ -n "${FFMPEG_PATH:-}" ]]; then
  if [[ ! -x "$FFMPEG_PATH" ]]; then
    echo "FFMPEG_PATH must point to an executable FFmpeg binary." >&2
    exit 1
  fi
  cp "$FFMPEG_PATH" "$RESOURCES_DIR/ffmpeg"
  chmod +x "$RESOURCES_DIR/ffmpeg"
else
  echo "Building without bundled FFmpeg. MP4/MOV/M4V playback works; .ts requires FFmpeg at runtime."
fi

chmod +x "$MACOS_DIR/CoursePlayer"
SIGNING_IDENTITY=${SIGNING_IDENTITY:--}
codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$APP_DIR"
echo "$APP_DIR"
