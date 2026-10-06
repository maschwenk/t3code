# Computer use

Computer use lets Claude Code and other agents inspect and operate native macOS apps on the
machine running your T3 environment, while you keep working in other apps. It works through the
same agent connection when you send instructions from another computer or your phone.

In **Settings → Integrations → Computer use**, select the environment, add exact app names to
**Allowed computer apps**, and enable **Agent computer access**. Start with Calculator, TextEdit or
another harmless app. macOS must grant Accessibility permission to the host runtime; T3 does not
grant or bypass operating-system permissions for you. The native accessibility library may also
require macOS Screen & System Audio Recording permission for text-only snapshots. This OS
permission does not enable T3's separate screen-capture setting.

## What agents can do

Agents can open an allowed app, read its controls, and act on them. Almost everything runs in the
background: the app stays behind your windows, your mouse does not move, and the keyboard focus
stays where you left it.

- **Open apps.** An agent can launch an allowed app or reopen its window without bringing it
  forward. Some apps still bring themselves to the front the first time they launch.
- **Read apps.** Snapshots list the app's controls, its menu bar, and which app is in front. Large
  apps such as browsers, Slack and Finder skip unnamed layout containers and anything scrolled out
  of view, and agents can search by text or role, focus on one part of a window, or page through
  long lists.
- **Act.** Agents press buttons, enter text, choose menu commands, invoke the actions a control
  offers (expand, increment, scroll into view, and so on), scroll by pages, and press keys such as
  Return, Tab, Escape, arrows, and shortcuts like ⌘N. Keys go only to the target app, not to the
  app you are typing in.
- **Several steps at once.** An agent can send up to 20 steps in one call, such as entering a
  calculation or filling a field and pressing Return. Each step checks that its control is still
  the one the agent saw, and the batch stops at the first change it cannot account for. The agent
  then sees the app's new state in the same response, so routine sequences take one round trip
  instead of one per click.

When the environment runs in the T3 desktop app, an agent cursor shows where each action happens.

Some input still needs the real pointer: hovering, double-clicking, exact wheel scrolling, and
clicking things that offer no accessibility action, such as a canvas. macOS apps ignore synthetic
pointer events in background windows, so these work only while the target app is in front and
nothing covers the target, and they move your mouse. Agents are told to avoid them and to bring an
app forward only when you are not using the machine. In a background Mac app, a shortcut runs the
matching menu command; shortcuts that act on a text selection, such as Select All, may do nothing
until the app is in front.

Turn off Agent computer access to block further calls, or remove an app from the allowlist to
revoke access to it. These grants apply to agents across the selected environment.

**Allow screen captures** is a separate opt-in that requires Screen Recording permission. A capture
shows only the target app's window, even when other windows cover it. Keep it off for text-only
control. Password controls are omitted from accessibility snapshots; screenshots are not redacted.
Complete logins yourself.

## Browser and remote work

For websites, use the existing **Browser** panel and ask Claude to use its browser tools. The browser
has navigation, screenshots, semantic locators, typing, scrolling and recording, with an animated
agent cursor and click feedback. Desktop browser profiles remain separate from the native app allowlist.

Connect through [remote access](./remote-access.md) to steer Claude on the host. Native computer-use
actions run on the environment machine, not on the phone or computer viewing the chat. The host must
remain running and its desktop session unlocked: while the screen is locked, apps report no windows.

## Current limits

macOS is supported; Windows and Linux are not enabled. Apps must expose usable accessibility
controls. Free-coordinate clicking, dragging, live desktop video, and phone takeover are not
implemented. Key names follow the US keyboard layout; agents enter text with typing, which works
with any layout. Native mobile settings for these grants are not yet available; configure them
from web or desktop settings.
