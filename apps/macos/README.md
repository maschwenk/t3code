# T3 Native prototype

A macOS 14+ AppKit client for a T3 protocol-v2 server. The interface uses
native tables and text controls, with isolated WebKit views for document previews. Agents,
SQLite, Git, terminals, and remote access still belong to the existing server.
It reconnects to saved environments or starts its bundled server on first launch.
Closing this app leaves external servers running and stops only its own server child.
About T3 Native shows the build's source revision and whether it includes local changes.

The client supports grouped active/pinned/settled/snoozed threads, project filtering,
search, archived history and restore, rename, pin, settle, snooze, and shared unread
state. Snoozes wake on the same attention and time rules as Electron. It also supports bounded conversation
history with older pages, streamed text and activity, per-thread drafts, new threads,
message submission, and stopping a run. New threads use the project filter when set,
then the current thread's project. Configured project and environment model defaults
take precedence over the current model, and permissions use the configured defaults.
New conversations remain saved local drafts until their first message. Choose the
project, model options, permissions, and current checkout or new worktree before
sending. Workspace defaults follow project overrides, environment settings, then
the project's JSONC `t3.json`. Worktrees use a selected base branch and the existing server launch contract.
An uncertain first launch retries the original command; newer edits remain saved.

Open an existing project folder with ⌘O or the folder-plus button. The picker browses
the connected server, including remote environments. Chat → New Project (⌘⇧N)
creates a folder in that server's configured projects directory. A new environment
can start its first thread without an existing thread; if the server does not support
Scratch, choose or create a project first.

Search matches thread titles, projects and branches. Use ↑/↓ to browse matches,
Return to open one, or Escape to clear the search. The folder button limits the
list to a project. Hover a thread for Settle and Snooze; archived and parked
threads use compact rows. Open Settings with the sidebar gear or ⌘,; Browser
Settings also remain available in the View menu.

The composer discovers provider instances, models, and model options from the
server. The searchable model picker supports account tabs, device-local favorites
scoped to the server, legacy models, and keyboard selection. Search matches model
and account names together, across all account tabs. Open it with ⌘⇧M; use ↑/↓ and
Return to choose a model, or Escape to close. ⌘B toggles the sidebar and ⌘N creates
a thread. Runtime modes and enabled plan mode are editable there. Pending approvals
and agent questions can be answered directly; resolved requests disappear when
another client answers them. Questions support choices, multiple selections,
custom answers, and dismissal when the server advertises it. Command and tool
results omitted from the live feed can be loaded on demand; stale fetches cannot
replace a newer streaming revision. Commands, searches, file changes, and reasoning
collapse into expandable work groups. Expanding preserves the full activity text;
errors and pending questions or approvals stay outside collapsed groups.

The composer offers workspace files/folders with @, provider skills with $, and
provider commands with /. Suggestions follow the selected account and workspace;
↑/↓ and Return/Tab select, and Escape dismisses. Context usage comes from provider
reports and live turns. Compatible idle conversations can compact older context.

Settings includes global thread defaults, restart and usage-limit recovery,
inactive-thread settling, notifications, appearance, providers, scheduled prompts,
connections, and storage diagnostics. Appearance applies to this Mac; server
settings apply to the connected environment. Existing project overrides continue
to apply. Account sign-in uses the provider's existing authentication flow.
Model visibility, ordering, and favorites are scoped to the environment on this Mac.
Scheduled prompts run once or at a recurring interval through the shared server scheduler.

Questions appear one at a time. Write a custom answer or attach files in the main
composer, then use Next or ⌘ Return to advance and submit the final answers.
Previous returns to an earlier answer; the question header collapses its options.
Single-choice options advance automatically, and number keys select visible
options when focus is outside the text editor. Each answer and its files survive
restart, separately from the normal message draft, which returns when the request
closes. Answered files remain available in the conversation.

