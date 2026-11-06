# Testing

Testing here moves a real person's mouse, keyboard focus and windows, and the keys can send real messages. Work through the safest level that answers the question.

## Levels

1. **Read-only.** Process lists, logs, window lists, app bundle searches. No warning needed.
2. **Simulated keys against Notepad.** Make a copy of the script with the target app replaced by `notepad.exe`, in a separate folder, so the real config is untouched. Give it a separate `keymap.ini`. Stop the real script first, because both would react to the same keys.
3. **The real app, in harmless ways.** Switching conversations, scrolling, opening and closing panels.
4. **Actions with effects.** Sending, starting voice calls. Do these only with agreement, on a safe target such as WeChat's File Transfer, and with text agreed in advance.

Never run simulated keys against the window hosting the current conversation, because they may land in its input box. Leave those keys for the person to try.

## Before a test

Tell the person how long it takes and what will happen on screen, such as windows switching, volume changing or apps opening, and ask them not to touch the keyboard or mouse. If they stop a screen-control action, stop and wait for them.

Restore what you changed: volume, mouse position, effort settings, the selected conversation. Close only the windows you opened, identified by process ID.

## Simulating the remote

Send keys from a second AutoHotkey script with `SendLevel(1)` so the first script's hotkeys fire:

```autohotkey
SendLevel(1)
SetKeyDelay(30, 30)
SendEvent("{F16}")
```

Assert on facts rather than appearance:

- Notepad text with `ControlGetText("Edit1", win)`
- Caret position with message `0xB0` and first visible line with `0xCE`
- Window size to detect real fullscreen in a browser
- `WinActive` and process lists to detect focus changes or a second instance

Send a burst of keys in one `SendEvent` to catch ordering bugs. A pause between every key hides them.

## Mocking a cloud API

Test the upload path with a small local HTTP server and a fake key, and never with a real key. Check the `Authorization` header, the form fields, the audio bytes, and that a 401 falls back to offline recognition. Confirm the key does not appear in plain text in any file.

Keep "the mock passed" separate from "the real service works".

## Reading results

When the person reports a problem, read `keys-debug.log` before theorizing. It often settles the question: a missing mode entry means the keys were never captured, and a default action in place of an app action means that app was not in the foreground.

If a test fails, find out whether the test or the script is wrong before changing the script. Several failures here came from the test: an input method swallowing a letter, too short a wait, and Notepad inserting a tab for `Ctrl+Tab`.
