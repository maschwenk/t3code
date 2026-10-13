import SwiftUI
import T3Core

struct ScheduledTasksView: View {
  let store: ClientStore
  @StateObject private var session: ManagementSettingsSession
  @State private var draft: ScheduledPromptDraft?
  @State private var editor = false
  @State private var deleting: ScheduledPrompt?
  @State private var draftEnvironment: String?
  @State private var refreshID = UUID()

  init(store: ClientStore) {
    self.store = store
    _session = StateObject(wrappedValue: ManagementSettingsSession(store: store))
  }
  var body: some View {
    Form {
      Section {
        HStack {
          Label("Scheduled prompts", systemImage: "calendar.badge.clock").font(.headline)
          Spacer()
          Button("Refresh") { refreshID = UUID() }.disabled(
            store.browserConnection == nil || session.busy)
        }
        Text(
          "Fixed times use the server’s local timezone. The server calculates next runs and executes prompts while this app is closed."
        )
        .font(.caption).foregroundStyle(.secondary)
        if !session.connected {
          Text("Connect to a server to manage schedules.").foregroundStyle(.secondary)
        }
        if let error = session.error { Text(error).font(.caption).foregroundStyle(.orange) }
        if session.busy {
          HStack {
            ProgressView().controlSize(.small)
            Button("Cancel action", action: session.cancelOperation)
          }
        }
      }
      if session.schedulesLoaded && session.tasks.isEmpty {
        Section {
          ContentUnavailableView(
            "No scheduled prompts", systemImage: "calendar",
            description: Text(
              "Create a prompt to run at a fixed server time or repeating interval."))
        }
      }
      ForEach(session.tasks) { task in
        Section {
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text(task.title).font(.headline)
              Text(task.cadence).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
              task.lifecycle,
              isOn: Binding(
                get: { task.enabled },
                set: { enabled in
                  session.perform {
                    _ = try await session.request(
                      "scheduledTasks.setEnabled",
                      .object(["id": .string(task.id), "enabled": .bool(enabled)]))
                  }
                })
            ).toggleStyle(.switch).fixedSize().disabled(session.busy || !session.connected)
          }
          Text(task.prompt).lineLimit(3).foregroundStyle(.secondary)
          LabeledContent("Project", value: store.shell.projects[task.projectID] ?? task.projectID)
          LabeledContent("Model", value: task.model["model"].string ?? "Unavailable")
          if let next = task.nextRun {
            LabeledContent("Next run") {
              Text(next, format: .dateTime.month().day().hour().minute().timeZone())
            }
          }
          LabeledContent(
            "Last status", value: task.lastStatus.capitalized + " · \(task.runCount) runs")
          if let last = task.lastRun {
            LabeledContent("Last run") {
              Text(last, format: .dateTime.month().day().hour().minute().timeZone())
            }
          }
          if let failure = task.source["lastRunError"].string, !failure.isEmpty {
            Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
          }
          HStack {
            if task.editable {
              Button("Edit…") {
                draft = ScheduledPromptDraft(task: task)
                draftEnvironment = session.environment
                editor = true
              }
              Button("Run now") {
                session.perform {
                  _ = try await session.request(
                    "scheduledTasks.runNow", .object(["id": .string(task.id)]))
                }
              }
            }
            if let threadID = task.threadID {
              Button("Open conversation") { store.select(threadID) }
            }
            Spacer()
            Button("Delete…", role: .destructive) { deleting = task }
          }.disabled(session.busy || !session.connected)
          if !task.editable {
            Text("This trigger is managed by another client.").font(.caption).foregroundStyle(
              .secondary)
          }
        }
      }
      Section {
        Button(
          draft == nil && session.pendingScheduleCreate == nil
            ? "Create scheduled prompt…" : "Continue editing prompt…"
        ) {
          if let pending = session.pendingScheduleCreate {
            draft = pending
            draftEnvironment = session.environment
          } else if draft == nil {
            var value = ScheduledPromptDraft()
            value.projectID = store.shell.projects.keys.sorted().first ?? ""
            if let provider = store.catalog.providers.first(where: { $0.available }),
              let model = provider.models.first(where: { !$0.legacy })
            {
              value.model = model.selection(
                instanceID: provider.id, planModeEnabled: store.catalog.planModeEnabled)
            }
            draft = value
            draftEnvironment = session.environment
          }
          editor = true
        }.disabled(!session.connected || !session.loaded || session.busy)
      }
    }.formStyle(.grouped)
      .task(
        id: (store.browserConnection.map { String(describing: ObjectIdentifier($0)) } ?? "")
          + refreshID.uuidString
      ) { await session.observe(schedules: true) }
      .onChange(of: session.environment) { _, next in
        if let draftEnvironment, draftEnvironment != next {
          draft = nil
          editor = false
        }
      }
      .sheet(isPresented: $editor) {
        if let draft {
          ScheduledPromptEditor(session: session, initial: draft) { value in
            self.draft = value
          } saved: {
            self.draft = nil
            editor = false
          } cancel: {
            editor = false
          }
        }
      }
      .confirmationDialog(
        "Delete this scheduled prompt?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible, presenting: deleting
      ) { task in
        Button("Delete \(task.title)", role: .destructive) {
          session.perform {
            _ = try await session.request(
              "scheduledTasks.delete", .object(["id": .string(task.id)]))
            deleting = nil
          }
        }
      } message: { _ in
        Text("Existing conversation history is kept. Future runs stop.")
      }
  }
}

