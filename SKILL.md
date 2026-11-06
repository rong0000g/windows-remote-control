---
name: windows-remote-control
description: Turn a TV box, projector or other Bluetooth remote into a Windows PC controller using AutoHotkey v2, with a launcher menu, per-app key layouts, and optional voice input, without modifying the remote or affecting the physical keyboard. Use this whenever someone wants to pair a remote with Windows, read its real key codes, map remote buttons to apps or shortcuts, control ChatGPT, WeChat, Chrome or similar apps from a couch, or debug remote keys that do nothing. Also use it for 遥控器、投影仪遥控器、蓝牙遥控器连电脑、遥控器按键映射, even when AutoHotkey is not mentioned.
---

# Windows remote control

Build a working remote-to-PC setup in small verified steps. Most failed setups come from assuming: that a remote is Bluetooth, that a shortcut works, that a button reaches Windows. Measure each of these before building on it.

Bundled files:

- `scripts/remote-control.ahk`: the working script. It has a launcher menu, a remote mode, per-app layouts and a settings window. Treat its app layouts and coordinates as examples to recalibrate.
- `scripts/dictate.cs`: voice input helper. It reads the remote's own microphone over HID and decodes the SBC audio, then recognizes it locally or through an optional cloud API.
- `scripts/asr/asr_worker.py`: local SenseVoice recognizer, loaded on first use and released when idle.
- `scripts/setup-asr.ps1`: downloads the recognizer's model and runtime. Tell the person the size first.
- `scripts/按键设置.ahk`: opens the settings window.
- `scripts/build.ps1`: compiles every C# program with the .NET compiler built into Windows.
- `tools/keylog.cs`: guided key logger that records only the remote.
- `tools/voicecap.cs`: records the remote's raw HID reports while the voice key is held.
- `tools/sbcdec.py`, `tools/spectro.py`: decode those recordings to WAV and draw spectrograms.
- `tools/wincap.cs`: captures a process's windows in the background with `PrintWindow`, without activating them. Captures can contain private content, so use it on safe targets and do not keep the files.
- `tools/gattprobe.cs`: listens on the remote's readable Bluetooth channels.
- `tools/btscan.cs`: lists nearby Bluetooth LE devices.
- `references/pitfalls.md`: read it before writing or changing AutoHotkey code, and whenever something fails in a confusing way.
- `references/example-x500.md`: a complete worked example of one remote's keys and app layouts.
- `references/testing.md`: read it before testing, because a careless test can send real messages.

## Workflow

### 1. Find out how the remote talks

A projector connecting to a Bluetooth speaker says nothing about its remote. Check before buying hardware:

1. Point the remote at a phone camera and press keys. A white or purple flash means that key sends infrared. The visible red light is only an indicator.
2. On the original device, cover the remote's tip with a hand and press keys. Infrared stops; Bluetooth keeps working.
3. Do not conclude "infrared only" from an unpaired remote. Many voice remotes send infrared until paired, then switch to Bluetooth. Pair it with its original device and repeat the test.

### 2. Pair with Windows

1. Find the pairing combination. The original device's own settings often show a diagram; generic combinations from the web are often wrong.
2. Unpair the remote from its original device, then power that device off so it cannot reconnect.
3. Hold the combination within about 20 cm of the adapter until the light flashes, and pair from Windows Bluetooth settings.

If the adapter shows up in Device Manager with no errors, do not install vendor drivers. Run `tools/btscan.cs` to tell "not advertising" apart from "Windows did not list it".

### 3. Read the real key codes

Run `tools/keylog.exe <log file> <hardware id>` after finding the hardware ID, for example `VID&02568A_PID&9869`, with `Get-PnpDevice`.

Expect some buttons to send nothing. If a button produces no event after a working test, tell the person plainly and put its function on another button. Do not keep promising it. `tools/gattprobe.cs` can check the vendor channel, but Windows keeps the HID service to itself, so its silence is suggestive rather than proof.

Sort the keys into two groups, because this drives the design:

- Keys a keyboard rarely has (such as F16 or F24) can be global hotkeys.
- Keys that collide with the keyboard (arrows, Enter, F1) must only be captured inside a mode. Otherwise the physical keyboard breaks.

