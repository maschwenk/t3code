# T3 Native prototype

A macOS 14+ AppKit client for an existing T3 protocol-v2 server. The interface uses
native tables and text controls, with isolated WebKit views for document previews. Agents,
SQLite, Git, terminals, and remote access still belong to the existing server.
Closing this app does not stop that server or its agents.

The client supports grouped active/pinned/settled/snoozed threads, project filtering,
search, archived history and restore, rename, pin, settle, snooze, and shared unread
state. Snoozes wake on the same attention and time rules as Electron. It also supports bounded conversation
history with older pages, streamed text and activity, per-thread drafts, new threads
using the selected thread's project/model, message submission, and stopping a run.
New threads use the project's workspace root; they do not create a worktree.
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

The integrated browser, full diff views,
provider setup, and T3 Connect
account/relay discovery remain in the existing app. Markdown supports native headings,
lists, task lists, quotes, code blocks, tables, and selectable links. Copy-message
actions preserve the original Markdown; code blocks have a Copy code context action.
Syntax highlighting, inline images, file/citation chips, math, and diagrams remain incomplete.

## Build and run

Requires Apple Silicon and Xcode with Swift 6.2 or later. Swift Package Manager fetches the pinned
Swift Markdown and cmark parser dependencies; the native client needs no JavaScript build.
GhosttyKit is vendored for arm64 only; Intel Macs are not supported. Ordinary app
builds need neither Zig nor a Metal compiler. To rebuild GhosttyKit, install the
Xcode Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) and run
`apps/macos/scripts/build-ghostty.sh`. It pins and verifies Zig 0.16.0 and uses the
Ghostty revision in `Vendor/GHOSTTY_VERSION`, with crash reporting disabled.
Dependency notices ship in the app's Resources/Licenses directory. To rebuild
with modified dependency sources, pass `GHOSTTY_ALLOW_LOCAL_CHANGES=1` to that script.

```sh
swift test --package-path apps/macos
apps/macos/build.sh
open 'apps/macos/.build/T3 Native.app'
```

The script creates an ad-hoc-signed local app, separate from the installed T3 app.
It is not a notarized distributable. Quit the prototype before rebuilding its bundle.
An optional first argument chooses the output bundle, for example
`apps/macos/build.sh "$HOME/Applications/T3 Native.app"`.

Choose **Connect**, enter the server's base URL and a pairing token from its
Connections settings. Pairing requests `orchestration:read`,
`orchestration:operate`, and `terminal:operate`; the exchanged bearer token is saved in Keychain. Uncheck
the pairing option to use an existing bearer token. HTTPS direct endpoints and
HTTP loopback endpoints are supported. When the session expires, pair again.

The native client does not open a database or launch a server. Connecting it to a
live environment makes all thread actions operate on that environment.
Use a separately running server with a pruned database copy for development; see
the root AGENTS.md test-data procedure.

## Integration check

A private JSON connection file can be used for local tests without saving a token:

```json
{ "endpoint": "http://127.0.0.1:4773", "token": "YOUR_BEARER_TOKEN" }
```

Keep this file outside Git and restrict its permissions (`chmod 600`).

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
