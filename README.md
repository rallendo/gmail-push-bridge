# Gmail Push Bridge for Apple Mail (macOS)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg)](https://apple.com/macos)
[![Sponsor on GitHub](https://img.shields.io/badge/Sponsor-%E2%9D%A4-pink?logo=github)](https://github.com/sponsors/rallendo)

A lightweight native macOS Menu Bar utility written in Swift that brings **instant Gmail push** to **Apple Mail**.

It maintains a persistent, sleep/wake-aware **IMAP `IDLE`** TLS connection to `imap.gmail.com:993` using Apple's `Network.framework`. The instant a new email lands in your Gmail `INBOX`, it triggers Apple Mail to fetch via AppleScript—without opening windows or interrupting your workflow.

Supports both **Sign in with Google (OAuth 2.0 + PKCE / Passkey via `XOAUTH2`)** and **Google App Passwords**.

---

## Architecture

- **[GmailPushBridgeApp.swift](Sources/GmailPushBridge/GmailPushBridgeApp.swift)** — Menu Bar UI (`MenuBarExtra`) with no Dock icon (`LSUIElement`), status indicator, quick actions, and Settings window controller.
- **[GoogleOAuthManager.swift](Sources/GmailPushBridge/GoogleOAuthManager.swift)** — Native RFC 8252 Desktop OAuth 2.0 + PKCE (`S256`) flow with an ephemeral loopback listener (`http://127.0.0.1:<port>/oauth2callback`), automatic token refresh, and `AUTHENTICATE XOAUTH2` SASL encoding.
- **[IMAPIdleClient.swift](Sources/GmailPushBridge/IMAPIdleClient.swift)** — Zero-dependency IMAP `IDLE` state machine over `NWConnection` (TLS + TCP keepalives). Supports both `AUTHENTICATE XOAUTH2` and `LOGIN`, tracks `EXISTS` and `EXPUNGE` counts so archiving followed by a new email still triggers push, and refreshes `IDLE` every 14 minutes.
- **[AppleMailBridge.swift](Sources/GmailPushBridge/AppleMailBridge.swift)** — Runs only when `Mail.app` is open (never launches Mail unexpectedly). Executes `check for new mail` + `synchronize` for your configured Apple Mail account, with optional fallback to all accounts.
- **[SystemMonitor.swift](Sources/GmailPushBridge/SystemMonitor.swift)** — Listens to `NSWorkspace` wake, Apple Mail launch/quit notifications, and `NWPathMonitor` to pause IMAP `IDLE` while Mail is closed and immediately reconnect + fetch when Mail opens, the Mac wakes from sleep, or Wi-Fi changes.
- **[KeychainStore.swift](Sources/GmailPushBridge/KeychainStore.swift)** — Stores OAuth 2.0 refresh/access tokens and App Passwords securely in the macOS Keychain (`com.gmailpushbridge.app`).
- **[LaunchAgentManager.swift](Sources/GmailPushBridge/LaunchAgentManager.swift)** — Optional one-click **Start at Login** toggle (`~/Library/LaunchAgents/com.gmailpushbridge.app.plist`).
- **[UpdateManager.swift](Sources/GmailPushBridge/UpdateManager.swift)** — Automatic background update checker and in-place updater powered by GitHub Releases. Verifies HTTPS GitHub download origins, checks release archive SHA-256 digests when provided, validates bundle code signatures (`SecStaticCodeCheckValidity`) prior to clearing Gatekeeper quarantine, atomically replaces the `.app` bundle via positional arguments, and relaunches.

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

#### Method A: Sign in with Google (OAuth 2.0 / Passkey — Recommended)
Run with your own free Google Cloud Desktop credentials for maximum privacy.
👉 **See the complete 2-minute walkthrough: [OAUTH_SETUP.md](OAUTH_SETUP.md)**

1. Create a free project at [Google Cloud Console](https://console.cloud.google.com/projectcreate) and enable the [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com).
2. Configure **OAuth consent screen** (User type: *External*, add your Gmail under *Test users*, leave status in *Testing*).
3. In **Credentials**, click **Create Credentials → OAuth client ID** and choose **Application type: Desktop app**. Download the JSON file.
4. In Gmail Push Bridge **Settings**, click **Import client_secret.json…** (or paste Client ID & Secret).
5. Click **Sign in with Google (Passkey / Browser)** — Safari/Chrome opens for Touch ID / Passkey authentication. Tokens are stored securely in your macOS Keychain.

#### Method B: Google App Password (Zero Google Cloud Setup)
1. Switch the picker in **Settings** to **Google App Password**.
2. Enter your **Gmail Address**, click **Get App Password ↗** ([myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)), and paste the 16-character code.
3. Click **Save & Connect**.

### 4. Target Your Apple Mail Account
1. Click **Detect from Mail** to select your Gmail account name in Apple Mail (e.g., `Google`).
2. Click **Test Apple Mail Trigger** once—macOS will prompt you to allow `Gmail Push Bridge` to control `Mail`. Click **Allow**.

---

## Feature Roadmap & Community Upvoting

Help shape future releases! React with a **👍 (+1)** on any GitHub issue below to vote for features you want to see:

| Feature | Description | Status & Upvoting |
| :--- | :--- | :---: |
| **Yahoo Mail & AOL Support** | Instant push for `imap.mail.yahoo.com` using Yahoo App Passwords. | [👍 Upvote Issue #3 ↗](https://github.com/rallendo/gmail-push-bridge/issues/3) |
| **Multi-Account Monitoring** | Concurrently watch multiple mailboxes (e.g., personal + work + Yahoo) in one running app. | [👍 Upvote Issue #4 ↗](https://github.com/rallendo/gmail-push-bridge/issues/4) |
| **Microsoft Outlook & Office 365** | Modern Auth (OAuth 2.0 / MSAL) push bridge for Outlook.com and Office 365. | [👍 Upvote Issue #5 ↗](https://github.com/rallendo/gmail-push-bridge/issues/5) |
| **Custom & Self-Hosted IMAP** | Configure custom host, port, and security for Fastmail, Dovecot, and private servers. | [👍 Upvote Issue #6 ↗](https://github.com/rallendo/gmail-push-bridge/issues/6) |
| **Auto-Disconnect When Apple Mail Closes** | Automatically pause IMAP IDLE when Mail.app quits and reconnect + fetch when Mail launches. | ✅ Shipped in v1.2.0 ([Issue #17 ↗](https://github.com/rallendo/gmail-push-bridge/issues/17)) |
| **macOS Focus Filter & Quiet Hours** | Auto-pause push monitoring during Do Not Disturb / Sleep Focus or scheduled Quiet Hours. | [👍 Upvote Issue #18 ↗](https://github.com/rallendo/gmail-push-bridge/issues/18) |
| **Low Power Mode Awareness** | Widen debounce intervals or optionally pause IDLE when macOS Low Power Mode is active. | [👍 Upvote Issue #19 ↗](https://github.com/rallendo/gmail-push-bridge/issues/19) |
| **Two-Way Read & Archive Sync** | Trigger debounced Apple Mail sync when emails are read or archived on another device to clear stale badges. | [👍 Upvote Issue #20 ↗](https://github.com/rallendo/gmail-push-bridge/issues/20) |
| **VIP & Primary-Only Push Filtering** | Filter incoming pushes by Gmail category/label or VIP sender so promotions don't wake Apple Mail. | [👍 Upvote Issue #21 ↗](https://github.com/rallendo/gmail-push-bridge/issues/21) |
| **Native Auth & Error Notifications** | Post a macOS Notification Center alert with a Reconnect action if OAuth or App Password auth fails. | [👍 Upvote Issue #22 ↗](https://github.com/rallendo/gmail-push-bridge/issues/22) |
| **macOS Shortcuts & Global Hotkey** | Expose Trigger Fetch, Pause, and Resume actions to macOS Shortcuts, Spotlight, and a global hotkey. | [👍 Upvote Issue #23 ↗](https://github.com/rallendo/gmail-push-bridge/issues/23) |
| **Connection Health & Diagnostics** | View session uptime, daily push counts, reconnect stats, and one-click redacted diagnostic logs. | [👍 Upvote Issue #24 ↗](https://github.com/rallendo/gmail-push-bridge/issues/24) |

Have another idea? [Submit a Feature Request ↗](https://github.com/rallendo/gmail-push-bridge/issues/new?template=feature_request.yml) or join the community on [GitHub Discussions ↗](https://github.com/rallendo/gmail-push-bridge/discussions).

---

## Support & Sponsorship

If you find Gmail Push Bridge helpful and it saves you time, consider [sponsoring the project on GitHub](https://github.com/sponsors/rallendo) or buying me a cup of coffee. Your support helps maintain the project, keep up with macOS updates, and add new features! ☕️❤️
