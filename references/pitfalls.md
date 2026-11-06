# Pitfalls

Each of these caused a real failure while building this setup.

## AutoHotkey v2

| Symptom | Cause | Fix |
|---|---|---|
| Script stops at startup with `Invalid base` | `base` is reserved in object literals | Use another property name, such as `url` |
| Test script does nothing and gives no result | `log` is a built-in function, so `log .= ...` fails at load | Use another variable name |
| An action stored in an object fails when called | `obj.run(k)` passes `obj` as a hidden first argument | Call `obj.run.Call(k)` |
| A second key press is lost, or OK runs in the middle of another action | Hotkey threads interrupt each other, and each hotkey runs one thread at a time | Put `Critical("On")` at the top of the key handler so keys queue |
| Hotkey's `Send` triggers itself | Keyboard hook is not forced | Prefix the hotkey with `$` |
| Simulated keys do not fire another script's hotkeys | Sends default to level 0 | Use `SendLevel(1)` |
| An error dialog appears on the person's screen | A running script hit a load or runtime error | Start with `/ErrorStdOut`, redirect stderr, and list `#32770` windows afterwards |
| Raw input registration fails for every device | A collection with usage 0 was registered without a flag, and it failed the whole batch | Add `RIDEV_PAGEONLY` for usage 0, and register one at a time |
| A helper program never sees a key | A running script's hook swallows the key before raw input gets it | Detect the event another way. The voice helper watches the audio stream instead of F24 |
| A hold-to-talk key turns dictation on and off repeatedly | The key auto-repeats while held | Do not toggle on the key. Let the data stream decide when speech starts and stops |

## Speed

Reading the screen with `PixelGetColor` takes about 13 ms per call. A column scan of 130 to 150 points took about 2 seconds, and the person reported the remote as slow. Copy the whole column with `BitBlt` once and read the buffer; this takes about 15 ms. See `ReadColumn` in the script.

Writing a log line with `FileAppend` also costs about 13 ms. Buffer lines and flush on a timer.

Log the script's own time for each action, so slowness can be attributed to the script, the remote or the app.

## Input and focus

- **Chinese input methods swallow simulated letters.** Sent `x` goes into the pinyin bar, and the next Enter commits it instead of adding a line. The test looks broken while the script is fine. Use digits, or turn the input method off for the test window.
- **Foreground switching can fail while screen control is running.** Failures clustered around computer-use activity and stopped afterwards. This is an inference, not proven. Verify with `WinWaitActive`, retry with an Alt tap, `SwitchToThisWindow`, then minimize and restore, and log what held the foreground.
- **Moving the mouse then scrolling at once can lose the scroll.** Electron apps need time to register the hover. Wait about 60 ms.
- **Pop-up panels are separate windows.** `WinGetPos("A")` returns the panel once it opens, so coordinates shift. Remember the main window.

## App behaviour

- **WeChat 4.x** draws its own interface. Arrow keys do not select emoji; they switch the emoji category.
- **WeChat's arrow keys work in the conversation list.** With no conversation open, they move a gray highlight. With one open and the input box focused, they switch straight to the next conversation. `Tab` loses this focus, so click the input box to restore it.
- **Enter on a highlighted WeChat row opens a separate window.** Click the row instead to keep the conversation in the main window.
- **Do not fall back to "click the first row".** With no conversation open there is no green row to anchor to, and the first row can be a pinned item that opens a side panel. This caused the "stuck" report that led to the arrow-key design.
- **WeChat accepts `PostMessage` clicks and wheel events**, so the cursor can stay still. Emoji selection is the exception, because it depends on real hover.
- **WeChat's favourites tab** may send on a single click (not confirmed). Force the normal emoji tab each time the panel opens.
- **WeChat closes a conversation** if its already selected row is clicked again. Check for the green selected row first.
- **Launching a shortcut for a running WeChat** can open a second instance with a login prompt. This happened through the app launcher, and also when the key was pressed again while WeChat was still starting. If the process exists, wait for its window or restore the hidden one. Never start another.
- **Passing over list rows in WeChat** marks conversations as read when they open, and may open mini-programs (not confirmed). Warn the person.
- **`f` is not universal.** A site may ignore it even though the key reaches the page. Log the key in the page, then try double-clicking the player and compare the fullscreen button's class, because an embedded browser may block real fullscreen.
- **Electron main process names can mislead.** ChatGPT and Codex may be one app (`ChatGPT.exe` inside the `OpenAI.Codex` package), so check before planning separate launch keys.
- **Global dictation in an app can be gated.** The binding may be stored correctly and still do nothing, so read the app's state file before blaming the remote.
- **Closing a window may not quit the app.** Compare the process start time with the config change to prove a restart happened.

## Building and tools

- `csc.exe` can fail with `CS1619` when the temp path or working path is too long. Point `TEMP` and `TMP` at a short folder and build there.
- Windows PowerShell 5.1 cannot subscribe to WinRT events. Use compiled C#.
- `Add-Type` rejects `.winmd` references. Call `csc.exe` directly.
- `AsTask()` needs a `Windows` reference that `WinMetadata` does not supply. Poll `op.Status` and call `GetResults()`.
- Windows gives the HID GATT service `AccessDenied`, so a GATT probe cannot see ordinary keys. Silence on it does not prove a button sends nothing over HID.
- A `winexe` build has no console. Setting `Console.OutputEncoding` crashes it, so write results to a file.
- `tar.exe` hung on a `.tar.bz2` in a folder with non-ASCII characters, using almost no CPU. Python's `tarfile` unpacked the same file in 22 seconds.
- Do not guess a download's size from memory. The full SenseVoice archive is about 1 GB, while the quantized one is 155 MB. Check `Content-Length` before promising a size.
- Restarting the script turns remote mode off, and to the person it looks as if the keys stopped working. Warn them before restarting it.