private struct ScheduledPromptEditor: View {
  @ObservedObject var session: ManagementSettingsSession
  @State var draft: ScheduledPromptDraft
  let changed: (ScheduledPromptDraft) -> Void
  let saved: () -> Void
  let cancel: () -> Void
  @State private var validation: String?
  init(
    session: ManagementSettingsSession, initial: ScheduledPromptDraft,
    changed: @escaping (ScheduledPromptDraft) -> Void, saved: @escaping () -> Void,
    cancel: @escaping () -> Void
  ) {
    self.session = session
    _draft = State(initialValue: initial)
    self.changed = changed
    self.saved = saved
    self.cancel = cancel
  }
  private var modelChoices: [(key: String, name: String, value: JSON)] {
    session.providers.flatMap { provider in
      provider.models.map { model in
        (
          provider.id + ":" + model.id, provider.name + " · " + model.name,
          model.selection(
            instanceID: provider.id, preserving: draft.model,
            planModeEnabled: session.store.catalog.planModeEnabled)
        )
      }
    }
  }
  private var selectedModel: String {
    (draft.model["instanceId"].string ?? "") + ":" + (draft.model["model"].string ?? "")
  }
  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section(draft.editing ? "Edit scheduled prompt" : "Create scheduled prompt") {
          TextField("Title", text: $draft.title)
          VStack(alignment: .leading) {
            Text("Prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.prompt).frame(minHeight: 100).accessibilityLabel(
              "Scheduled prompt")
          }
          Toggle("Enabled", isOn: $draft.enabled)
        }
        Section("Schedule") {
          Picker("Run", selection: $draft.mode) {
            Text("At a fixed time").tag("fixed_time")
            Text("At a recurring interval").tag("interval")
          }
          if draft.mode == "fixed_time" {
            TextField("Server time (HH:MM)", text: $draft.timeOfDay)
            HStack {
              ForEach(0..<7) { day in
                Toggle(
                  ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][day],
                  isOn: Binding(
                    get: { draft.weekdays.contains(day) },
                    set: { selected in
                      if selected { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) }
                    })
                ).toggleStyle(.button)
              }
            }
            Text("No selected days means every day, matching the server schedule.").font(.caption)
              .foregroundStyle(.secondary)
          } else {
            TextField("Interval in minutes", text: $draft.intervalMinutes)
            Text("Minimum one minute. Timing is measured by the server.").font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Section("Workspace") {
          Picker("Project", selection: $draft.projectID) {
            Text("Choose a project").tag("")
            ForEach(session.store.shell.projects.keys.sorted(), id: \.self) { id in
              Text(session.store.shell.projects[id] ?? id).tag(id)
            }
          }.onChange(of: draft.projectID) { _, _ in draft.threadID = "" }
          Picker("Conversation", selection: $draft.threadID) {
            Text("Create a new conversation each run").tag("")
            ForEach(
              session.store.shell.threads.values.filter { $0.projectID == draft.projectID }.sorted {
                $0.title < $1.title
              }
            ) { thread in
              Text(thread.title).tag(thread.id)
            }
            if !draft.threadID.isEmpty && session.store.shell.threads[draft.threadID] == nil {
              Text("Saved conversation").tag(draft.threadID)
            }
          }
          Picker("Workspace", selection: $draft.workspaceMode) {
            Text("Project root").tag("root")
            Text("New worktree").tag("worktree")
            Text("Existing worktree").tag("existing_worktree")
          }.disabled(!draft.threadID.isEmpty)
          if draft.workspaceMode == "worktree" {
            TextField("Base branch", text: $draft.baseRef)
            Toggle("Start from origin", isOn: $draft.startFromOrigin)
          }
          if draft.workspaceMode == "existing_worktree" {
            TextField("Worktree path on server", text: $draft.worktreePath)
          }
          TextField("Branch (optional)", text: $draft.branch)
        }
        Section("Model & permissions") {
          Picker(
            "Model",
            selection: Binding(
              get: { selectedModel },
              set: { key in
                if let choice = modelChoices.first(where: { $0.key == key }) {
                  draft.model = choice.value
                }
              })
          ) {
            Text("Choose a model").tag(":")
            ForEach(modelChoices, id: \.key) { choice in Text(choice.name).tag(choice.key) }
            if selectedModel != ":" && !modelChoices.contains(where: { $0.key == selectedModel }) {
              Text("Saved model (currently unavailable)").tag(selectedModel)
            }
          }
          Picker("Permissions", selection: $draft.runtimeMode) {
            Text("Approval required").tag("approval-required")
            Text("Auto accept edits").tag("auto-accept-edits")
            Text("Auto").tag("auto")
            Text("Full access").tag("full-access")
          }
          if session.store.catalog.planModeEnabled || draft.interactionMode == "plan" {
            Picker("Mode", selection: $draft.interactionMode) {
              Text("Default").tag("default")
              Text("Plan").tag("plan")
            }
          }
        }
        if draft.editing {
          Text("Existing end conditions and run history are preserved.").font(.caption)
            .foregroundStyle(.secondary)
        }
        if let error = validation ?? session.error {
          Text(error).font(.caption).foregroundStyle(.orange)
        }
      }.formStyle(.grouped).disabled(session.busy || !session.connected)
      HStack {
        if session.busy {
          ProgressView().controlSize(.small)
          Button("Cancel action", action: session.cancelOperation)
        }
        Spacer()
        Button("Cancel") {
          changed(draft)
          cancel()
        }.keyboardShortcut(.cancelAction).disabled(session.busy)
        Button("Save") {
          do {
            let payload = try draft.payload()
            changed(draft)
            validation = nil
            if !draft.editing { session.pendingScheduleCreate = draft }
            try session.persistPendingCreates()
            session.perform {
              _ = try await session.request("scheduledTasks.upsert", payload)
              if !draft.editing { session.pendingScheduleCreate = nil }
              try session.persistPendingCreates()
              saved()
            }
          } catch { validation = error.localizedDescription }
        }.keyboardShortcut(.defaultAction).disabled(session.busy || !session.connected)
      }.padding(16)
    }.frame(width: 650, height: 760).interactiveDismissDisabled(true)
  }
}
