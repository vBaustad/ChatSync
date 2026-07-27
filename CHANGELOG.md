# Changelog

## 1.2.0

### Patch 1.15.9 brought Edit Mode to Classic

- **The main chat window's position and size now come from Edit Mode.** The patch put the main
  window under Edit Mode's control, so it overrode whatever your profile set - which is why it
  stopped following your layout after the patch. Rather than fight it, ChatSync now leaves that
  one window to Edit Mode. Edit Mode layouts are **shared across your whole account**, so the
  main window already carries between characters on its own: set it once and you're done.
- **Everything else still comes from your profile,** exactly as before - tab names, docking,
  channels, message types, colours, transparency, font size, and the position and size of any
  **undocked** windows. Edit Mode doesn't touch any of that.

### Fixes

- **Settings open again.** Clicking Settings did nothing and threw an error - 1.15.9 changed how
  addons open their options page, and it now needs a numeric category ID rather than a name.
- Opening settings **during combat** no longer throws a "blocked" error. The game protects the
  options panel in combat, so ChatSync now just says to try again after the fight.
- Updated for game version **1.15.9**.

## 1.1.0

### Chat message pings
- Hear a **sound when a message comes in** — a new **Chat message pings** section in the
  settings, below your profiles.
- Pick a **sound** and click the speaker to preview it; the list also picks up sounds
  added by other addons you have installed.
- Choose what pings: **Whisper**, **Guild**, **Party**, and/or specific **custom channels**.
- Whispers ping by default, and your own messages never ping. Turn any of it off in the
  same place.

### Other
- New **What's New** window after an update, re-openable with `/cs news`.
- Settings page cleanup — aligned buttons and tidier dropdowns.

## 1.0.1

- Added a "Buy me a coffee" support link to the settings page.

## 1.0.0

- Initial release.
- Account-wide chat-window profiles: tabs, channels, message types, names, colors,
  transparency, font size, sizes and positions.
- New-character prompt to pick a profile (or auto-apply the default, or do nothing).
- Auto-update: the character a profile was saved from keeps it current on change and
  on logout; plus a one-click "Save changes" button.
- Minimap button and a settings page (`/chatsync`, `/csync`, `/cs`).
