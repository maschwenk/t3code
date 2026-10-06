# Computer use

Computer use lets Claude Code and other agents inspect and operate native macOS apps on the
machine running your T3 environment. It works through the same agent connection when you send
instructions from another computer or your phone.

In **Settings → Integrations → Computer use**, select the environment, add exact app names to
**Allowed computer apps**, and enable **Agent computer access**. Start with Calculator or a disposable test
app. Open the app on the host first. macOS must grant Accessibility permission to the host runtime;
T3 does not grant or bypass operating-system permissions for you.

Ask Claude to inspect the app and perform a small task. Agents can inspect controls, press buttons,
enter text, and invoke the accessibility actions exposed by a control. Actions use a fresh observation
and move the visible system cursor to their target before acting. Keep the target window in the
foreground. Agents can also hover, click, double-click, right-click and scroll at an inspected control.
Pointer actions share your mouse; avoid simultaneous manual input. Turn off Agent computer access
to block further calls, or remove an app from the allowlist to revoke access to it. These grants apply to agents across the selected environment.

**Allow screen captures** is a separate opt-in. It requires Screen Recording permission and the target
app's window in the foreground. Captures show pixels on the screen, so overlapping windows and
sensitive content can be visible. Keep it off for text-only control. Password controls are omitted
from accessibility snapshots; screenshots are not redacted. Complete logins yourself.

## Browser and remote work

For websites, use the existing **Browser** panel and ask Claude to use its browser tools. The browser
has navigation, screenshots, semantic locators, typing, scrolling and recording, with an animated
agent cursor and click feedback. Desktop browser profiles remain separate from the native app allowlist.

Connect through [remote access](./remote-access.md) to steer Claude on the host. Native computer-use
actions run on the environment machine, not on the phone or computer viewing the chat. The host must
remain running and its desktop session accessible. A remote browser task still needs a connected
T3 desktop browser host; this change does not add a server-only Chromium host.

## Current limits

This is the fork's first native computer-use implementation. macOS is supported; Windows and Linux
are not enabled. Apps must expose usable accessibility controls. Free-coordinate clicking,
dragging, global keyboard shortcuts, app launch, a separate native agent cursor overlay, live desktop
video, and phone takeover are not implemented. Native mobile settings for these grants are not yet available; configure them from web or desktop settings.
The existing mobile app can steer a compatible server's agent, but end-to-end mobile compatibility
and native app actions must be verified on your devices before relying on them.
