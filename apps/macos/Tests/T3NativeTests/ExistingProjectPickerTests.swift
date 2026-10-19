import AppKit
import T3Core
import Testing

@testable import T3Native

@MainActor private func projectPickerViews(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(projectPickerViews)
}

private func pickerProject(_ id: String, _ title: String, _ root: String) -> JSON {
  .object(["id": .string(id), "title": .string(title), "workspaceRoot": .string(root)])
}

@MainActor @Test func existingProjectPickerSearchesPathsAndChoosesWithKeyboard() throws {
  var chosen: JSON?
  var closed = false
  let projects = [
    pickerProject("one", "App", "/work/client/App"),
    pickerProject("two", "App", "/work/server/App"),
    pickerProject("three", "Website", "/work/site"),
  ]
  let picker = ExistingProjectPicker(
    projects: projects, selectedID: "one", choose: { chosen = $0 }, openFolder: {},
    close: { closed = true })
  let views = projectPickerViews(picker.view)
  let search = try #require(views.compactMap { $0 as? NSSearchField }.first)
  let table = try #require(views.compactMap { $0 as? NSTableView }.first)
  #expect(table.numberOfRows == 3)
  search.stringValue = "app server"
  picker.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: search))
  #expect(table.numberOfRows == 1)
  #expect(chosen == nil && !closed, "Searching must not switch the draft's project.")
  #expect(
    picker.control(
      search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
  #expect(chosen == projects[1] && closed)
}

@MainActor @Test func existingProjectPickerKeepsEmptySearchSafeAndRefreshesTheCatalog() throws {
  var chosen: JSON?
  var closed = false
  let project = pickerProject("one", "Native", "/work/native")
  let picker = ExistingProjectPicker(
    projects: [project], selectedID: "one", choose: { chosen = $0 }, openFolder: {},
    close: { closed = true })
  let views = projectPickerViews(picker.view)
  let search = try #require(views.compactMap { $0 as? NSSearchField }.first)
  let table = try #require(views.compactMap { $0 as? NSTableView }.first)
  search.stringValue = "does not exist"
  picker.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: search))
  #expect(table.numberOfRows == 0)
  _ = picker.control(
    search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
  #expect(chosen == nil && !closed)
  search.stringValue = ""
  picker.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: search))
  picker.update(projects: [], selectedID: "one")
  #expect(
    table.numberOfRows == 0, "A removed project must not remain selectable in an open picker.")
  _ = picker.control(
    search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
  #expect(chosen == nil && closed)
}
