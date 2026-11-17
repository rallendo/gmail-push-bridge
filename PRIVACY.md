# Privacy Policy for Gmail Push Bridge

**Effective Date:** November 16, 2026  
**Last Updated:** November 16, 2026  

This Privacy Policy explains how **Gmail Push Bridge** ("we", "our", or "the Application"), developed by Rick Allendoerfer, accesses, handles, and protects your information when you use our open-source macOS utility.

---

## 1. Zero-Cloud / 100% Local-First Architecture

Gmail Push Bridge is designed with privacy at its core:
- **No Third-Party Servers:** The Application connects directly from your Mac to Google's official IMAP mail servers (`imap.gmail.com:993`) via TLS. We operate no intermediate cloud servers, proxies, analytics servers, or databases.
- **Local Credential Storage:** OAuth tokens (access tokens, refresh tokens) and App Passwords are stored exclusively in your macOS Keychain under your local user account (`com.gmailpushbridge.app`). They never leave your device.
- **No Analytics or Telemetry:** The Application does not collect, track, or transmit any analytics, diagnostics, crash reports, or user behavior metrics.

---

## 2. Google User Data & OAuth Scopes

When you connect your Google Account via Sign in with Google (OAuth 2.0 with PKCE), the Application requests access to the following scope:

- **`https://mail.google.com/`** (Restricted Scope: Full IMAP access)  
  *Purpose:* Required by Google's IMAP server to perform SASL `XOAUTH2` authentication and initiate an IMAP `IDLE` state to listen for real-time mailbox count changes (`EXISTS` notifications).
- **`email`**  
  *Purpose:* Used strictly to detect and populate your Gmail email address in the Application's settings UI for connection targeting.

### What Data We Access
- **Mailbox Notification Counts:** The Application monitors IMAP status events (such as `EXISTS` counts) signaling that a new message has arrived in your `INBOX`.
- **Email Content:** The Application **does not read, store, index, or parse the body, headers, or attachments of your emails**. When a new email is signaled via IMAP `IDLE`, the Application issues a local AppleScript trigger instructing macOS Apple Mail (`Mail.app`) to synchronize directly with your Gmail account.

---

## 3. Google API Services User Data Policy & Limited Use Disclosure

Gmail Push Bridge's use and transfer to any other app of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the **Limited Use** requirements.

Specifically:
1. **No External Transfer:** We do not transfer, transmit, or disclose Google user data to any external parties or servers.
2. **No Advertising:** Google user data is never used or transferred for serving advertisements, retargeting, interest-based advertising, or personalized marketing.
3. **No Human Access:** No human (including the developer) can read, view, or access your Google user data or emails.
4. **No AI Training:** Google user data is not used to train machine learning or artificial intelligence models.

---

## 4. Data Retention and Deletion

- **Retention:** All OAuth tokens and local preferences are retained locally on your Mac only for as long as you keep the Application configured.
- **Immediate Deletion / Revocation:**
  - You can delete stored credentials at any time in the Application's Settings window by clicking **Sign Out** (which removes OAuth tokens from your macOS Keychain and triggers best-effort token revocation via Google's revocation endpoint) or **Remove App Password** (which removes your stored App Password from Keychain).
  - You can revoke the Application's access at any time from your Google Account security dashboard at [https://myaccount.google.com/permissions](https://myaccount.google.com/permissions).
  - Uninstalling the Application and deleting Keychain entries removes all traces of the Application from your device.

---

## 5. Security

The Application uses industry-standard security practices:
- **Transport Security:** All network communications with Google IMAP servers use TLS 1.3/1.2 encryption (`imap.gmail.com` / `imap.googlemail.com` on port `993`).
- **Keychain Access Control:** Sensitive tokens and App Passwords are stored locally via macOS Keychain Services (`kSecClassGenericPassword`, service `com.gmailpushbridge.app`, accessibility `kSecAttrAccessibleAfterFirstUnlock`) in your user login keychain.

---

## 6. Open Source Transparency

The complete source code of Gmail Push Bridge is open source and available for public inspection at:  
[https://github.com/rallendo/gmail-push-bridge](https://github.com/rallendo/gmail-push-bridge)

---

## 7. Contact Us

If you have any questions, concerns, or requests regarding this Privacy Policy or your data, please contact:

**Developer:** Rick Allendoerfer  
**Email:** [rick.allendoerfer@gmail.com](mailto:rick.allendoerfer@gmail.com)  
**Project Repository:** [https://github.com/rallendo/gmail-push-bridge](https://github.com/rallendo/gmail-push-bridge)  
