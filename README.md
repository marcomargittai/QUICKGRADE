# QuickGrade

Select a JPEG or PNG in Finder, press Space, and grade it right there instead of opening Quick Look. Light, white balance, HSL, curves, filters, crop, drawing and sharing, with every slider already open.

Needs macOS 14 Sonoma or newer on an Apple Silicon Mac (M1 or later).

## Install with your AI agent

Copy this prompt into Claude Code, Codex, Cursor or any agent that can run commands on your Mac:

```text
Install QuickGrade on my Mac. It is a free Mac app: when I select a JPEG or PNG in Finder and press Space, it opens the photo with editing sliders instead of Quick Look.

1. Check that this Mac has Apple Silicon and macOS 14 or newer: `uname -m` must print arm64 and the first number of `sw_vers -productVersion` must be 14 or higher. If not, stop and tell me QuickGrade won't run here.
2. Make a new temporary folder, download https://github.com/marcomargittai/QUICKGRADE/releases/latest/download/QuickGrade.zip into it with curl -fL, and unzip it there with `ditto -x -k QuickGrade.zip .`
3. Quit QuickGrade if it is running (`killall QuickGrade`, ignore an error), then move QuickGrade.app into /Applications, replacing any older copy. If /Applications is not writable, use ~/Applications instead.
4. Open it with `open` on the installed app.
5. Do not change security settings or remove macOS quarantine flags yourself. Instead, tell me the two steps only I can do:
   - If macOS says it cannot verify the developer: open System Settings, go to Privacy & Security, scroll down, click Open Anyway, then open QuickGrade again.
   - When macOS asks for Accessibility, switch QuickGrade on. It needs this to notice Space in Finder.
6. Finish by telling me: select a photo in Finder and press Space.
```

## Install by hand

1. Download [QuickGrade.zip](https://github.com/marcomargittai/QUICKGRADE/releases/latest/download/QuickGrade.zip) and open it.
2. Move QuickGrade to your Applications folder.
3. Open it. If macOS says it cannot verify the developer, open System Settings, go to Privacy & Security, and click **Open Anyway**.
4. Switch QuickGrade on when macOS asks for Accessibility.
5. Select a photo in Finder and press Space.

## Build from source

```bash
swift build
swift test
scripts/run.sh release   # builds, installs to Applications and opens it
scripts/share.sh         # makes dist/QuickGrade.zip for sharing
```
