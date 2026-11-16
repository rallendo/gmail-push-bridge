# Gmail Push Bridge for Apple Mail (macOS)

A lightweight native macOS Menu Bar utility written in Swift that brings **instant Gmail push** to **Apple Mail**.

It maintains a persistent, sleep/wake-aware **IMAP `IDLE`** TLS connection to `imap.gmail.com:993` using Apple's `Network.framework`. The instant a new email lands in your Gmail `INBOX`, it triggers Apple Mail to fetch via AppleScript—without opening windows or interrupting your workflow.

Supports both **Sign in with Google (OAuth 2.0 + PKCE / Passkey via `XOAUTH2`)** and **Google App Passwords**.

---

## Architecture

- **[GmailPushBridgeApp.swift](Sources/GmailPushBridge/GmailPushBridgeApp.swift)** — Menu Bar UI (`MenuBarExtra`) with no Dock icon (`LSUIElement`), status indicator, quick actions, and Settings window controller.
- **[GoogleOAuthManager.swift](Sources/GmailPushBridge/GoogleOAuthManager.swift)** — Native RFC 8252 Desktop OAuth 2.0 + PKCE (`S256`) flow with an ephemeral loopback listener (`http://127.0.0.1:<port>/oauth2callback`), automatic token refresh, and `AUTHENTICATE XOAUTH2` SASL encoding.
- **[IMAPIdleClient.swift](Sources/GmailPushBridge/IMAPIdleClient.swift)** — Zero-dependency IMAP `IDLE` state machine over `NWConnection` (TLS + TCP keepalives). Supports both `AUTHENTICATE XOAUTH2` and `LOGIN`, tracks `EXISTS` and `EXPUNGE` counts so archiving followed by a new email still triggers push, and refreshes `IDLE` every 14 minutes.
- **[AppleMailBridge.swift](Sources/GmailPushBridge/AppleMailBridge.swift)** — Runs only when `Mail.app` is open (never launches Mail unexpectedly). Executes `check for new mail` + `synchronize` for your configured Apple Mail account, with optional fallback to all accounts.
- **[SystemMonitor.swift](Sources/GmailPushBridge/SystemMonitor.swift)** — Listens to `NSWorkspace.didWakeNotification` and `NWPathMonitor` to immediately reconnect and fetch when your Mac wakes from sleep or changes Wi-Fi networks.
- **[KeychainStore.swift](Sources/GmailPushBridge/KeychainStore.swift)** — Stores OAuth 2.0 refresh/access tokens and App Passwords securely in the macOS Keychain (`com.gmailpushbridge.app`).
- **[LaunchAgentManager.swift](Sources/GmailPushBridge/LaunchAgentManager.swift)** — Optional one-click **Start at Login** toggle (`~/Library/LaunchAgents/com.gmailpushbridge.app.plist`).
- **[UpdateManager.swift](Sources/GmailPushBridge/UpdateManager.swift)** — Automatic background update checker and seamless in-place updater powered by GitHub Releases. Downloads release archives, validates signatures, clears Gatekeeper quarantine, atomically swaps the `.app` bundle, and relaunches.

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

### 3. Authenticate with Gmail (Choose Either Method)

#### Method A: Sign in with Google (OAuth 2.0 / Passkey)
1. In [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials), click **Create Credentials → OAuth client ID** and choose **Application type: Desktop app**.
2. Download the JSON file (or copy the Client ID & Secret).
3. In Gmail Push Bridge **Settings**, click **Import client_secret.json…** (or paste your Client ID & Secret).
4. Click **Sign in with Google (Passkey / Browser)** — Safari/Chrome will open so you can sign in with your Passkey / Touch ID. Your Gmail address and OAuth tokens are saved automatically to your macOS Keychain.

#### Method B: Google App Password (No Google Cloud Setup)
1. Switch the picker in **Settings** to **Google App Password**.
2. Enter your **Gmail Address**, click **Get App Password ↗** ([myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)), and paste the 16-character code.
3. Click **Save & Connect**.

### 4. Target Your Apple Mail Account
1. Click **Detect from Mail** to select your Gmail account name in Apple Mail (e.g., `Google`).
2. Click **Test Apple Mail Trigger** once—macOS will prompt you to allow `Gmail Push Bridge` to control `Mail`. Click **Allow**.
