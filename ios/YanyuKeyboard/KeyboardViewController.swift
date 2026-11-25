import UIKit

/// Typing and dictation controls. The containing app owns microphone access and inference.
final class KeyboardViewController: UIInputViewController {
  private struct PendingAction {
    enum Kind { case start, stop, cancel }
    let kind: Kind
    let sessionID: UUID
    let deadline = ContinuousClock.now.advanced(by: .seconds(KeyboardSessionStore.liveLifetime))
  }

  private let store = KeyboardSessionStore.shared()
  private let consumer = KeyboardResultConsumer(defaults: .standard)
  private let delivery = KeyboardTextDelivery(defaults: .standard)
  private let statusLabel = UILabel()
  private let previewLabel = UITextView()
  private let contentStack = UIStackView()
  private let keyRows = UIStackView()
  private let voicePanel = KeyboardVoicePanel()
  private let voiceButton = UIButton(type: .system)
  private let cancelButton = UIButton(type: .system)
  private let undoButton = UIButton(type: .system)
  private let keyboardSwitcher = UIStackView()
  private var heightConstraint: NSLayoutConstraint?
  private var snapshot: KeyboardSessionSnapshot?
  private var pendingAction: PendingAction?
  private var refreshTask: Task<Void, Never>?
  private var showsNumbers = false
  private var uppercase = false

