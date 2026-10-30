import UIKit

/// A small offline keyboard. Recording and model inference run only in the containing app.
final class KeyboardViewController: UIInputViewController {
  private let store = KeyboardSessionStore.shared()
  private let consumer = KeyboardResultConsumer(defaults: .standard)
  private let statusLabel = UILabel()
  private let previewLabel = UITextView()
  private let contentStack = UIStackView()
  private var heightConstraint: NSLayoutConstraint?
  private let voiceButton = UIButton(type: .system)
  private var snapshot: KeyboardSessionSnapshot?
  private var pendingStopID: UUID?
  private var refreshTask: Task<Void, Never>?
  private var showsNumbers = false
  private var uppercase = false
  private let keyRows = UIStackView()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .secondarySystemBackground
    let stack = contentStack
    stack.axis = .vertical
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
    ])
    statusLabel.font = .preferredFont(forTextStyle: .footnote)
    statusLabel.numberOfLines = 2
    statusLabel.accessibilityIdentifier = "keyboardStatus"
    previewLabel.font = .preferredFont(forTextStyle: .body)
    previewLabel.isEditable = false
    previewLabel.isSelectable = false
    previewLabel.backgroundColor = .clear
    previewLabel.textContainerInset = .zero
    let previewHeight = previewLabel.heightAnchor.constraint(equalToConstant: 64)
    previewHeight.priority = UILayoutPriority(999)
    previewHeight.isActive = true
    previewLabel.accessibilityIdentifier = "keyboardTranscriptPreview"
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(previewLabel)
    voiceButton.configuration = .filled()
    voiceButton.addTarget(self, action: #selector(voiceAction), for: .touchUpInside)
    voiceButton.accessibilityIdentifier = "keyboardVoiceAction"
    voiceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    stack.addArrangedSubview(voiceButton)
    keyRows.axis = .vertical
    keyRows.spacing = 6
    stack.addArrangedSubview(keyRows)
    let height = view.heightAnchor.constraint(equalToConstant: 320)
    height.priority = UILayoutPriority(999)
    height.isActive = true
    heightConstraint = height
    buildKeys()
    refresh()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let fitted = contentStack.systemLayoutSizeFitting(
      CGSize(width: max(1, view.bounds.width - 16), height: 0),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    let height = ceil(fitted.height + 16)
    if abs((heightConstraint?.constant ?? 0) - height) > 1 {
      heightConstraint?.constant = height
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.refresh()
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      }
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    refreshTask?.cancel()
    refreshTask = nil
  }

  @objc private func refresh() {
    do {
      snapshot = try store?.read()
      previewLabel.text = snapshot?.phase == .ready ? snapshot?.text : nil
      previewLabel.isHidden = previewLabel.text == nil
      voiceButton.isEnabled = false
      voiceButton.setTitle(localized("iosApp.keyboardStartInApp"), for: .normal)
      guard let snapshot else {
        statusLabel.text = localized("iosApp.keyboardIdle")
        return
      }
      switch snapshot.phase {
      case .recording:
        statusLabel.text = localized(
          hasFullAccess ? "iosApp.keyboardRecording" : "iosApp.keyboardFullAccess")
        voiceButton.setTitle(localized("iosApp.stop"), for: .normal)
        voiceButton.isEnabled = hasFullAccess && pendingStopID != snapshot.id
      case .transcribing:
        statusLabel.text = localized("iosApp.transcribing")
      case .ready:
        let available = consumer.canInsert(snapshot)
        statusLabel.text = localized(
          available ? "iosApp.keyboardReview" : "iosApp.keyboardInserted")
        voiceButton.setTitle(localized("iosApp.keyboardInsert"), for: .normal)
        voiceButton.isEnabled = available
      case .failed:
        statusLabel.text = localized("iosApp.keyboardFailed")
      }
    } catch {
      snapshot = nil
      previewLabel.isHidden = true
      voiceButton.isEnabled = false
      statusLabel.text = localized("iosApp.keyboardUnavailable")
    }
  }

  @objc private func voiceAction() {
    do {
      // Re-read after the tap: a result may expire or another session may replace it.
      guard let current = try store?.read(), current.id == snapshot?.id else {
        refresh()
        return
      }
      if current.phase == .recording, hasFullAccess {
        try store?.requestStop(for: current.id)
        pendingStopID = current.id
      } else if let text = consumer.consume(current) {
        textDocumentProxy.insertText(text)
      }
      refresh()
    } catch {
      statusLabel.text = localized("iosApp.keyboardUnavailable")
      voiceButton.isEnabled = false
    }
  }

  private func buildKeys() {
    for row in keyRows.arrangedSubviews {
      keyRows.removeArrangedSubview(row)
      row.removeFromSuperview()
    }
    let rows =
      showsNumbers
      ? ["1234567890", "-/:;()$&@\"", ".,?!'#+=*%"]
      : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    for characters in rows {
      let row = makeRow()
      for character in characters {
        let value = uppercase ? String(character).uppercased() : String(character)
        let button = makeButton(value) { [weak self] in self?.textDocumentProxy.insertText(value) }
        row.addArrangedSubview(button)
      }
      keyRows.addArrangedSubview(row)
    }
    let controls = makeRow()
    let globe = makeButton("🌐") {}
    globe.accessibilityLabel = localized("iosApp.keyboardNext")
    globe.addTarget(self, action: #selector(nextKeyboard(_:event:)), for: .allTouchEvents)
    controls.addArrangedSubview(globe)
    controls.addArrangedSubview(
      makeButton(showsNumbers ? "ABC" : "123") { [weak self] in
        guard let self else { return }
        self.showsNumbers.toggle()
        self.buildKeys()
      })
    let shift = makeButton("⇧") { [weak self] in
      guard let self else { return }
      self.uppercase.toggle()
      self.buildKeys()
    }
    shift.accessibilityLabel = localized("iosApp.keyboardShift")
    shift.isSelected = uppercase
    controls.addArrangedSubview(shift)
    controls.addArrangedSubview(
      makeButton(localized("iosApp.keyboardSpace")) { [weak self] in
        self?.textDocumentProxy.insertText(" ")
      })
    let delete = makeButton("⌫") { [weak self] in self?.textDocumentProxy.deleteBackward() }
    delete.accessibilityLabel = localized("iosApp.keyboardDelete")
    controls.addArrangedSubview(delete)
    let newline = makeButton("↵") { [weak self] in self?.textDocumentProxy.insertText("\n") }
    newline.accessibilityLabel = localized("iosApp.keyboardReturn")
    controls.addArrangedSubview(newline)
    keyRows.addArrangedSubview(controls)
  }

  private func makeRow() -> UIStackView {
    let row = UIStackView()
    row.axis = .horizontal
    row.distribution = .fillEqually
    row.spacing = 4
    return row
  }

  private func makeButton(_ title: String, action: @escaping @MainActor () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
    button.backgroundColor = .tertiarySystemBackground
    button.layer.cornerRadius = 5
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    return button
  }

  @objc private func nextKeyboard(_ sender: UIButton, event: UIEvent) {
    handleInputModeList(from: sender, with: event)
  }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
  }
}
