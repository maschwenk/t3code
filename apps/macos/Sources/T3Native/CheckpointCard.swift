import AppKit
import T3Core

@MainActor final class CheckpointCard: NSView {
  static func height(_ checkpoint: TurnCheckpoint) -> CGFloat {
    46 + CGFloat(min(checkpoint.files.count, 5)) * 26
      + (checkpoint.files.count > 5 ? 26 : 0)
      + (checkpoint.unavailableReason == nil ? 0 : 36)
  }

  init(_ checkpoint: TurnCheckpoint, open: @escaping (String?) -> Void) {
    super.init(frame: .zero)
    let totals = checkpoint.files.reduce((0, 0)) { ($0.0 + $1.additions, $0.1 + $1.deletions) }
    let title = NSTextField(
      labelWithString: "Turn \(checkpoint.turnCount) · \(checkpoint.files.count) changed files")
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    let counts = NSTextField(labelWithString: "+\(totals.0)  −\(totals.1)")
    counts.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let review = ActionButton("Review") { open(nil) }
    review.controlSize = .small
    review.isEnabled = checkpoint.unavailableReason == nil
    let header = NSStackView(views: [title, NSView(), counts, review])
    let stack = NSStackView(views: [header])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    if let error = checkpoint.unavailableReason {
      let label = NSTextField(wrappingLabelWithString: error)
      label.font = .systemFont(ofSize: 11)
      label.textColor = .secondaryLabelColor
      label.maximumNumberOfLines = 2
      stack.addArrangedSubview(label)
    }
    for file in checkpoint.files.prefix(5) {
      let link = ActionButton(file.path) { open(file.path) }
      link.bezelStyle = .inline
      link.alignment = .left
      link.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      link.lineBreakMode = .byTruncatingMiddle
      link.toolTip = "Review \(file.path) · +\(file.additions) −\(file.deletions)"
      link.isEnabled = checkpoint.unavailableReason == nil
      let stats = NSTextField(labelWithString: "+\(file.additions)  −\(file.deletions)")
      stats.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
      stats.textColor = .secondaryLabelColor
      stats.setContentCompressionResistancePriority(.required, for: .horizontal)
      let row = NSStackView(views: [link, NSView(), stats])
      row.heightAnchor.constraint(equalToConstant: 22).isActive = true
      stack.addArrangedSubview(row)
    }
    if checkpoint.files.count > 5 {
      let all = ActionButton("View all \(checkpoint.files.count) files…") { open(nil) }
      all.bezelStyle = .inline
      all.alignment = .left
      all.isEnabled = checkpoint.unavailableReason == nil
      all.heightAnchor.constraint(equalToConstant: 22).isActive = true
      stack.addArrangedSubview(all)
    }
    for row in stack.arrangedSubviews {
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
    ])
    setAccessibilityLabel("Changes from turn \(checkpoint.turnCount)")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
