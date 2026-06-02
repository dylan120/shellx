# ShellX Electron

This is the TypeScript/Electron implementation of ShellX. The legacy Swift/Xcode app has been removed from the repository. Terminal rendering and input are handled by xterm.js and Chromium, with PTY access through node-pty.

## Commands

```bash
npm install
npm run dev
npm run start
npm run start:app
npm run typecheck
npm run build
npm run package:dir
```

`npm run start` opens the desktop app against a production renderer build through Electron. `npm run package:dir` creates a local `.app` bundle under `release/mac-arm64/ShellX.app`, applies ad-hoc signing, and clears extended attributes. `npm run start:app` packages and opens that `.app` bundle.

## Current Scope

- macOS tool-style UI with session tree, detail editor, terminal workbench, script manager, batch execution and settings views.
- Session/folder/script/settings persistence in the Electron app support directory.
- Local terminal tabs through the user's default shell.
- SSH tabs through `/usr/bin/ssh`, including host, port, username, private key, startup command and remote forwarding options.
- xterm.js fit/resize, fixed Chromium page zoom, tab switching, unread markers, close confirmation and process cleanup.
- Script library editing and non-interactive batch script execution over `/usr/bin/ssh` for key/agent based sessions.
- Data import/export, theme settings, scrollback settings and optional selection-to-clipboard.
- macOS Keychain helper IPC is used for password storage and automatic password prompt fill.
- DMG packaging, local install helper and manual GitHub Release publishing live in the root `scripts/` directory.