### 4. Find each app's shortcuts from the app itself

Prefer built-in shortcuts over coordinates, since they survive layout changes. In order: the app's menus, its settings, then a read-only search of its bundle (Electron apps keep command tables in `resources/app.asar`, which `mmap` plus a regex can search without unpacking). Verify every shortcut in the running app. Documentation and memory go stale.

Try the app's native keys too, not only its documented shortcuts. WeChat's arrow keys step through conversations without any mouse, which was found only by testing.

Use mouse coordinates only when no shortcut exists. Anchor them to the window edge they follow, scale by DPI, and check with a pixel probe before clicking anything that could cause harm. Do not move the real cursor if you can avoid it. Many apps accept click and wheel messages sent with `PostMessage`, which leaves the cursor where it is.

### 5. Build the interaction model

Ask what the person wants each key to do in each app, and use their words. Users think in terms of "the thing I'm looking at", so state should follow what they see. Hidden modes they must remember cause reports of "the key doesn't work". The script's conventions, each of which came from a real failure:

- **Launcher menu**: the menu key opens an app list; up and down select, OK opens. Opening an app with a layout enters remote mode automatically.
- **Remote mode**: keys that collide with the keyboard are captured only here. Typing a character on the physical keyboard leaves the mode at once.
- **Sending is guarded**: OK starts in a state where it cannot send (choosing a conversation) and only sends once inside the conversation.
- **Queued keys**: `Critical` in the key handler, so a fast OK cannot run in the middle of another action and be misread as "send".

### 6. Test without causing harm

Follow `references/testing.md`. Test logic with simulated keys against Notepad. Test in real apps only on a safe target, such as WeChat's File Transfer. Tell the person what will move on screen before each test, and ask them to keep their hands off during it.

Report what was actually verified. Keep "passed in simulation", "passed in the real app" and "the person confirmed it" separate.

### 7. Deploy

1. Keep everything in one folder the person chooses.
2. Add a shortcut to the Windows Startup folder and launch through that shortcut once to verify it. Say plainly that a real reboot was not tested if it was not.
3. Report measured memory use. The script and voice helper take about 40 MB together, plus about 350 MB while the local voice model is loaded.

## Safety rules

- **API keys**: never ask for one in chat. The settings window has a password field and stores the key encrypted with Windows DPAPI.
- **Sending**: never send a message without agreement on the exact text and the target conversation.
- **Logs**: record key names, durations, counts and results only, never typed or recognized text.
- **Publishing**: leave out `keymap.ini`, logs, key files, recordings and window captures. They are personal. Replace device addresses with arguments.

## Voice input

Check the remote's own microphone before suggesting that the person buy one. A voice remote may already be streaming audio to Windows without appearing as a recording device. Windows treats it as a keyboard, and nothing decodes the audio.

1. Run `tools/voicecap.exe <log file> <hardware id>`. Hold the voice key, say a known sentence, and also count from one to ten.
2. Look for a steady stream of same-sized reports while the key is held. The X500 sends 21-byte reports at about 125 per second.
3. Work out the format from its structure. Eight descending nibbles at the start of each frame are SBC scale factors. Packet rate times samples per frame gives the sample rate.
4. Verify in stages: decode with `tools/sbcdec.py`, look for harmonic stripes with `tools/spectro.py`, then run a good recognizer. A weak recognizer's failure proves nothing, and recordings made without speech cannot confirm a decoder.

Other options, in order. Tell the person what each costs before installing anything:

1. An app's built-in dictation. It may be gated by account even when the shortcut binds successfully, so test it rather than assume it.
2. `Win+H`, which is unavailable on some systems.
3. Local SenseVoice through `scripts/setup-asr.ps1`. It is free and offline, and it was accurate on the X500's narrow-band audio. It needs a download and about 350 MB while loaded.
4. A cloud API through the settings window. Audio is uploaded and billed, and failures fall back to the local recognizer.

The offline recognizer built into Windows (`System.Speech`) recognized almost nothing from the same audio, so do not judge the microphone by it.
