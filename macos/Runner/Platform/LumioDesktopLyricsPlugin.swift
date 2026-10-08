import Cocoa
import FlutterMacOS

final class LumioDesktopLyricsPlugin: NSObject, FlutterPlugin, NSWindowDelegate {
  private let channel: FlutterMethodChannel
  private let spectrum: LumioAudioSpectrum
  private var spectrumEnabled = true
  private let defaults = UserDefaults.standard
  private var panel: LyricsPanel?
  private var lyricsView: LyricsView?
  private var enabled = false
  private var locked = false
  private var transparency: Double = 0
  private var isAudio = true
  private var hasSnapshot = false
  private let enabledKey = "lumio.desktopLyrics.enabled"
  private let lockedKey = "lumio.desktopLyrics.locked"
  private let originKey = "lumio.desktopLyrics.origin"
  private let widthKey = "lumio.desktopLyrics.width"
  private let transparencyKey = "lumio.desktopLyrics.transparency"
  private let maximumTransparency: Double = 0.6
  private let minimumWidth: CGFloat = 360
  private let maximumWidth: CGFloat = 720
  private let panelHeight: CGFloat = 70

  static func register(with registrar: FlutterPluginRegistrar) {}

  init(registrar: FlutterPluginRegistrar, spectrum: LumioAudioSpectrum) {
    self.spectrum = spectrum
    channel = FlutterMethodChannel(
      name: "lumio/desktop_lyrics", binaryMessenger: registrar.messenger
    )
    super.init()
    spectrum.onDesktopBands = { [weak self] bands in self?.lyricsView?.setSpectrum(bands) }
    enabled = defaults.bool(forKey: enabledKey)
    locked = defaults.bool(forKey: lockedKey)
    let savedTransparency = defaults.double(forKey: transparencyKey)
    transparency = savedTransparency.isFinite
      ? min(max(savedTransparency, 0), maximumTransparency) : 0
    registrar.addMethodCallDelegate(self, channel: channel)
    NotificationCenter.default.addObserver(
      self, selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification, object: nil
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getSettings":
      result(settings)
    case "configure":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalidArguments", message: "桌面歌词设置无效。", details: nil))
        return
      }
      if let rawValue = args["transparency"] {
        guard let value = rawValue as? NSNumber, value.doubleValue.isFinite else {
          result(FlutterError(code: "invalidArguments", message: "桌面歌词透明度无效。", details: nil))
          return
        }
        transparency = min(max(value.doubleValue, 0), maximumTransparency)
      }
      if let value = args["enabled"] as? Bool { enabled = value }
      if let value = args["locked"] as? Bool { locked = value }
      persistSettings()
      reconcileVisibility()
      result(settings)
    case "update":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalidArguments", message: "桌面歌词内容无效。", details: nil))
        return
      }
      hasSnapshot = true
      isAudio = args["audio"] as? Bool ?? false
      spectrumEnabled = args["spectrumEnabled"] as? Bool ?? true
      if enabled && isAudio {
        ensurePanel()
        lyricsView?.applyAppearance(args)
        lyricsView?.setProgress((args["progress"] as? NSNumber)?.doubleValue ?? 0)
        lyricsView?.setControlsEnabled(args["canControl"] as? Bool ?? false)
        lyricsView?.calibrationMediaId = args["canCalibrate"] as? Bool == true
          ? args["mediaId"] as? String : nil
        lyricsView?.update(
          title: String((args["title"] as? String ?? "忆光").prefix(300)),
          current: String((args["current"] as? String ?? "").prefix(1024)),
          next: String((args["next"] as? String ?? "").prefix(1024)),
          playing: args["playing"] as? Bool ?? false,
          locked: locked
        )
      }
      reconcileVisibility()
      result(nil)
    case "resetPosition":
      locked = false
      defaults.removeObject(forKey: originKey)
      persistSettings()
      ensurePanel()
      placePanel(reset: true)
      reconcileVisibility()
      if enabled && isAudio && hasSnapshot { panel?.makeKeyAndOrderFront(nil) }
      result(settings)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private var settings: [String: Any] {
    ["enabled": enabled, "locked": locked, "transparency": transparency]
  }

  private func persistSettings() {
    defaults.set(enabled, forKey: enabledKey)
    defaults.set(locked, forKey: lockedKey)
    defaults.set(transparency, forKey: transparencyKey)
  }