Enable the optional Plan control from Chat → Enable Plan Mode. This is a saved
client preference. After a plan finishes, type feedback and choose Refine to stay
in planning mode, or leave the composer empty and choose Implement. The adjacent
menu can start implementation in a new thread with the same model and workspace.
An empty composer shows Resume for an interrupted or usage-limited thread, including
one with a proposed plan, and Stop while a run is active. Typing restores the send
or refinement action. Questions, queued edits, and saved plan-send retries keep
their own actions; ⌘ Return follows the same action as the primary button.
Both implementation paths retain the link to the source plan. If a send loses its connection,
Retry resumes the saved send; its menu can dismiss the retry without stopping
work already accepted by the server.

Long plan cards start with a compact preview; Expand plan reveals the full text.
Their actions menu copies the complete Markdown, downloads it, or saves it to a
path in the thread’s workspace. Workspace saves use the connected environment,
including a remote server or the thread’s worktree. A failed save keeps the dialog
and entered path available for retry.

The menu beside Send chooses Auto, Queue next, Steer now, or Interrupt and restart
when the provider supports them. Queued messages can be edited, removed, reordered,
or sent as steering. Stop holds the queue; Resume continues interrupted work and
releases queued messages. Queued edits have separate saved drafts; ⌥↑ at the start
of the composer opens the last queued message and ⌘⇧Return steers the next one.

Attach images or files with the paperclip or ⌘⇧A, or paste/drop into the message
field. The attachment tray shows uploads, failures, retry, and removal. Drafts keep
private local copies across restarts, and expired uploads are restored from those
copies. HEIC/TIFF and oversized images are converted to JPEG; file and aggregate
image limits follow the server contract. Attachment-only messages are supported.
Received files can be downloaded from the conversation with a native save dialog.
Image attachments have thumbnails, and files open in a Quick Look gallery with
navigation and Save controls.

Open the thread’s Files panel from its header or ⌘⇧E. Folders load as you expand
them, including ignored files; Search files also finds paths in unopened folders.
Text files open in a native editor with ⌘F find. Edits autosave after a brief pause;
⌘S saves immediately or retries a failed save. Switching files, closing the panel,
and quitting flush pending edits. If the server cannot finish a save during shutdown,
the local draft remains recoverable. Unsaved changes survive file, thread, and server
switches and app restarts; use Unsaved files to recover them. A delayed save keeps
the original workspace even after navigation. Save checks for intervening server
changes; conflicts retain your edits to copy or retry. Reload can discard them and
load the server version. Completed agent commands, file changes, and checkpoints
refresh visited folders and the open file without replacing unsaved text. Truncated
previews and absolute host paths are read-only.

Markdown files offer Source and Preview; editable checklists save when clicked.
Relative file links open against the file’s directory on the connected server.
CSV and TSV files open as tables, with quoted delimiters and multiline cells preserved.
Table display is limited to 100 rows, 30 columns, and 2,000 characters per cell;
Source retains the complete loaded text. Markdown and table display preferences
are saved separately. ⌘F opens source for searching without changing that preference.
File links in messages, plans and previews open against the connected workspace.
Folder links reveal their ancestors and contents in the file tree.
`:line:column` and `#LlineCcolumn` destinations reveal source without changing
the preview preference; positions beyond the file are clamped to its contents.
Right-click a file or file link, or use Actions in the file toolbar, to copy its
path, open it, reveal it in the host's file manager, or choose an available editor.
Open and reveal use the connected environment's apps and capabilities.
Images and PDFs open in the file panel. Audio and video stream through native
playback controls; Retry refreshes the asset URL and preserves playback position.
HTML files offer Source and Preview, with previews refreshing after autosave.
Save… downloads the original file. Formats macOS cannot decode can be opened
through Actions. Syntax coloring, heading links and workspace content search
remain incomplete.

Open the terminal drawer with ⌘J or the thread header. Its tabs reuse shells on
the connected server, including shells opened from Electron. With terminal focus,
⌘N opens another shell and ⌘W closes the selected shell. Hiding the drawer or
switching threads leaves shells running; reopening restores their history. Clear
removes saved output, and Restart explicitly starts a new shell after exit.
Closing or restarting warns when a command is running. Copy, paste, selection,
scrolling, Unicode and input methods use the native Ghostty renderer. Split panes
and terminal search remain incomplete.

