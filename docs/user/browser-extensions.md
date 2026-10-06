# Browser extensions

The desktop app's preview browser runs Chrome extensions such as 1Password.

Open **Settings → Integrations → Browser → Extensions → Add extension**. Choose **From a
browser on this computer** to copy an extension you already use in Chrome, Edge, Brave, Arc or
another Chromium browser, or **From the Chrome Web Store** and paste the extension's store link.
Extensions with a toolbar button appear next to the preview's address bar; click one to open
its popup.

Extensions run in every browser profile except Incognito. Each profile keeps its own extension
data, so sign in to an extension once per profile. Turning an extension off or removing it
applies to every profile.

Most extensions work. Some Chrome features are not available: an extension's items in the
right-click menu, keyboard shortcuts and its side panel do not appear.

## 1Password

Sign in to the 1Password extension with your account details the first time you open it.
To unlock it with the 1Password app and Touch ID instead, add T3 Code in **1Password →
Settings → Browser → Add Browser**. 1Password only accepts code-signed apps in the
Applications folder, so this works with an installed T3 Code build, not a development build.

## Okta Verify

Okta Verify is a desktop app, not an extension. Sign-in pages reach it in two ways, and the
preview browser supports both: they contact Okta Verify on this computer, and they open a
`com-okta-authenticator:` link, which T3 Code asks you to confirm before opening Okta Verify.
Okta Verify must be installed and set up on the computer.
