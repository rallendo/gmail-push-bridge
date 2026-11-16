# Gmail Push Bridge for Apple Mail (macOS)

A lightweight native macOS Menu Bar utility written in Swift that brings **instant Gmail push** to **Apple Mail**.

It maintains a persistent, sleep/wake-aware **IMAP `IDLE`** TLS connection to `imap.gmail.com:993` using Apple's `Network.framework`. The instant a new email lands in your Gmail `INBOX`, it triggers Apple Mail to fetch via AppleScript—without opening windows or interrupting your workflow.

---

## Architecture

- **[GmailPushBridgeApp.swift](Sources/GmailPushBridge/GmailPushBridgeApp.swift)** — Menu Bar UI (`MenuBarExtra`) with no Dock icon (`LSUIElement`), status indicator, quick actions, and Settings window controller.
- **[IMAPIdleClient.swift](Sources/GmailPushBridge/IMAPIdleClient.swift)** — Zero-dependency IMAP `IDLE` state machine over `NWConnection` (TLS + TCP keepalives). Tracks `EXISTS` and `EXPUNGE` counts so archiving followed by a new email still triggers push, and refreshes `IDLE` every 14 minutes.
- **[AppleMailBridge.swift](Sources/GmailPushBridge/AppleMailBridge.swift)** — Runs only when `Mail.app` is open (never launches Mail unexpectedly). Executes `check for new mail` + `synchronize` for your configured Apple Mail account, with optional fallback to all accounts.
- **[SystemMonitor.swift](Sources/GmailPushBridge/SystemMonitor.swift)** — Listens to `NSWorkspace.didWakeNotification` and `NWPathMonitor` to immediately reconnect and fetch when your Mac wakes from sleep or changes Wi-Fi networks.
- **[GoogleOAuthManager.swift](Sources/GmailPushBridge/GoogleOAuthManager.swift)** — Handles Google OAuth 2.0 with PKCE and SASL `XOAUTH2` authentication for browser-based sign-in.
- **[KeychainStore.swift](Sources/GmailPushBridge/KeychainStore.swift)** — Securely stores Google App Passwords and OAuth tokens in the macOS Keychain (`com.gmailpushbridge.app`).
- **[LaunchAgentManager.swift](Sources/GmailPushBridge/LaunchAgentManager.swift)** — Optional one-click **Start at Login** toggle (`~/Library/LaunchAgents/com.gmailpushbridge.app.plist`).

---

## Quick Start

### 1. Build the `.app` Bundle
```zsh
./scripts/build-app.sh
```
This builds the release binary and packages `dist/GmailPushBridge.app`.

### 2. Launch the App
```zsh
open dist/GmailPushBridge.app
```
*(Optional: drag `dist/GmailPushBridge.app` to `/Applications` first so its path never changes if you enable "Start automatically at login".)*

### 3. Configure Credentials
1. Click the envelope/bolt icon in your macOS **Menu Bar** → **Settings & Credentials…** (`⌘,`).
2. Enter your **Gmail Address**.
3. Click **Get App Password ↗** (opens `https://myaccount.google.com/apppasswords`), create an App Password, and paste the 16-character code.
4. Click **Detect from Mail** to select your Gmail account name in Apple Mail (e.g., `Google`), then click **Save & Connect**.
5. Click **Test Apple Mail Trigger** once—macOS will prompt you to allow `Gmail Push Bridge` to control `Mail`. Click **Allow**.
