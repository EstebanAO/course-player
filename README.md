# Course Player

Course Player is a lightweight, native macOS application for studying local video courses while keeping progress and Markdown notes beside the library.

It is designed for personal, offline-first use. Course files, notes, playback history, and generated video cache remain on the user's Mac.

## Features

- Recursively indexes folders and subfolders and updates when macOS reports file changes.
- Plays MP4, MOV, M4V, common audio formats, and MPEG transport streams (`.ts`) through FFmpeg remuxing.
- Remembers the last opened lesson, playback position, completion state, and playback speed.
- Opens the last lesson paused with a clear **Continue studying** action.
- Supports playback rates from 0.5× to 2×.
- Provides previous/next controls and optional automatic playback of the next lesson.
- Provides a resizable split view with the player and a live-preview Markdown editor.
- Saves one standard `.md` file per lesson in `Course Player Notes/`.
- Supports headings, bold, italic, underline, highlight, strikethrough, links, code, quotes, dividers, bullet lists, numbered lists, and pasted images.
- Stores application state in `.course-player/progress.json` inside the selected library.
- Keeps at most three remuxed videos in the local cache.
- Avoids periodic directory polling and batches progress writes to reduce energy use.
- Includes library filters, visible lesson states, remembered folder expansion, contextual actions, actionable error banners, and note save feedback.
- Supports image paste and drag-and-drop, task lists, links, and familiar formatting shortcuts.
- Keeps user-facing language consistent in Spanish and includes a localization catalog structure for future translations.

## Keyboard shortcuts

- `Command-B`, `Command-I`, `Command-U`: bold, italic, underline in notes.
- `Command-Shift-7`, `Command-Shift-8`: numbered and bulleted lists.
- `Command-Shift-H`: highlight selected text.
- `Command-Option-P`: play or pause without taking the space bar away from the editor.
- `Command-Option-Left/Right`: previous or next video.
- `Command-Option-J/L`: back or forward 15 seconds.
- Standard macOS text navigation, selection, undo, paste, and find shortcuts remain available.

## Requirements

- macOS 13 or newer.
- Xcode Command Line Tools.
- FFmpeg only when `.ts` playback is needed.

## Build

```sh
./build-app.sh
```

The resulting application is written to `.build/Course Player.app`. Without FFmpeg, MP4, MOV, M4V, and supported audio files still work.

For `.ts` support, install FFmpeg locally or explicitly provide a redistributable build:

```sh
FFMPEG_PATH="$(command -v ffmpeg)" ./build-app.sh
```

At runtime, Course Player checks its application resources, `FFMPEG_PATH`, `/opt/homebrew/bin/ffmpeg`, and `/usr/local/bin/ffmpeg` in that order.

To build and copy the application to `/Applications`:

```sh
./install-app.sh
```

You may also pass `FFMPEG_PATH` to `install-app.sh`.

## Release build

Create a universal Apple Silicon + Intel `.dmg` and `.zip`:

```sh
./release.sh
```

For signed distribution, set `SIGNING_IDENTITY` to a Developer ID Application identity. If a notarytool keychain profile is available, also set `NOTARY_PROFILE`; the release script will submit and staple the build. GitHub Actions builds an unsigned universal artifact for every push and pull request.

## FFmpeg notice

FFmpeg is not stored in this repository. If you distribute a build that bundles FFmpeg, you are responsible for using a redistributable configuration and complying with its license and the licenses of enabled components. In particular, FFmpeg builds configured with `--enable-nonfree` must not be redistributed. See [FFmpeg's legal and license guidance](https://ffmpeg.org/legal.html).

## Privacy

Course Player has no analytics, accounts, servers, or network synchronization. It only reads the library selected by the user and writes notes, progress, and cache data inside that folder.

## Project structure

- `CoursePlayerApp.swift` — application entry point and menus.
- `ContentView.swift` — library, player, controls, and notes interface.
- `LibraryModel.swift` — indexing, playback, progress, notes, caching, and file monitoring.
- `LiveMarkdownEditor.swift` — live Markdown rendering, formatting, lists, and image paste support.
- `Models.swift` — library and progress data models.
- `build-app.sh` — Swift compiler build script.
- `install-app.sh` — local `/Applications` installation helper.

## Contributing

Issues and pull requests are welcome. Please avoid committing course material, notes, generated builds, caches, or third-party binaries without compatible redistribution terms.

## License

Course Player is available under the MIT License. See [LICENSE](LICENSE).