  private func ensurePanel() {
    guard panel == nil else { return }
    let window = LyricsPanel(
      contentRect: NSRect(x: 0, y: 0, width: maximumWidth, height: panelHeight),
      styleMask: [.borderless, .nonactivatingPanel, .resizable],
      backing: .buffered, defer: false
    )
    window.title = "忆光 · 桌面歌词"
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    window.isFloatingPanel = true
    window.becomesKeyOnlyIfNeeded = true
    window.hidesOnDeactivate = false
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.alphaValue = CGFloat(1 - transparency)
    window.hasShadow = true
    window.isMovableByWindowBackground = true
    window.minSize = NSSize(width: minimumWidth, height: panelHeight)
    window.maxSize = NSSize(width: maximumWidth, height: panelHeight)
    let content = LyricsView(frame: NSRect(x: 0, y: 0, width: maximumWidth, height: panelHeight))
    content.onClose = { [weak self] in
      guard let self else { return }
      self.enabled = false
      self.persistSettings()
      self.reconcileVisibility()
      self.channel.invokeMethod("settingsChanged", arguments: self.settings)
    }
    content.onLock = { [weak self] in
      guard let self else { return }
      self.locked = true
      self.persistSettings()
      self.reconcileVisibility()
      self.channel.invokeMethod("settingsChanged", arguments: self.settings)
    }
    content.onPlaybackAction = { [weak self] action in
      guard let self, self.enabled, !self.locked, self.isAudio else { return }
      self.channel.invokeMethod("playbackAction", arguments: action)
    }
    content.onActivate = { [weak self] in
      guard let self, self.enabled, !self.locked else { return }
      self.activateMainWindow()
    }
    content.onCalibrate = { [weak self] mediaId in
      guard let self, self.enabled, !self.locked, self.isAudio else { return }
      self.activateMainWindow()
      self.channel.invokeMethod("openLyricCalibration", arguments: mediaId)
    }
    window.contentView = content
    panel = window
    lyricsView = content
    placePanel(reset: false)
    window.delegate = self
  }

  private func activateMainWindow() {
    guard let window = NSApp.windows.first(where: { $0.contentViewController is FlutterViewController }) else { return }
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.deminiaturize(nil)
    window.makeKeyAndOrderFront(nil)
  }

  private func reconcileVisibility() {
    panel?.alphaValue = CGFloat(1 - transparency)
    guard enabled && isAudio && hasSnapshot else {
      spectrum.setDesktopRequested(false)
      panel?.orderOut(nil)
      return
    }
    ensurePanel()
    panel?.ignoresMouseEvents = locked
    panel?.isMovableByWindowBackground = !locked
    lyricsView?.setLocked(locked)
    // 不激活主应用，也不在每次歌词变化时重新抢占窗口层级。
    if panel?.isVisible == false { panel?.orderFrontRegardless() }
    spectrum.setDesktopRequested(spectrumEnabled && panel?.isVisible == true)
  }

  private func placePanel(reset: Bool) {
    guard let panel, let mainScreen = NSScreen.main ?? NSScreen.screens.first else { return }
    var frame = panel.frame
    let savedWidth = defaults.double(forKey: widthKey)
    frame.size.width = savedWidth.isFinite && savedWidth > 0
      ? min(max(CGFloat(savedWidth), minimumWidth), maximumWidth) : maximumWidth
    if !reset, let saved = defaults.dictionary(forKey: originKey),
       let x = saved["x"] as? Double, let y = saved["y"] as? Double,
       x.isFinite, y.isFinite {
      frame.origin = NSPoint(x: x, y: y)
    } else {
      frame.origin = NSPoint(
        x: mainScreen.visibleFrame.midX - frame.width / 2,
        y: mainScreen.visibleFrame.minY + 60
      )
    }
    let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? mainScreen
    let bounds = screen.visibleFrame.insetBy(dx: 12, dy: 12)
    let availableWidth = min(maximumWidth, bounds.width)
    panel.minSize = NSSize(width: min(minimumWidth, availableWidth), height: panelHeight)
    panel.maxSize = NSSize(width: availableWidth, height: panelHeight)
    frame.size.width = min(frame.width, availableWidth)
    frame.size.height = panelHeight
    frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
    frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
    panel.setFrame(frame, display: true)
  }

  @objc private func screensChanged() { placePanel(reset: false) }

