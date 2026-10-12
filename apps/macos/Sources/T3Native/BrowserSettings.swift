import AppKit
import SwiftUI
import T3Core

@MainActor final class BrowserSettingsWindow: NSWindowController {
  init(
    preferences: BrowserPreferences, profiles: BrowserProfiles, chromium: BrowserChromiumController,
    onModeChange: @escaping () -> Void
  ) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = "Browser Settings"
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 520, height: 500)
    window.contentView = NSHostingView(
      rootView: BrowserSettings(
        preferences: preferences, profiles: profiles, chromium: chromium, onModeChange: onModeChange
      ))
    window.center()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct BrowserSettings: View {
  @ObservedObject var preferences: BrowserPreferences
  let profiles: BrowserProfiles
  @ObservedObject var chromium: BrowserChromiumController
  let onModeChange: () -> Void
  @State private var removeExtension = false
  @State private var editing: BrowserProfile?
  @State private var adding = false
  @State private var name = ""
  @State private var confirmation: BrowserProfile?
  @State private var removing = false
  @State private var busy = false
  @State private var width = ""
  @State private var height = ""
  @State private var zoom = ""

  var body: some View {
    Form {
      if let error = preferences.error {
        Text(error).foregroundStyle(.orange).textSelection(.enabled)
      }
      Section("1Password Browser") {
        Toggle("Use managed Chromium browser", isOn: $chromium.enabled).disabled(
          chromium.nativeRecordingActive
        )
        .onChange(of: chromium.enabled) { _, _ in onModeChange() }
        Text(
          "The live page opens in a managed floating window. 1Password runs its genuine browser extension there."
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(chromium.state + " · " + chromium.passwordStatus).font(.caption)
        if !chromium.available {
          Text("This app needs its packaged Apple Silicon Chromium helper.").foregroundStyle(
            .orange)
        }
        if let error = chromium.error {
          Text(error).foregroundStyle(.orange).textSelection(.enabled)
        }
        HStack {
          Button("Install official 1Password extension") { Task { await chromium.install() } }
          Button("Import from browser…") {
            Task { await chromium.importSelectedProfile(window: nil) }
          }
        }.disabled(!chromium.available)
        Button("Remove 1Password extension", role: .destructive) { removeExtension = true }
          .disabled(chromium.extensions.isEmpty)
          .confirmationDialog(
            "Remove the managed 1Password extension?", isPresented: $removeExtension
          ) {
            Button("Remove extension", role: .destructive) {
              Task { await chromium.removeExtension() }
            }
          }
        Button("Stop Chromium helper") {
          Task { if await chromium.finishBeforeQuit(window: nil) { chromium.stop() } }
        }.disabled(!chromium.running)
        Text(
          "For desktop unlock, choose an Apple code signed T3 Browser in Applications using 1Password Settings → Browser → Add Browser. Trust grants the browser access to unlocked 1Password information for saving and filling. This setup is your choice; T3 does not unlock your vault."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Show T3 Browser in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([
            Bundle.main.bundleURL.appendingPathComponent(
              "Contents/Resources/chromium-helper/T3 Browser.app")
          ])
        }.disabled(!chromium.available)
        Link(
          "1Password browser setup",
          destination: URL(string: "https://support.1password.com/additional-browsers/")!)
      }
      Section("New tabs") {
        Picker("Default profile", selection: binding(\.defaultProfileID)) {
          ForEach(preferences.values.availableProfiles.filter { $0.id != "incognito" }) {
            Text($0.name).tag($0.id)
          }
        }
        Picker(
          "Viewport",
          selection: Binding(
            get: {
              preferences.values.defaultViewport.width == nil
                ? "fill" : preferences.values.defaultViewport.presetID ?? "custom"
            }, set: { id in setViewport(id) })
        ) {
          Text("Fit panel").tag("fill")
          Text("Custom").tag("custom")
          ForEach(BrowserDevicePreset.all, id: \.id) { Text($0.name).tag($0.id) }
        }
        if preferences.values.defaultViewport.width != nil {
          HStack {
            TextField("Width", text: $width).accessibilityLabel("Default viewport width").onSubmit(
              applySize)
            Text("×")
            TextField("Height", text: $height).accessibilityLabel("Default viewport height")
              .onSubmit(applySize)
            Button("Apply", action: applySize)
          }
        }
        HStack {
          TextField("Zoom (%)", text: $zoom).onSubmit(applyZoom)
          Button("Apply", action: applyZoom).accessibilityLabel("Apply default zoom")
        }
        Picker("Appearance", selection: binding(\.appearance)) {
          Text("System").tag("system")
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }
        Text("These defaults apply when a page opens. Existing pages keep their current view.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Links and agents") {
        Toggle("Open conversation links in the default browser", isOn: binding(\.externalLinks))
        Toggle(
          "Show floating previews when an agent uses Browser", isOn: binding(\.showAgentPreview))
      }
      Section {
        ForEach(preferences.values.availableProfiles.filter { $0.id != "incognito" }) { profile in
          HStack {
            Text(profile.name).lineLimit(1)
            if preferences.values.defaultProfileID == profile.id {
              Text("Default").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
              Button("Set as default") { save { $0.defaultProfileID = profile.id } }
                .disabled(preferences.values.defaultProfileID == profile.id)
              if !profile.builtIn {
                Button("Rename…") {
                  name = profile.name
                  editing = profile
                }
              }
              Button("Clear cookies and cache…") {
                removing = false
                confirmation = profile
              }
              if !profile.builtIn {
                Button("Remove profile and data…", role: .destructive) {
                  removing = true
                  confirmation = profile
                }
              }
            } label: {
              Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(profile.name + " options")
          }
        }
        Button("Add profile…") {
          name = ""
          adding = true
        }.disabled(preferences.values.profiles.count >= 24)
      } header: {
        Text("Profiles")
      } footer: {
        Text("Profiles separate cookies and logins. Incognito data is cleared when the app closes.")
      }
    }
    .formStyle(.grouped).disabled(busy).onAppear(perform: updateFields)
    .onChange(of: preferences.values.viewport) { _, _ in updateFields() }
    .onChange(of: preferences.values.zoom) { _, _ in updateFields() }
    .sheet(
      isPresented: Binding(
        get: { adding || editing != nil },
        set: {
          if !$0 {
            adding = false
            editing = nil
          }
        })
    ) {
      VStack(alignment: .leading, spacing: 16) {
        Text(adding ? "Add profile" : "Rename profile").font(.headline)
        TextField("Profile name", text: $name).onSubmit(saveName)
        if let error = preferences.error { Text(error).foregroundStyle(.orange).font(.caption) }
        HStack {
          Spacer()
          Button("Cancel") {
            adding = false
            editing = nil
          }.keyboardShortcut(.cancelAction)
          Button("Save", action: saveName).keyboardShortcut(.defaultAction)
        }
      }.padding(24).frame(width: 360)
    }
    .confirmationDialog(
      removing ? "Remove profile and data?" : "Clear cookies and cache?",
      isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
      titleVisibility: .visible, presenting: confirmation
    ) { profile in
      Button(removing ? "Remove profile" : "Clear data", role: .destructive) {
        let remove = removing
        busy = true
        Task { @MainActor in
          do {
            if chromium.enabled {
              try await chromium.clearProfile(profile.id, kinds: .all)
            } else {
              await profiles.clear(profile: profile.id, kinds: .all)
            }
            if remove { try preferences.remove(profile.id) }
          } catch { preferences.error = error.localizedDescription }
          busy = false
          confirmation = nil
        }
      }
    } message: { profile in
      Text(
        "This signs you out of \(profile.name) and removes its website data. Existing tabs stay open."
      )
    }
  }
  private func binding<Value>(_ path: WritableKeyPath<BrowserPreferenceValues, Value>) -> Binding<
    Value
  > {
    Binding(
      get: { preferences.values[keyPath: path] },
      set: { value in save { $0[keyPath: path] = value } })
  }
  private func save(_ change: (inout BrowserPreferenceValues) throws -> Void) {
    do { try preferences.update(change) } catch { preferences.error = error.localizedDescription }
  }
  private func saveName() {
    do {
      if adding {
        try preferences.create(name)
      } else if let editing {
        try preferences.rename(editing.id, to: name)
      }
      adding = false
      editing = nil
    } catch { preferences.error = error.localizedDescription }
  }
  private func updateFields() {
    width = preferences.values.defaultViewport.width.map(String.init) ?? "1280"
    height = preferences.values.defaultViewport.height.map(String.init) ?? "800"
    zoom = String(Int((preferences.values.zoom * 100).rounded()))
  }
  private func setViewport(_ id: String) {
    save {
      if id == "fill" {
        $0.viewport = BrowserViewport.fill.json
      } else if id == "custom" {
        $0.viewport = try BrowserViewport(width: 1280, height: 800).json
      } else if let preset = BrowserDevicePreset.all.first(where: { $0.id == id }) {
        $0.viewport = preset.viewport.json
      }
    }
  }
  private func applySize() {
    save {
      guard let width = Int(width), let height = Int(height) else {
        throw T3Error("Enter whole numbers for the viewport dimensions.")
      }
      $0.viewport = try BrowserViewport(width: width, height: height).json
    }
  }
  private func applyZoom() {
    save {
      guard let value = Double(zoom) else {
        throw T3Error("Enter a zoom percentage from 25 to 500.")
      }
      $0.zoom = value / 100
    }
  }
}
