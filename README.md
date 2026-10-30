# Fireplace

A menu bar app for macOS that listens to the microphone for a double clap.

![The fireplace wallpaper with live flames](docs/screenshot.png)

- **First double clap:** your wallpaper changes to a fireplace with animated flames, and every other app quits.
- **Second double clap:** the fire fades out, your original wallpaper comes back, and Fireplace quits.

## Build and run

```bash
./build.sh
open build/Fireplace.app
```

On first launch macOS asks for microphone access. While the app runs, a flame icon sits in the menu bar. Its menu shows the status and lets you light the fire or quit without clapping.

Launch it with `open` (or from Finder), not by running the binary inside a terminal. The terminal gets quit along with the other apps, and that would take Fireplace down with it.

## How it stays idle

Nothing polls. Core Audio delivers microphone buffers to a tap callback, and a small state machine looks at each 5 ms slice of sound. It flags a clap only when the sound jumps sharply, peaks within about 12 ms, and dies away within 100 ms, with quiet between the two claps. The main thread wakes up only when a double clap is detected. The flames are Core Animation particle emitters drawn by the window server, so the app does no per-frame work.

## Tuning

```bash
defaults write com.fima.Fireplace ClapThreshold -float 0.03   # raise if it triggers too easily (default 0.015)
defaults write com.fima.Fireplace MaxClapGap -float 1.0       # allow slower double claps (default 0.8 s)
defaults write com.fima.Fireplace KeepRunning -array com.apple.Music com.spotify.client   # apps not to quit
```

Developer commands:

```bash
build/Fireplace.app/Contents/MacOS/Fireplace --preview            # live fire in a normal window; quits nothing
build/Fireplace.app/Contents/MacOS/Fireplace --analyze clip.wav   # list the claps found in a recording
build/Fireplace.app/Contents/MacOS/Fireplace --render out.png     # write the wallpaper image
```