  func windowDidMove(_ notification: Notification) {
    guard let origin = panel?.frame.origin else { return }
    defaults.set(["x": Double(origin.x), "y": Double(origin.y)], forKey: originKey)
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    if locked { return sender.frame.size }
    return NSSize(
      width: min(max(frameSize.width, sender.minSize.width), sender.maxSize.width),
      height: panelHeight
    )
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard let panel else { return }
    defaults.set(Double(panel.frame.width), forKey: widthKey)
    // 左侧缩放也会改变原点；一并保存并确保窗口留在可见屏幕内。
    windowDidMove(notification)
    placePanel(reset: false)
  }

  deinit { NotificationCenter.default.removeObserver(self) }
}

private final class LyricsPanel: NSPanel {
  // 自动更新只 orderFront；用户主动定位窗口时允许键盘访问原生按钮。
  override var canBecomeKey: Bool { !ignoresMouseEvents }
  override var canBecomeMain: Bool { false }
}

private final class LyricsView: NSView {
  var onActivate: (() -> Void)?
  var onClose: (() -> Void)?
  var onLock: (() -> Void)?
  var onPlaybackAction: ((String) -> Void)?
  var onCalibrate: ((String) -> Void)?
  var calibrationMediaId: String?
  private let titleLabel = NSTextField(labelWithString: "忆光 · 桌面歌词")
  private let currentLabel = NSTextField(wrappingLabelWithString: "等待播放音乐…")
  private let nextLabel = NSTextField(labelWithString: "")
  private let lockButton = NSButton(title: "锁定", target: nil, action: nil)
  private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
  private let previousButton = NSButton(title: "", target: nil, action: nil)
  private let playButton = NSButton(title: "", target: nil, action: nil)
  private let nextButton = NSButton(title: "", target: nil, action: nil)
  private var locked = false
  private var isHovered = false
  private var hoverTrackingArea: NSTrackingArea?
  private var clickStart: NSEvent?
  private var didDrag = false
  private let spectrumLayer = CAGradientLayer()
  private let spectrumMask = CAShapeLayer()
  private var spectrumBands = [Double](repeating: 0, count: 24)
  private let progressLayer = CALayer()
  private let progressClip = CAShapeLayer()
  private let progressTrack = CALayer()
  private let progressFill = CALayer()
  private var progress: CGFloat = 0
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    if hit === titleLabel || hit === currentLabel || hit === nextLabel { return self }
    return hit
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.backgroundColor = NSColor(srgbRed: 0.97, green: 0.99, blue: 0.96, alpha: 0.82).cgColor
    layer?.borderWidth = 1
    layer?.borderColor = NSColor(srgbRed: 0.70, green: 0.86, blue: 0.78, alpha: 1).cgColor
    spectrumLayer.startPoint = CGPoint(x: 0, y: 0)
    spectrumLayer.endPoint = CGPoint(x: 1, y: 0)
    spectrumLayer.mask = spectrumMask
    layer?.insertSublayer(spectrumLayer, at: 0)
    let ink = NSColor(srgbRed: 0.15, green: 0.42, blue: 0.36, alpha: 1)
    progressLayer.mask = progressClip
    progressLayer.addSublayer(progressTrack)
    progressLayer.addSublayer(progressFill)
    progressTrack.backgroundColor = ink.withAlphaComponent(0.12).cgColor
    progressFill.backgroundColor = ink.withAlphaComponent(0.65).cgColor
    layer?.addSublayer(progressLayer)
    titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
    titleLabel.textColor = ink.withAlphaComponent(0.8)
    titleLabel.lineBreakMode = .byTruncatingTail
    currentLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    currentLabel.textColor = ink
    currentLabel.alignment = .center
    currentLabel.maximumNumberOfLines = 1
    currentLabel.lineBreakMode = .byTruncatingTail
    nextLabel.font = .systemFont(ofSize: 11, weight: .medium)
    nextLabel.textColor = ink.withAlphaComponent(0.7)
    nextLabel.alignment = .center
    nextLabel.lineBreakMode = .byTruncatingTail
    for label in [titleLabel, currentLabel, nextLabel] {
      label.isSelectable = false
      addSubview(label)
    }
    for button in [lockButton, closeButton] {
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.font = .systemFont(ofSize: 11)
      button.target = self
      addSubview(button)
    }
    lockButton.action = #selector(lockLyrics)
    lockButton.toolTip = "锁定并穿透鼠标；从设置或显示菜单解锁"
    closeButton.action = #selector(closeLyrics)
    closeButton.toolTip = "关闭桌面歌词，不停止音乐"
    for (button, symbol, label, action) in [
      (previousButton, "backward.end.fill", "上一首", #selector(previousTrack)),
      (playButton, "play.fill", "播放", #selector(togglePlayback)),
      (nextButton, "forward.end.fill", "下一首", #selector(nextTrack))
    ] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
      button.imagePosition = .imageOnly
      button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.toolTip = label
      button.setAccessibilityLabel(label)
      button.target = self
      button.action = action
      button.isEnabled = false
      addSubview(button)
    }
    updateControlsVisibility()
    needsLayout = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverTrackingArea = area
    refreshHoverState()
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    updateControlsVisibility()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updateControlsVisibility()
  }

  private func refreshHoverState() {
    if let window, window.isVisible {
      isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    } else {
      isHovered = false
    }
    updateControlsVisibility()
  }

  private func updateControlsVisibility() {
    for button in [previousButton, playButton, nextButton, lockButton, closeButton] {
      button.isHidden = locked || !isHovered
    }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    spectrumLayer.frame = bounds
    spectrumMask.frame = bounds
    CATransaction.commit()
    drawSpectrum(animated: false)
    layoutProgress()
    titleLabel.frame = NSRect(x: 14, y: 6,
      width: max(0, bounds.width - (locked ? 28 : 238)), height: 16)
    previousButton.frame = NSRect(x: bounds.width - 218, y: 3, width: 28, height: 22)
    playButton.frame = NSRect(x: bounds.width - 188, y: 3, width: 28, height: 22)
    nextButton.frame = NSRect(x: bounds.width - 158, y: 3, width: 28, height: 22)
    lockButton.frame = NSRect(x: bounds.width - 122, y: 3, width: 52, height: 22)
    closeButton.frame = NSRect(x: bounds.width - 64, y: 3, width: 52, height: 22)
    currentLabel.frame = NSRect(x: 16, y: 27, width: bounds.width - 32, height: 20)
    nextLabel.frame = NSRect(x: 16, y: 49, width: bounds.width - 32, height: 16)
  }

  func update(title: String, current: String, next: String, playing: Bool, locked: Bool) {
    titleLabel.stringValue = title
    currentLabel.stringValue = current
    nextLabel.stringValue = next
    let playLabel = playing ? "暂停" : "播放"
    playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
      accessibilityDescription: playLabel)
    playButton.toolTip = playLabel
    playButton.setAccessibilityLabel(playLabel)
    setLocked(locked)
  }

