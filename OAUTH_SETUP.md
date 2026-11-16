# Google OAuth 2.0 Setup Guide (BYOC)

> **Time required:** ~2 minutes  
> **Cost:** $0 (100% Free)  
> **Why do this?** Running your own Google Cloud Desktop credentials keeps your data 100% private, requires no third-party trust, and bypasses any Google verification delays.

---

## Quick Navigation
1. [Step 1: Create a Google Cloud Project](#step-1-create-a-google-cloud-project)
2. [Step 2: Enable the Gmail API](#step-2-enable-the-gmail-api)
3. [Step 3: Configure the OAuth Consent Screen](#step-3-configure-the-oauth-consent-screen)
4. [Step 4: Create Desktop OAuth Credentials](#step-4-create-desktop-oauth-credentials)
5. [Step 5: Connect in Gmail Push Bridge](#step-5-connect-in-gmail-push-bridge)
6. [Troubleshooting & FAQs](#troubleshooting--faqs)

---

### Step 1: Create a Google Cloud Project
1. Open the [Google Cloud Resource Manager / New Project](https://console.cloud.google.com/projectcreate) page.
2. Enter a project name like **`Gmail Push Bridge`**.
3. Leave *Organization* as **No organization** (or your personal domain).
4. Click **Create** and wait 5–10 seconds for the project to provision.

---

### Step 2: Enable the Gmail API
1. Navigate directly to the [Gmail API Library page](https://console.cloud.google.com/apis/library/gmail.googleapis.com).
2. Ensure your new **Gmail Push Bridge** project is selected in the top project dropdown.
3. Click the blue **Enable** button.

---

### Step 3: Configure the OAuth Consent Screen
1. Go to [APIs & Services → OAuth consent screen](https://console.cloud.google.com/apis/credentials/consent).
2. Choose **External** under User Type, then click **Create**.
3. Fill in only the 3 required fields:
   * **App name:** `Gmail Push Bridge`
   * **User support email:** Choose your Gmail address from the dropdown.
   * **Developer contact information:** Enter your Gmail address.
4. Click **Save and Continue**.
5. **Scopes:** You don't need to add anything here manually (the app requests the IMAP scope dynamically). Click **Save and Continue**.
6. **Test users:**
   * Click **+ Add Users**.
   * Enter your Gmail address (the one you want to push to Apple Mail).
   * Click **Add**, then click **Save and Continue**.
7. Click **Back to Dashboard**.  
   *(Leave the publishing status in **Testing**—you do NOT need to click "Publish app".)*

---

### Step 4: Create Desktop OAuth Credentials
1. Go to [APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials).
2. At the top, click **+ Create Credentials** → **OAuth client ID**.
3. In the **Application type** dropdown, select **Desktop app**.
4. In the **Name** field, enter `Gmail Push Bridge Desktop` (or leave default).
5. Click **Create**.
6. A dialog will appear with your Client ID and Client Secret:
   * Click **Download JSON** to save the file (recommended), **OR**
   * Copy the **Client ID** and **Client Secret**.

---

### Step 5: Connect in Gmail Push Bridge
1. Open **Gmail Push Bridge** from your macOS Menu Bar.
2. Open **Settings & Status** (`⌘,`).
3. Under **Gmail Authentication**, select **Sign in with Google (OAuth 2.0)**.
4. Click **Import client_secret.json…** and select the file you just downloaded (or paste your Client ID & Secret).
5. Click **Sign in with Google (Passkey / Browser)**:
   * Your default web browser will open to Google's sign-in screen.
   * If Google displays a *"Google hasn't verified this app"* screen, click **Advanced** → **Go to Gmail Push Bridge (unsafe)**. *(This warning appears because you are the developer of your own private project in Testing mode).*
   * Click **Continue** to grant IMAP access.
6. Return to Gmail Push Bridge. The status will turn green (**IDLE active**) and your tokens will be saved securely to your macOS Keychain!

---

## Troubleshooting & FAQs

#### "Error 403: access_denied (The developer hasn't given you access)"
* **Fix:** Go back to **APIs & Services → OAuth consent screen → Test users**, click **Add Users**, and ensure the exact Gmail address you are signing in with is listed.

#### "Can I use multiple Gmail accounts?"
* **Yes!** Under **Test users**, simply add each additional Gmail address you want to use.

#### "Will my tokens expire?"
* In Testing mode, Google refresh tokens for projects that haven't been verified remain valid until revoked, unless unused for 6 months or if your Google account password changes. The app will automatically refresh the access token every ~60 minutes.

#### "Is this safe?"
* **Yes, completely.** You are the sole administrator of your Google Cloud project. No third party ever has access to your credentials or your email data. Everything stays strictly between your Mac and Google's IMAP servers.
