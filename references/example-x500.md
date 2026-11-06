# Worked example: projector voice remote

One real setup, with a 坚影 X500 projector remote and a Realtek Bluetooth 5.0 USB adapter on Windows 10. Other remotes will differ, so measure yours.

## Pairing

The projector's own settings showed the combination: hold the keys either side of OK until the light flashes. The generic `Back + Home` from the web did nothing. Before pairing, direction keys stopped when the tip was covered (infrared); after pairing they worked covered (Bluetooth).

Windows listed it as `语音助手` with hardware ID `VID&02568A_PID&9869`.

## Keys

| Button | Windows receives | Collides with keyboard |
|---|---|---|
| Arrows | Arrow keys | Yes |
| OK | Enter | Yes |
| Menu | AppsKey | Rarely |
| Settings | F2 | Yes |
| Source | F1 | Yes |
| F+ / F- | F5 / F6 | Yes |
| Key between F- and F+ | F16 | No |
| Voice | F24, plus 21-byte packets on a vendor collection | No |
| Back, Home, Volume, Mute | Nothing seen | Not applicable |
| Power | Not tested, because it might sleep the PC | Not applicable |

## App layouts

**Chrome:** up and down scroll with the wheel, left and right change system volume, OK is the media key, Source toggles video fullscreen (`f`, or a double-click on sites listed in `VIDEO_DOUBLE_CLICK_SITES`), Settings moves to the next tab.

**WeChat 4.x:** with the mouse over the friend list, up and down step between friends and open each immediately; with the mouse over the chat, they scroll history. Left returns to the list, right opens emoji (arrows move, OK inserts), and OK sends.

**Grok Bot:** the same logic, with right starting voice chat.

**ChatGPT:** `Ctrl+Alt+[` and `Ctrl+Alt+]` step conversations, `Ctrl+N` starts one, and `Ctrl+Shift+M` opens the effort panel, whose slider moves with left and right. `Ctrl+Tab` switches tabs, not conversations.

**Claude:** `Ctrl+Tab` and `Ctrl+Shift+Tab` step sessions and `Ctrl+N` starts one. No effort shortcut was found in its menus, so right is unused.

## Verification status

The remote keys and most of these layouts were exercised with simulated keys or by the original user. Sending in WeChat and Grok, Grok's voice button, and all of the Claude layout were not observed directly by the author. Recheck coordinates on any other screen, DPI or list width.
