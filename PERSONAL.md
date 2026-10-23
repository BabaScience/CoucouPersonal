# Coucou — personal build

A fork of [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) customized for one person.
Everything Claude does here runs on a **Claude subscription** (through Claude Code), never an API key.

## Setup

1. Install: `./scripts/install-personal.sh` (builds and installs `~/Applications/Coucou Personal.app`).
2. Sign in to Claude: run `claude setup-token` in Terminal, then paste the token in **Coucou → Claude**
   and press **Test connection**.
3. For the screen assistant, allow **Coucou Personal** in System Settings → Privacy & Security →
   **Screen & System Audio Recording** and **Accessibility** (buttons on the **Screen** page), then
   reopen it. Builds are signed with the local "Coucou Personal Signing" certificate (login
   Keychain), so these permissions and the Keychain approval survive rebuilds. If that certificate
   is ever missing, the script signs ad-hoc and the permissions must be reset
   (`tccutil reset ScreenCapture com.greatbamba.coucou`, same for `Accessibility`) and granted again.

## What's added

- **YouTube** (sidebar → Mine → YouTube): Inspiration Illimitée's public numbers (subscribers, the
  latest 15 uploads with views) and a Claude chat with one-click actions: understand my channel,
  market research, video ideas, write a script, title/description/tags.
  The studio folder is `~/CoucouStudio/inspiration_illimitee/`: `CLAUDE.md` is Claude's memory of
  the channel, `channel.md` the latest numbers, and scripts, research and ideas are saved in their
  folders. Put skills in `.claude/skills/` and Claude can use them.
- **Screen** (⌃⌥S from anywhere): ask a question and Claude looks at your screen.
  *Guide me* points at each step with a pulsing marker and waits for your click (or **Next**).
  *Do it* clicks and types for you, and stops to ask before passwords, payments, sending, posting
  or deleting. **Stop** ends it at any time.
- **Claude**: the subscription token (Keychain), a connection test, and the models for each feature.

## How it works

- `Sources/App/ClaudeCLI.swift` runs `claude -p` with stream-json output. `ANTHROPIC_API_KEY` is
  removed from its environment, so billing always goes to the subscription.
- `Sources/App/YouTubeStudio.swift`: the channel feed, the studio folder and the YouTube page.
- `Sources/App/ScreenAgent.swift`: the assistant, its panel and the pointer.
  `Sources/App/ScreenTool.swift`: `Coucou --screen-tool …`, the command Claude calls
  (`~/CoucouStudio/.screen/bin/coucou-screen`). That process is credited to Claude Code by macOS,
  so it only passes each command to the running app, which captures (ScreenCaptureKit, at 1568 px
  so Claude Code doesn't shrink it), clicks and types with its own permissions. Requests are served
  only from the session's folder while a session runs.
- Separate app identity (`com.greatbamba.coucou`) and Keychain entries from the official Coucou; the
  auto-updater is off so it is never replaced by an official release.
- Builds with Xcode 16.1 (Swift 5 language mode for Debug, a few compiler workarounds).
