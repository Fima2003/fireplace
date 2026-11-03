# Fireplace

<img src="docs/icon.png" width="96" align="right" alt="">

A menu bar app for macOS that listens to the microphone for a double clap.

![A fire burning in the fireplace](docs/screenshot.png)

- **First double clap:** your desktop becomes a fireplace with a live, physically simulated fire, and every other app quits. The fire crackles and roars the whole time it burns.
- **Second double clap:** the fire goes out. It fades together with its sound, your original wallpaper comes back, and Fireplace quits. (**Put Out the Fire and Quit** in the menu bar does the same.)
- **The coil:** while the fire burns, a small cast-iron button with a heating coil floats in the bottom-right corner of the screen. Hold it to push the coil into the fire: it glows from dull red to yellow-white, and the fire burns harder, with more flames and sparks and a rushing roar, then settles as the coil cools. **Stoke the Fire** in the menu bar gives it a short press.

## Build and run

```bash
./build.sh
open build/Fireplace.app
```

On first launch macOS asks for microphone access. While the app runs, a flame icon sits in the menu bar. Its menu shows the status and lets you light the fire or quit without clapping.

Launch it with `open` (or from Finder), not by running the binary inside a terminal. The terminal gets quit along with the other apps, and that would take Fireplace down with it.

## The fire

The flames aren't an animation. They're a 2D fluid simulation that runs on the GPU in Metal compute shaders, 60 steps a second:

- **Flow:** incompressible air with semi-Lagrangian advection, a Jacobi pressure solve, Boussinesq buoyancy (hot gas rises) and vorticity confinement (keeps the swirls). Room air comes in through the mouth of the fireplace and leaves up the chimney throat.
- **Combustion:** hot logs give off fuel gas in wandering hot spots. Above its ignition temperature the gas burns, releasing heat and soot. Everything cools by mixing and by T⁴ radiation.
- **Light:** only hot soot glows, as a black body: its color and Stefan–Boltzmann brightness come from its temperature. The room is lit by the fire's total heat, so the bricks brighten and dim with the flames. Sparks are particles carried by the airflow.

The sound is synthesized on the fly for as long as the fire burns, not played from a file: filtered noise for the roar (which swells and breathes), a faint hiss, the rushing air when the coil is in, plus randomly timed crackle voices of three sizes: frequent small ticks, pops that ring a little, and the occasional big pop with a low thump, with now and then a sizzle of sap. The coil raises the roar and triples the crackle rate; stoking adds a whoosh and a burst of crackles that settles over a few seconds.

Crackles through your speakers look just like claps to the microphone. So while the fire burns, the microphone and the sound share one audio engine with macOS voice processing turned on: its echo canceller knows exactly what we are playing and subtracts it from the microphone before the clap detector hears it (automatic gain control is off, and the ducking of other apps' audio is kept to the minimum macOS 14 and later allow). That engine takes a couple of seconds to build, so it's built in the background: the fire appears the moment you clap, and the sound fades in once the engine is up. If voice processing can't be enabled, the app falls back to timing: every crackle is stamped with the moment it leaves the speaker, a clap that arrives from 20 ms before to 60 ms after one of them is ignored, and once a first clap has been heard the crackles pause for a second so they are less likely to get in the way of the second.

The rest of the scene is drawn once per screen size: bump-mapped brick, charred logs with glowing cracks, the coal bed, the mantel, the floor.

**Every fire is different.** Each time the fire is lit, the app takes a 64-bit seed from `SecRandomCopyBytes`. That's the kernel's random generator, which macOS seeds from the hardware true random number generator (the Secure Enclave on Apple silicon). The seed places the logs, colors the bricks and drives the fuel release. Fluid flow is chaotic, so no two fires ever burn the same way, on your Mac or anyone else's.

## How it stays idle

Until the fire is lit, nothing polls. Core Audio delivers microphone buffers to a tap callback, and a small state machine looks at each 5 ms slice of sound. It flags a clap only when the sound jumps sharply, peaks within about 12 ms, and dies away within 100 ms, with quiet between the two claps. The main thread wakes up only when a clap is detected.

Once lit, the simulation draws at 30 fps and costs about 1.8 ms of GPU time per frame on an M3 Pro. It pauses whenever app windows fully cover the desktop. The sound is a few arithmetic operations per sample on the audio thread, and the coil button animates only while its heat is changing.

## Tuning

```bash
defaults write com.fima.Fireplace ClapThreshold -float 0.03   # raise if it triggers too easily (default 0.015)
defaults write com.fima.Fireplace MaxClapGap -float 1.0       # allow slower double claps (default 0.8 s)
defaults write com.fima.Fireplace KeepRunning -array com.apple.Music com.spotify.client   # apps not to quit
```

Developer commands:

```bash
build/Fireplace.app/Contents/MacOS/Fireplace --preview            # live fire, sound and coil button in a normal window; quits nothing
build/Fireplace.app/Contents/MacOS/Fireplace --analyze clip.wav   # list the claps found in a recording
build/Fireplace.app/Contents/MacOS/Fireplace --render out.png     # a still of a fresh fire (--seconds N to burn longer, --stoke to catch a flare-up)
build/Fireplace.app/Contents/MacOS/Fireplace --sound out.wav      # write the fire sound to a file (--seconds N, default 20: a stoke at 5 s, the coil held from 10 s to 14 s)
build/Fireplace.app/Contents/MacOS/Fireplace --listen 20          # play the sound and listen for claps through it for 20 s, printing the mode (AEC or fallback), every clap, and the input level (--no-aec forces the fallback)
build/Fireplace.app/Contents/MacOS/Fireplace --make-icon AppIcon.iconset   # render a new app icon
```