  func setControlsEnabled(_ enabled: Bool) {
    for button in [previousButton, playButton, nextButton] { button.isEnabled = enabled }
  }

  func setProgress(_ value: Double) {
    let next = value.isFinite ? CGFloat(min(1, max(0, value))) : 0
    guard next != progress else { return }
    progress = next
    layoutProgress()
  }

  private func layoutProgress() {
    // Layer-only decoration: no seek/drag target, and no extra playback timer.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    progressLayer.frame = bounds
    progressClip.frame = bounds
    progressClip.path = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
    let height: CGFloat = 2
    let bottom = bounds.height - height
    progressTrack.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: height)
    progressFill.frame = CGRect(x: 0, y: bottom, width: bounds.width * progress, height: height)
    CATransaction.commit()
  }

  func applyAppearance(_ args: [String: Any]) {
    func color(_ key: String) -> NSColor? {
      guard let number = args[key] as? NSNumber else { return nil }
      let argb = number.uint32Value
      return NSColor(
        srgbRed: CGFloat((argb >> 16) & 255) / 255,
        green: CGFloat((argb >> 8) & 255) / 255,
        blue: CGFloat(argb & 255) / 255,
        alpha: CGFloat((argb >> 24) & 255) / 255
      )
    }
    if let background = color("backgroundColor") {
      layer?.backgroundColor = background.withAlphaComponent(0.82).cgColor
    }
    if let border = color("borderColor") { layer?.borderColor = border.cgColor }
    if let foreground = color("foregroundColor") {
      currentLabel.textColor = foreground
      progressTrack.backgroundColor = foreground.withAlphaComponent(0.12).cgColor
      progressFill.backgroundColor = foreground.withAlphaComponent(0.65).cgColor
      let accent = color("spectrumAccentColor") ?? foreground
      spectrumLayer.colors = [foreground.withAlphaComponent(0.18).cgColor,
        accent.withAlphaComponent(0.10).cgColor]
    }
    if let secondary = color("secondaryColor") {
      titleLabel.textColor = secondary
      nextLabel.textColor = secondary
    }
    if let dark = args["dark"] as? Bool {
      appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
  }

  func setSpectrum(_ bands: [Double]) {
    guard bands.count == 24 else { return }
    let next = bands.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
    guard next != spectrumBands else { return }
    spectrumBands = next
    drawSpectrum(animated: true)
  }

  private func drawSpectrum(animated: Bool) {
    let path = CGMutablePath()
    // Fit the minimum 360pt panel; resizing only adds space on the right.
    let spectrumWidth = min(336, max(0, bounds.width - 24))
    let step = max(1, spectrumWidth / 24)
    let width = min(7, step * 0.46)
    let maximumHeight = max(0, bounds.height - 6)
    for i in 0..<24 {
      let height = max(0.001, CGFloat(spectrumBands[i]) * maximumHeight)
      let x = 12 + (CGFloat(i) + 0.5) * step
      // This flipped view uses top-down coordinates; bars stay inside the panel.
      let left = x - width / 2, right = x + width / 2
      let bottom = bounds.height - 3, top = bottom - height
      let radius = min(width, height) / 2
      // Keep identical path commands even at zero height, avoiding malformed
      // intermediate shapes when Core Animation interpolates rounded bars.
      path.move(to: CGPoint(x: left + radius, y: top))
      path.addLine(to: CGPoint(x: right - radius, y: top))
      path.addQuadCurve(to: CGPoint(x: right, y: top + radius), control: CGPoint(x: right, y: top))
      path.addLine(to: CGPoint(x: right, y: bottom))
      path.addLine(to: CGPoint(x: left, y: bottom))
      path.addLine(to: CGPoint(x: left, y: top + radius))
      path.addQuadCurve(to: CGPoint(x: left + radius, y: top), control: CGPoint(x: left, y: top))
      path.closeSubpath()
    }
    if animated, let previous = spectrumMask.presentation()?.path ?? spectrumMask.path {
      let animation = CABasicAnimation(keyPath: "path")
      animation.fromValue = previous
      animation.toValue = path
      animation.duration = 0.10
      spectrumMask.add(animation, forKey: "spectrum")
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    spectrumMask.path = path
    CATransaction.commit()
  }

  func setLocked(_ value: Bool) {
    let changed = value != locked
    locked = value
    refreshHoverState()
    if changed { needsLayout = true }
  }

  override func mouseDown(with event: NSEvent) {
    clickStart = locked ? nil : event
    didDrag = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard !locked, !didDrag, let start = clickStart else { return }
    let delta = NSPoint(x: event.locationInWindow.x - start.locationInWindow.x,
      y: event.locationInWindow.y - start.locationInWindow.y)
    guard hypot(delta.x, delta.y) >= 4 else { return }
    // 原生拖动可能消费 mouseUp；在进入拖动循环前排除本次单击。
    didDrag = true
    window?.performDrag(with: start)
  }

  override func mouseUp(with event: NSEvent) {
    defer { clickStart = nil }
    guard !locked, clickStart != nil, !didDrag,
          bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onActivate?()
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard !locked, let mediaId = calibrationMediaId, !mediaId.isEmpty else { return nil }
    let menu = NSMenu()
    let item = NSMenuItem(title: "校准歌词（仅此歌曲）", action: #selector(calibrateLyrics(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = mediaId
    menu.addItem(item)
    return menu
  }

  @objc private func calibrateLyrics(_ sender: NSMenuItem) {
    guard !locked, let mediaId = sender.representedObject as? String,
          mediaId == calibrationMediaId else { return }
    onCalibrate?(mediaId)
  }

  @objc private func lockLyrics() { onLock?() }
  @objc private func closeLyrics() { onClose?() }
  @objc private func previousTrack() { onPlaybackAction?("previous") }
  @objc private func togglePlayback() { onPlaybackAction?("togglePlaying") }
  @objc private func nextTrack() { onPlaybackAction?("next") }
}
