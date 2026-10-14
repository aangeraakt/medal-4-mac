# Medal 4 Mac

A small Medal-style clipping app for macOS 13 Ventura and newer. It lives in the menu bar
and keeps recording your screen and game audio in the background. Press a hotkey and it
saves the **last 10 s, 30 s, 1 min, 2 min or 3 min** as an `.mp4` in
**Movies → Medal4Mac** (`~/Movies/Medal4Mac`).

---

## For the person building it

You need a Mac with **Xcode** (15.2 is the newest that runs on Ventura) or at least
the Command Line Tools:

```bash
xcode-select --install
```

Then, in this folder:

```bash
bash build.sh
```

That creates:

- `build/Medal4Mac.app`, the app
- `build/Medal4Mac.zip`, the zip to send back

With full Xcode installed the build is **universal**, so it runs on both Intel and
Apple Silicon Macs. With only the Command Line Tools it builds for your own Mac's chip
(the script says which). If your Mac's chip differs from your friend's, you'll need Xcode.

If the build fails, please send back the full error output.

---

## Using it

1. Unzip and drag **Medal4Mac.app** into **Applications**.
2. The first time, **right-click the app → Open → Open**. The app isn't signed with an Apple
   developer account, so macOS warns about it. If it says the app is "damaged", run this
   once in Terminal:
   ```bash
   xattr -cr /Applications/Medal4Mac.app
   ```
3. macOS asks for **Screen Recording** permission. Turn it on in
   *System Settings → Privacy & Security → Screen Recording*, then **quit and reopen** the app
   (via the menu bar icon → Quit).
4. A ● icon in the menu bar means it's recording. Play your game and clip.

### Hotkeys

| Keys | Saves |
|---|---|
| **⌥C** (Option + C) | default length (30 s, changeable in the menu) |
| **⌃⌥1** (Control + Option + 1) | last 10 seconds |
| **⌃⌥2** | last 30 seconds |
| **⌃⌥3** | last 1 minute |
| **⌃⌥4** | last 2 minutes |
| **⌃⌥5** | last 3 minutes |

You can change the main clip key to F8, F9 or F10 in **menu → Clip Hotkey**. On Mac
keyboards you may have to hold **fn** for F-keys to work, unless you turned on
*"Use F1, F2, etc. keys as standard function keys"* in Keyboard settings.

When a clip is saved you hear a "Glass" sound and get a notification. Click the
notification to show the clip in Finder.

### Menu options

- **Resolution:** Native, 1440p, 1080p (default) or 720p
- **Frame Rate:** 30 or 60 FPS
- **Quality:** Low, Medium or High (higher quality makes bigger files)
- **Record Game/System Audio:** on or off
- **Open Clips Folder**, **Open at Login**, **Restart Recording**

Changing resolution, FPS, quality or audio restarts recording, which clears the replay buffer.

### Notes

- It records the **main display**. Fullscreen games work.
- It records **system/game audio**. On Ventura it **cannot record your microphone**
  (Apple added that in a later macOS version).
- The buffer is kept on disk in `~/Library/Caches/Medal4Mac` (a few hundred MB at most)
  plus about 80 MB of RAM for audio.
- If you rebuild or update the app, macOS may ask for Screen Recording permission again.
  If recording won't start, remove Medal4Mac from the Screen Recording list, add it again,
  and reopen the app.