Open Changes from the thread header or ⌘⇧G to review uncommitted work or compare
against a branch or revision. Choose a unified or side-by-side diff, filter the
changed-file list, ignore whitespace, wrap long lines, copy a patch, or use ⌘F to
search the selected diff. Split columns stay aligned when wrapping or resizing,
scroll together vertically, and search the focused side. Clicking a
new line number opens that location in the current workspace file. Completed
agent tools refresh the comparison; Refresh also picks up external edits.
Choose Latest turn, a numbered turn, or Full thread to inspect saved checkpoint
changes. Full thread compares the baseline through the latest saved turn.
Changed-file cards below assistant replies open that turn or a particular file;
file selection reuses the fetched comparison. Missing, stale and unfinished
checkpoints show their availability rather than falling back to a different turn.
Links open the current workspace file, which may have changed since the checkpoint.
Workspace comparisons can expand unchanged context inline or for the whole file,
then collapse it again. Context is loaded on demand and checked against the patch;
refresh if the file changed during loading. Copy patch retains the original diff.
Changes and Files share the right side of the window. Large patches are bounded
and labeled when incomplete; complete file totals remain available when supplied
by the server. Syntax coloring and line
annotations remain incomplete. Older pairing sessions need a new pairing token
for review access.

Open Usage from the sidebar or ⌘⇧U. Limits groups subscription windows by provider,
with individual account bars, reset times, pace and the quota restored by the next
reset. Duplicate accounts from provider instances and usage sources count once;
the freshest read supplies their limits. Click a bar for account details and any
available reset credits; redemption requires confirmation. Failed probes remain
visible as notices. Cost and Tokens show provider charts and model/time breakdowns
for the past 24 hours or 7, 30 and 90 days. Model details separate input, cache and
output tokens; reasoning is included in output. Costs are API equivalents, with
missing prices and incomplete source coverage identified. The metric and period
are saved locally. Refresh updates the selected view; Escape returns to chat.
Usage currently covers the connected environment and its configured accounts.

Open Browser from the conversation header or ⌘⇧B. The native WebKit panel has
per-conversation tabs, back/forward, an address/search field (⌘L), new tabs (⌘T),
zoom, reload, private tabs, uploads, and screenshot attachments. HTTP links in chat
open in the panel; its menu can open the current page in the default browser.
Tabs synchronize through the existing preview RPCs. Loaded pages keep their form
state when switching tabs or conversations. Browser cookies are separate from
Electron; normal profile cookies persist, while private tabs use a memory-only
store. Empty tabs list servers discovered by the connected environment.
Loopback links resolve to a directly connected LAN/Tailscale host; public relays
need a browser gateway before local previews can work.

Use the profile button to open a tab with separate cookies and logins. Manage
Profiles, or View → Browser Settings, lets you add and rename profiles, choose a
default, and clear a profile's website data. Removing a profile clears its data;
existing tabs stay open. Settings also saves the default viewport, zoom and
appearance for new pages, where conversation links open, and whether agent
actions show a floating preview. Agents use the same default profile and viewport;
an explicit show/hide request overrides the preview preference. The managed
Chromium option can import the 1Password extension package from a selected browser
profile; it does not copy that browser's cookies, logins, or passwords.