  override func viewDidLoad() {
    super.viewDidLoad()
    hasDictationKey = true
    view.backgroundColor = .secondarySystemBackground
    configureLayout()
    buildKeys()
    refresh()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    keyboardSwitcher.isHidden = !needsInputModeSwitchKey
    updateHeight()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.refresh()
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      }
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    refreshTask?.cancel()
    refreshTask = nil
    delivery.invalidateContext()
  }

  override func textWillChange(_ textInput: (any UITextInput)?) {
    super.textWillChange(textInput)
    delivery.invalidateContext()
  }

  override func selectionWillChange(_ textInput: (any UITextInput)?) {
    super.selectionWillChange(textInput)
    delivery.invalidateContext()
  }

  private func configureLayout() {
    contentStack.axis = .vertical
    contentStack.spacing = 8
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(contentStack)
    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
      contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
      contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
    ])

    contentStack.addArrangedSubview(makeToolbar())
    previewLabel.font = .preferredFont(forTextStyle: .body)
    previewLabel.adjustsFontForContentSizeCategory = true
    previewLabel.isEditable = false
    previewLabel.isSelectable = false
    previewLabel.backgroundColor = .tertiarySystemBackground
    previewLabel.layer.cornerRadius = 8
    previewLabel.accessibilityIdentifier = "keyboardTranscriptPreview"
    let previewHeight = previewLabel.heightAnchor.constraint(equalToConstant: 60)
    previewHeight.priority = .defaultHigh
    previewHeight.isActive = true
    contentStack.addArrangedSubview(previewLabel)

    keyRows.axis = .vertical
    keyRows.distribution = .fillEqually
    keyRows.spacing = 6
    let body = UIView()
    for panel in [keyRows, voicePanel] as [UIView] {
      panel.translatesAutoresizingMaskIntoConstraints = false
      body.addSubview(panel)
      NSLayoutConstraint.activate([
        panel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
        panel.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        panel.topAnchor.constraint(equalTo: body.topAnchor),
        panel.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      ])
    }
    contentStack.addArrangedSubview(body)

    let globe = UIButton(type: .system)
    configureTool(globe, symbol: "globe", label: "iosApp.keyboardNext", style: .plain())
    globe.addTarget(self, action: #selector(nextKeyboard(_:event:)), for: .allTouchEvents)
    keyboardSwitcher.addArrangedSubview(globe)
    keyboardSwitcher.addArrangedSubview(UIView())
    keyboardSwitcher.isHidden = !needsInputModeSwitchKey
    contentStack.addArrangedSubview(keyboardSwitcher)

    let height = view.heightAnchor.constraint(equalToConstant: 268)
    height.priority = UILayoutPriority(999)
    height.isActive = true
    heightConstraint = height
  }

  private func makeToolbar() -> UIStackView {
    let toolbar = UIStackView()
    toolbar.alignment = .center
    toolbar.spacing = 8

    configureTool(cancelButton, symbol: "xmark", label: "iosApp.cancel", style: .tinted())
    cancelButton.accessibilityIdentifier = "keyboardCancelDictation"
    cancelButton.addTarget(self, action: #selector(cancelDictation), for: .touchUpInside)
    toolbar.addArrangedSubview(cancelButton)

    statusLabel.font = .preferredFont(forTextStyle: .footnote)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.numberOfLines = 2
    statusLabel.accessibilityIdentifier = "keyboardStatus"
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    toolbar.addArrangedSubview(statusLabel)
    toolbar.addArrangedSubview(UIView())

    configureTool(
      undoButton, symbol: "arrow.uturn.backward", label: "iosApp.keyboardUndo", style: .tinted())
    undoButton.accessibilityIdentifier = "keyboardUndoAction"
    undoButton.addTarget(self, action: #selector(undoInsertion), for: .touchUpInside)
    toolbar.addArrangedSubview(undoButton)

    var voiceStyle = UIButton.Configuration.filled()
    voiceStyle.baseBackgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.28, green: 0.33, blue: 0.72, alpha: 1)
        : UIColor(red: 0.17, green: 0.23, blue: 0.60, alpha: 1)
    }
    voiceStyle.baseForegroundColor = .white
    configureTool(
      voiceButton, symbol: "mic.fill", label: "iosApp.keyboardStartRecording", style: voiceStyle)
    voiceButton.accessibilityIdentifier = "keyboardVoiceAction"
    voiceButton.addTarget(self, action: #selector(voiceAction), for: .touchUpInside)
    toolbar.addArrangedSubview(voiceButton)
    return toolbar
  }

  private func configureTool(
    _ button: UIButton, symbol: String, label: String, style: UIButton.Configuration
  ) {
    var configuration = style
    configuration.cornerStyle = .large
    configuration.contentInsets = .zero
    configuration.image = UIImage(systemName: symbol)
    configuration.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .semibold)
    button.configuration = configuration
    button.accessibilityLabel = localized(label)
    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    button.heightAnchor.constraint(equalToConstant: 44).isActive = true
  }

  private func updateHeight() {
    let baseHeight: CGFloat = traitCollection.verticalSizeClass == .compact ? 218 : 268
    heightConstraint?.constant =
      baseHeight + (previewLabel.isHidden ? 0 : 68) + (keyboardSwitcher.isHidden ? 0 : 52)
  }

  private func refresh() {
    let document = ProxyKeyboardDocument(proxy: textDocumentProxy)
    do {
      let current = try store?.read()
      snapshot = current
      updatePendingAction(with: current)
      var reviewText: String?
      var receiptPending = false
      if let current, current.phase == .ready, try store?.isResultHandled(for: current.id) != true {
        if view.window != nil, hasFullAccess {
          _ = delivery.insert(current, into: document, automatically: true)
        }
        if consumer.hasConsumed(current.id), hasFullAccess {
          do {
            try store?.markResultHandled(for: current.id)
          } catch {
            // A failed receipt can be retried without repeating the insertion.
            receiptPending = true
          }
        }
        if consumer.canInsert(current) { reviewText = current.text }
      }
      undoButton.isHidden = !delivery.canUndo(in: document.context)
      previewLabel.text = reviewText
      previewLabel.isHidden = reviewText == nil
      render(reviewAvailable: reviewText != nil, receiptPending: receiptPending)
    } catch {
      snapshot = nil
      pendingAction = nil
      delivery.invalidateContext()
      undoButton.isHidden = true
      previewLabel.isHidden = true
      showTyping(status: "iosApp.keyboardUnavailable")
    }
    updateHeight()
  }

  private func updatePendingAction(with snapshot: KeyboardSessionSnapshot?) {
    guard let pendingAction else { return }
    let phase = snapshot?.phase
    if snapshot?.id != pendingAction.sessionID
      || ContinuousClock.now >= pendingAction.deadline
      || (pendingAction.kind == .start && phase != .standby)
      || (pendingAction.kind == .stop && phase != .recording)
      || (pendingAction.kind == .cancel && phase != .standby && phase != .recording)
    {
      self.pendingAction = nil
    }
  }

  private func render(reviewAvailable: Bool, receiptPending: Bool) {
    if hasFullAccess {
      switch pendingAction?.kind {
      case .start:
        showVoice("iosApp.keyboardStarting", loading: true, canCancel: true)
        return
      case .stop:
        showVoice("iosApp.transcribing", loading: true)
        return
      case .cancel:
        showTyping(status: "iosApp.keyboardCancelling")
        return
      case nil: break
      }
      if snapshot?.phase == .recording {
        showVoice(
          "iosApp.keyboardListening",
          source: snapshot?.microphoneName ?? localized("iosApp.keyboardMicrophone"),
          level: snapshot?.audioLevel ?? 0, canCancel: true, canConfirm: true)
        return
      }
    }
    switch snapshot?.phase {
    case .transcribing where hasFullAccess:
      showVoice("iosApp.transcribing", loading: true)
    case .ready:
      let status =
        receiptPending
        ? "iosApp.keyboardHandlingPending"
        : reviewAvailable ? "iosApp.keyboardReview" : "iosApp.keyboardInserted"
      showTyping(status: status, canInsert: reviewAvailable)
    case .failed:
      showTyping(status: "iosApp.keyboardFailed")
    case .standby where hasFullAccess:
      showTyping(status: "iosApp.keyboardMicrophoneReady", canStart: true)
    default:
      showTyping(status: hasFullAccess ? "iosApp.keyboardIdle" : "iosApp.keyboardFullAccess")
    }
  }

  private func showTyping(status: String, canStart: Bool = false, canInsert: Bool = false) {
    keyRows.isHidden = false
    voicePanel.isHidden = true
    statusLabel.isHidden = false
    statusLabel.text = localized(status)
    cancelButton.isHidden = true
    setVoiceButton(
      symbol: canInsert ? nil : "mic.fill",
      label: canInsert ? "iosApp.keyboardInsert" : "iosApp.keyboardStartRecording",
      enabled: canStart || canInsert)
  }

  private func showVoice(
    _ status: String, source: String? = nil, level: Float = 0, loading: Bool = false,
    canCancel: Bool = false, canConfirm: Bool = false
  ) {
    keyRows.isHidden = true
    statusLabel.isHidden = true
    undoButton.isHidden = true
    cancelButton.isHidden = !canCancel
    voicePanel.isHidden = false
    voicePanel.update(status: localized(status), source: source, level: level, loading: loading)
    setVoiceButton(symbol: "checkmark", label: "iosApp.keyboardConfirm", enabled: canConfirm)
  }

  private func setVoiceButton(symbol: String?, label: String, enabled: Bool) {
    let title = localized(label)
    if voiceButton.accessibilityLabel != title, var configuration = voiceButton.configuration {
      configuration.image = symbol.flatMap { UIImage(systemName: $0) }
      configuration.title = symbol == nil ? title : nil
      configuration.contentInsets =
        symbol == nil ? .init(top: 0, leading: 12, bottom: 0, trailing: 12) : .zero
      voiceButton.configuration = configuration
    }
    voiceButton.accessibilityLabel = title
    voiceButton.isEnabled = enabled
  }

  @objc private func voiceAction() {
    do {
      // A tap must still match the session shown by the keyboard.
      guard let store, let current = try store.read(), current.id == snapshot?.id,
        current.phase == snapshot?.phase, pendingAction == nil
      else {
        refresh()
        return
      }
      let document = ProxyKeyboardDocument(proxy: textDocumentProxy)
      switch current.phase {
      case .standby where hasFullAccess:
        let context = document.context
        try store.requestStart(for: current.id)
        delivery.trackContext(for: current.id, in: context)
        pendingAction = PendingAction(kind: .start, sessionID: current.id)
      case .recording where hasFullAccess:
        try store.requestStop(for: current.id)
        if current.startedFromKeyboard == true {
          delivery.confirmAutomaticInsertion(for: current.id)
        } else {
          delivery.prepareAutomaticInsertion(for: current.id, in: document.context)
        }
        pendingAction = PendingAction(kind: .stop, sessionID: current.id)
      case .ready where try !store.isResultHandled(for: current.id):
        _ = delivery.insert(current, into: document)
      default: break
      }
      refresh()
    } catch {
      delivery.invalidateContext()
      showTyping(status: "iosApp.keyboardUnavailable")
    }
  }

  @objc private func cancelDictation() {
    guard let store, let snapshot, hasFullAccess else { return }
    do {
      try store.requestCancel(for: snapshot.id)
      delivery.invalidateContext()
      pendingAction = PendingAction(kind: .cancel, sessionID: snapshot.id)
      refresh()
    } catch {
      refresh()
    }
  }

  @objc private func undoInsertion() {
    _ = delivery.undo(in: ProxyKeyboardDocument(proxy: textDocumentProxy))
    refresh()
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
        row.addArrangedSubview(makeKey(value) { [weak self] in self?.typeText(value) })
      }
      keyRows.addArrangedSubview(row)
    }
    let controls = makeRow()
    controls.distribution = .fill
    let numbers = makeKey(showsNumbers ? "ABC" : "123") { [weak self] in
      guard let self else { return }
      showsNumbers.toggle()
      buildKeys()
    }
    controls.addArrangedSubview(numbers)
    if !showsNumbers {
      let shift = makeKey("⇧") { [weak self] in
        guard let self else { return }
        uppercase.toggle()
        buildKeys()
      }
      shift.accessibilityLabel = localized("iosApp.keyboardShift")
      shift.isSelected = uppercase
      if uppercase { shift.backgroundColor = .systemFill }
      controls.addArrangedSubview(shift)
      shift.widthAnchor.constraint(equalTo: numbers.widthAnchor).isActive = true
    }
    let space = makeKey(localized("iosApp.keyboardSpace")) { [weak self] in self?.typeText(" ") }
    space.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
    controls.addArrangedSubview(space)
    let delete = makeKey("⌫") { [weak self] in
      guard let self else { return }
      delivery.invalidateContext()
      textDocumentProxy.deleteBackward()
      refresh()
    }
    delete.accessibilityLabel = localized("iosApp.keyboardDelete")
    controls.addArrangedSubview(delete)
    let newline = makeKey("↵") { [weak self] in self?.typeText("\n") }
    newline.accessibilityLabel = localized("iosApp.keyboardReturn")
    controls.addArrangedSubview(newline)
    for key in [numbers, delete, newline] {
      key.widthAnchor.constraint(equalToConstant: 48).isActive = true
    }
    keyRows.addArrangedSubview(controls)
  }

  private func typeText(_ value: String) {
    delivery.invalidateContext()
    textDocumentProxy.insertText(value)
    refresh()
  }

  private func makeRow() -> UIStackView {
    let row = UIStackView()
    row.distribution = .fillEqually
    row.spacing = 5
    return row
  }

  private func makeKey(_ title: String, action: @escaping @MainActor () -> Void) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(.label, for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.backgroundColor = .tertiarySystemBackground
    button.layer.cornerRadius = 8
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

@MainActor
private final class KeyboardVoicePanel: UIView {
  private let title = UILabel()
  private let source = UILabel()
  private let indicator = UIActivityIndicatorView(style: .medium)
  private let waveform = UIStackView()
  private var bars: [NSLayoutConstraint] = []

  init() {
    super.init(frame: .zero)
    backgroundColor = .tertiarySystemBackground
    layer.cornerRadius = 18

    waveform.spacing = 6
    waveform.alignment = .center
    waveform.accessibilityElementsHidden = true
    for _ in 0..<9 {
      let bar = UIView()
      bar.backgroundColor = .systemIndigo
      bar.layer.cornerRadius = 2
      waveform.addArrangedSubview(bar)
      let height = bar.heightAnchor.constraint(equalToConstant: 4)
      NSLayoutConstraint.activate([bar.widthAnchor.constraint(equalToConstant: 4), height])
      bars.append(height)
    }
    let signal = UIView()
    for item in [waveform, indicator] as [UIView] {
      signal.addSubview(item)
      item.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        item.centerXAnchor.constraint(equalTo: signal.centerXAnchor),
        item.centerYAnchor.constraint(equalTo: signal.centerYAnchor),
      ])
    }
    signal.heightAnchor.constraint(equalToConstant: 42).isActive = true

    title.font = .preferredFont(forTextStyle: .headline)
    title.accessibilityIdentifier = "keyboardVoiceStatus"
    source.font = .preferredFont(forTextStyle: .footnote)
    source.textColor = .secondaryLabel
    for label in [title, source] {
      label.adjustsFontForContentSizeCategory = true
      label.textAlignment = .center
      label.numberOfLines = 2
    }

    let content = UIStackView(arrangedSubviews: [signal, title, source])
    content.axis = .vertical
    content.spacing = 4
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func update(status: String, source: String?, level: Float, loading: Bool) {
    title.text = status
    self.source.text = source
    self.source.isHidden = source == nil
    waveform.isHidden = loading
    if loading {
      indicator.startAnimating()
    } else {
      indicator.stopAnimating()
      let amplitude = CGFloat(level.isFinite ? min(max(level, 0), 1) : 0)
      for (bar, scale) in zip(bars, [9, 17, 25, 34, 27, 34, 25, 17, 9] as [CGFloat]) {
        bar.constant = 4 + amplitude * scale
      }
    }
  }
}

@MainActor
private final class ProxyKeyboardDocument: KeyboardTextDocument {
  let proxy: any UITextDocumentProxy

  init(proxy: any UITextDocumentProxy) { self.proxy = proxy }

  var context: KeyboardTextContext {
    KeyboardTextContext(
      documentID: proxy.documentIdentifier,
      before: proxy.documentContextBeforeInput,
      after: proxy.documentContextAfterInput,
      selected: proxy.selectedText,
      hasText: proxy.hasText)
  }

  func insertText(_ text: String) { proxy.insertText(text) }
  func deleteBackward() { proxy.deleteBackward() }
}
