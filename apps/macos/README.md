# T3 Native prototype

A macOS 14+ AppKit client for an existing T3 protocol-v2 server. The interface uses
native tables and text controls; it embeds neither Electron nor a web view. Agents,
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

The integrated browser, interactive terminal, full diff views, attachments,
provider setup, question attachments, and T3 Connect
account/relay discovery remain in the existing app. Markdown supports native headings,
lists, task lists, quotes, code blocks, tables, and selectable links. Copy-message
actions preserve the original Markdown; code blocks have a Copy code context action.
Syntax highlighting, inline images, file/citation chips, math, and diagrams remain incomplete.

## Build and run

Requires Xcode with Swift 6.2 or later. Swift Package Manager fetches the pinned
Swift Markdown and cmark parser dependencies; the native client needs no JavaScript build.

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
Connections settings. Pairing requests only `orchestration:read` and
`orchestration:operate`; the exchanged bearer token is saved in Keychain. Uncheck
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
Add `--manual-question` instead to leave the real question pending for a UI check.
Add `--tool-output-smoke` to run a diagnostic `printf`, approve only that exact
command once if requested, and fetch its omitted output through the controller.
An interrupted tool check can resume with `--resume-tool-thread ID` on its isolated
test thread; it does not send another message.
UI runs can use `--thread-id ID` and `--filter TEXT` to select an isolated thread.

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