Browser Settings offers an optional Chromium companion for 1Password. Its live
page opens in a managed floating window, and browser tools operate on that page.
The genuine 1Password extension can be installed from the official Chrome Web Store
or imported from a selected installed profile. Desktop unlock uses 1Password's
[additional-browser setup](https://support.1password.com/additional-browsers/),
which requires an Apple-signed browser in Applications and explicit user trust.
The default ad-hoc development build does not satisfy that signing requirement.
The anonymous welcome screen is checked on the first action and after helper restart.
The browser waits for 1Password to choose onboarding or its account popup before opening it.
Actual account popup, vault unlock and autofill require user verification; the WebKit panel cannot
run Chromium extensions. The two engines have separate cookie stores.

The device toolbar offers the same viewport presets as Electron, rotation, and
custom CSS dimensions (press Return to apply). Previews fit the panel without
changing responsive breakpoints or reloading the page. These are viewport sizes;
the browser still uses macOS WebKit, without mobile user-agent or touch emulation.
Select an element with the pointer button to add its URL, selector and HTML to the
message draft. Escape cancels; selected links do not navigate. Selection currently
covers the main document and open shadow roots. Pen, rectangle, and arrow annotations
can be saved or attached with their page context. React source attribution and
frame selection remain incomplete.

Use the download button, or View → Browser Downloads, to see progress, cancel a
download or show its file in Finder. Downloads you start use the native Save
dialog. Agent-triggered downloads save automatically; the downloads window links
to their folder. Downloads continue when a tab closes. Quitting asks before
cancelling active downloads. Existing files are replaced only after a download
finishes, and a failed save keeps the completed temporary file available in Finder.

Agents can open, navigate, inspect, click, type, press keys, scroll and resize the
native browser through T3's existing browser tools. Background actions preserve
the selected conversation and its browser state; an agent can show a separate
preview window. Stop agent in the browser, or View → Pause Agent Browser, pauses
browser control and cancels queued actions. Resume Agent Browser enables it again.
Typing, clicking or scrolling inside a page also interrupts pending agent actions
for that conversation and returns download handling to the native Save dialog.
Switching tabs or conversations keeps ongoing agent actions attached to their page.
This does not stop the agent's other work or page scripts already running.
Snapshots include a screenshot, accessible page tree, interactive elements and
action history. The cursor animates between agent actions and appears in page
captures. Recordings use H.264 MP4 with a 30/60 fps target, constrained by WebKit
capture throughput, and stop at the time/size limits. Artifacts can be attached to
the composer or uploaded for broker downloads. Console/network diagnostics,
cross-frame locators, and remote JavaScript object handles remain incomplete.

Connections supports saved Mac environments, local server start/stop, T3 Connect
sign-in, environment discovery, and host linking. It preserves saved external
environments and existing phone/iPad connections. The native host uses separate
userdata at ~/Library/Application Support/T3Native/server and refuses live ~/.t3.
Host linking and authentication remain explicit user actions.

Markdown supports native headings,
lists, task lists, quotes, code blocks, tables, and selectable links. Copy-message
actions preserve the original Markdown; code blocks have a Copy code context action.
Code blocks have syntax colors, Copy/Wrap controls, and horizontal overflow.
Interface/code fonts, sizes, wrapping, and chat width follow Appearance settings.
Inline images, file/citation chips, math, and diagrams remain incomplete.

## Build and run

Requires Apple Silicon and Xcode with Swift 6.2 or later. Swift Package Manager fetches the pinned
Swift Markdown and cmark parser dependencies. Packaging also requires the checkout's
Node and pnpm toolchain and builds the shared server/web client. The app bundles
arm64 Node and a physical runtime dependency closure; it does not need a sibling
checkout or a separately installed Node to launch.
GhosttyKit is vendored for arm64 only; Intel Macs are not supported. Ordinary app
builds need neither Zig nor a Metal compiler. To rebuild GhosttyKit, install the
Xcode Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) and run
`apps/macos/scripts/build-ghostty.sh`. It pins and verifies Zig 0.16.0 and uses the
Ghostty revision in `Vendor/GHOSTTY_VERSION`, with crash reporting disabled.
Dependency notices ship in the app's Resources/Licenses directory. To rebuild
with modified dependency sources, pass `GHOSTTY_ALLOW_LOCAL_CHANGES=1` to that script.
The browser selector engine is vendored from the desktop's pinned Playwright
version and verified when packaging. After installing workspace dependencies,
`node apps/macos/update-playwright.mjs` regenerates it with its notices and checksum.

```sh
pnpm install --frozen-lockfile
swift test --package-path apps/macos
apps/macos/build.sh
open 'apps/macos/.build/T3 Native.app'
```

