import AppKit
import T3Core

@MainActor enum FileContextMenu {
  static func make(
    path: String, position: FileSourcePosition? = nil,
    at location: WorkspaceLocation, store: ClientStore
  ) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let capabilities = store.fileOpenCapabilities
    func item(_ title: String, editor: String, reveal: Bool = false) -> NSMenuItem {
      ActionMenuItem(title) { [weak store] in
        store?.openFileExternally(
          path, position: position, editor: editor, reveal: reveal, at: location)
      }
    }
    if capabilities.canOpenDefault { menu.addItem(item("Open", editor: "file-manager")) }
    if let title = capabilities.revealTitle {
      menu.addItem(item(title, editor: "file-manager", reveal: true))
    }
    let editors = capabilities.editors.filter { $0 != "file-manager" }
    if !editors.isEmpty {
      let parent = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      submenu.autoenablesItems = false
      for editor in editors {
        submenu.addItem(item(FileOpenCapabilities.label(editor), editor: editor))
      }
      parent.submenu = submenu
      menu.addItem(parent)
    }
    if !menu.items.isEmpty { menu.addItem(.separator()) }
    for (title, text) in [
      ("Copy path", path),
      ("Copy absolute path", FileOpenCapabilities.absolutePath(path, root: location.root)),
    ] {
      menu.addItem(
        ActionMenuItem(title) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        })
    }
    return menu
  }

  static func forLink(_ url: URL, at location: WorkspaceLocation?, store: ClientStore) -> NSMenu? {
    guard let location, store.workspaceLocation == location,
      let link = WorkspaceFileLink(url: url, root: location.root)
    else { return nil }
    return make(path: link.path, position: link.position, at: location, store: store)
  }

  static func append(_ source: NSMenu, to menu: NSMenu) {
    for item in source.items {
      source.removeItem(item)
      menu.addItem(item)
    }
  }
}

@MainActor final class WorkspaceOutlineView: NSOutlineView {
  var menuAtRow: ((Int) -> NSMenu?)?
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    return row >= 0 ? menuAtRow?(row) : nil
  }
}