The script creates an ad-hoc-signed local app, separate from the installed T3 app.
It is not a notarized distributable. Quit the prototype before rebuilding its bundle.
An optional first argument chooses the output bundle, for example
`apps/macos/build.sh "$HOME/Applications/T3 Native.app"`.
To sign the app and Chromium helper with an installed Apple signing identity, set
`T3_NATIVE_SIGN_IDENTITY` to that identity's name or fingerprint when running the script.
Packaging authenticates the pinned official Electron arm64 archive and compares
every runtime file and symlink before copying it. The original runtime is never re-signed.

Choose **Connect**, enter the server's base URL and a pairing token from its
Connections settings. Pairing requests `orchestration:read`,
`orchestration:operate`, `terminal:operate`, and `review:write`; the exchanged bearer token is saved in Keychain. Uncheck
the pairing option to use an existing bearer token. HTTPS direct endpoints and
HTTP loopback endpoints are supported. When the session expires, pair again.

Connecting to a live environment makes all thread actions operate on that environment.
The optional native host owns a separate data directory and never adopts an existing listener.
Use a separately running server with a pruned database copy for development; see
the root AGENTS.md test-data procedure.

## Integration check

A private JSON connection file can be used for local tests without saving a token:

```json
{ "endpoint": "http://127.0.0.1:4773", "token": "YOUR_BEARER_TOKEN" }
```

Keep this file outside Git and restrict its permissions (`chmod 600`).
For a normal app launch, add `--remember-connection` alongside `--connection-file`
to save the imported token in Keychain. Subsequent launches reconnect automatically
and restore the last selected thread for that server. Test launches leave saved
credentials unchanged unless this flag is explicitly supplied.

```sh
apps/macos/.build/release/T3Native --smoke --connection-file /private/path/connection.json
```

This reads real shell/thread subscriptions and an older history page. To verify a
real provider reply and idempotent submission, create a disposable project rooted
in an isolated workspace, then add `--send-smoke --sandbox-project PROJECT_ID`.
This submits a short prompt to the server's authenticated Codex provider. It must
not target a project containing ongoing work.

The parity integration check creates a new thread in the isolated project, checks
model/options and runtime-mode mutations against fresh server reads, and exercises
the app controller's configuration subscription and reconnect behavior:

```sh
apps/macos/.build/release/T3Native --parity-smoke \
  --connection-file /private/path/connection.json --sandbox-project PROJECT_ID
```

Add `--question-smoke` to ask the real Codex provider for a question, answer through
the app controller, and verify the resolved request and completed reply. This
requires an authenticated Codex instance and consumes one short provider turn.
Use `--question-paging-smoke` for two provider turns covering multiple questions,
per-question attachments, paging and restart recovery, attachment-only answers,
exact downloaded bytes, and resolution from another client. `--queue-smoke`
checks queue edits, reorder, cancellation, stop/resume, and draft recovery.
`--plan-smoke` checks real plan generation and refinement, implementation in the
same and a new thread, source-plan links, and restart after a partially committed
send. It uses an isolated plan-mode preference and five short provider turns.
`--plan-card-thread THREAD_ID` reuses one of those isolated plan threads to check
collapsed/expanded text layout and exact local/workspace exports, including
reconnect and invalid-path handling. It writes a uniquely named Markdown file
under `plans/` in the isolated workspace and sends no inference request.
Add `--manual-question` instead to leave the real question pending for a UI check.
Add `--tool-output-smoke` to run a diagnostic `printf`, approve only that exact
command once if requested, and fetch its omitted output through the controller.
An interrupted tool check can resume with `--resume-tool-thread ID` on its isolated
test thread; it does not send another message.
UI runs can use `--thread-id ID` and `--filter TEXT` to select an isolated thread.

`--terminal-thread THREAD_ID` checks the native terminal transport on an existing
thread in the isolated project. It creates its own temporary directory and shell,
checks input/output, Unicode, resizing, history replay, clearing and restarting,
then closes that shell and deletes its history. It sends no inference request and
requires a bearer token with `terminal:operate`; older native pairing tokens need
to be replaced for this check. It also sends input from the native terminal engine
through the real server PTY. The native test suite checks the renderer's history,
selection, Unicode input and bracketed paste without opening a window.

`--review-thread THREAD_ID` creates a disposable Git repository and thread in the
isolated project, then checks actual working-tree and branch patches, complete
statistics, renames, deletions, binary/Unicode/CRLF/untracked files, whitespace
filtering, large patches, invalid-ref recovery, navigation and refresh. It sends
no inference request and requires `review:write`. Fixtures remain for UI checking.
If the isolated project's directory lies outside the server's configured workspace,
pass `--review-fixture-root /path/to/isolated-server-base/worktrees` to create the
fixture inside that server's permitted managed-worktree directory.

`--checkpoint-review-thread THREAD_ID` uses an existing completed sandbox thread
with saved checkpoints. It checks turn and full-thread RPCs, exact per-file patch
copies, current-file access, the timeline entry point, unavailable checkpoints,
local rollback snapshot handling, reconnect and navigation. It sends no inference
and verifies the server's run/checkpoint history remains unchanged.

For browser verification, run `python3 apps/macos/Tests/Fixtures/browser_server.py`
and use its printed URL with `--parity-smoke --browser-smoke --browser-fixture URL`,
the private connection file, and an isolated sandbox project. This creates
verification threads, loads real HTTP pages in WebKit, and checks server status
echoes, SPA form state, history, popups and PNG capture. It also checks discovered
server buttons, panel sizing, conversation/hide state retention and private-cookie
isolation, trusted agent input, selectors, redirects, hidden screenshots and
conversation isolation, then closes its test tabs. For broker verification, also
run `node apps/macos/Tests/Fixtures/browser_broker.mjs /private/path/broker.json`
and pass `--browser-broker-fixture /private/path/broker.json` to the same smoke.
That fixture uses the real broker with a local RPC adapter to check routing,
ordered actions, cancellation, pause/resume and reconnects. These checks send no
inference. Stop both fixture servers with their captured PIDs after verification.

## Measure

```sh
python3 apps/macos/measure.py --pid NATIVE_PID --pid ELECTRON_PID --seconds 15
```

The script samples entire descendant trees and reports summed RSS and CPU time as
a percentage of one core. RSS includes shared pages and is not physical footprint.
Report the backend separately: the native client uses an external server, whereas
the Electron desktop normally owns its server. Use the same thread/history and
idle workloads before comparing. A full-featured desktop and this limited client
are not equivalent workloads. This sampler does not measure cold launch, input
latency, scrolling frame times, or energy.

Use `--exclude-pid BACKEND_PID` to exclude a verified backend subtree from the
desktop client sample. Record that exclusion and measure the backend separately.

## Protocol constraints

The Swift adapter implements the existing Effect JSON RPC framing, WebSocket
tickets, stream acknowledgements, cancellation, and protocol-v2 snapshots/events.
It deliberately preserves the existing desktop `creationSource: "web"` value.
No new server contract is introduced. Changes to those contracts need a native
smoke run as well as the reducer tests.

One reconnect task owns the session. Reconnect reloads authoritative bounded
snapshots; cached text remains visible while offline. Mutations are never replayed
automatically. An unchanged draft retry within this process reuses the command and
message IDs, including after an app restart. Draft text, question answers, and
pending submission IDs are stored atomically under Application Support/T3 Native,
separated by server address. The files are private to the current macOS user.
Switching servers or quitting does not discard a draft that failed to save without
an explicit choice to quit without saving.

Use `--parity-smoke --workspace-thread THREAD_ID` with an existing isolated
“Native plan verification” thread to check workspace files without inference.
It creates uniquely named fixture files and a second thread with an isolated
workspace, then checks lazy listing, ignored entries, path search, autosave, exact
text bytes, recovery after restart, typing/undo during a write, navigation with a
pending save, conflicts, reconnect retry, mutation refresh, and truncated/binary
previews. Fixtures remain available for UI verification. Add
`--workspace-provider-smoke` to also have the real provider change an open file
and verify automatic refresh from its tool/checkpoint events. That option consumes
one short provider turn in the newly created verification thread.
