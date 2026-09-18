import Cocoa
import FlutterMacOS

final class LumioDesktopLyricsPlugin: NSObject, FlutterPlugin, NSWindowDelegate {
  private let channel: FlutterMethodChannel
  private let defaults = UserDefaults.standard
  private var panel: LyricsPanel?
  private var lyricsView: LyricsView?
  private var enabled = false
  private var locked = false
  private var isAudio = true
  private var hasSnapshot = false
  private let enabledKey = "lumio.desktopLyrics.enabled"
  private let lockedKey = "lumio.desktopLyrics.locked"
  private let originKey = "lumio.desktopLyrics.origin"

  static func register(with registrar: FlutterPluginRegistrar) {}

  init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(
      name: "lumio/desktop_lyrics", binaryMessenger: registrar.messenger
    )
    super.init()
    enabled = defaults.bool(forKey: enabledKey)
    locked = defaults.bool(forKey: lockedKey)
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
      if enabled && isAudio {
        ensurePanel()
        lyricsView?.applyAppearance(args)
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

  private var settings: [String: Any] { ["enabled": enabled, "locked": locked] }

  private func persistSettings() {
    defaults.set(enabled, forKey: enabledKey)
    defaults.set(locked, forKey: lockedKey)
  }

  private func ensurePanel() {
    guard panel == nil else { return }
    let window = LyricsPanel(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 87),
      styleMask: [.borderless, .nonactivatingPanel],
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
    window.hasShadow = true
    window.isMovableByWindowBackground = true
    let content = LyricsView(frame: NSRect(x: 0, y: 0, width: 720, height: 87))
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
    window.contentView = content
    panel = window
    lyricsView = content
    placePanel(reset: false)
    window.delegate = self
  }

  private func reconcileVisibility() {
    guard enabled && isAudio && hasSnapshot else {
      panel?.orderOut(nil)
      return
    }
    ensurePanel()
    panel?.ignoresMouseEvents = locked
    panel?.isMovableByWindowBackground = !locked
    lyricsView?.setLocked(locked)
    // 不激活主应用，也不在每次歌词变化时重新抢占窗口层级。
    if panel?.isVisible == false { panel?.orderFrontRegardless() }
  }

  private func placePanel(reset: Bool) {
    guard let panel, let mainScreen = NSScreen.main ?? NSScreen.screens.first else { return }
    var frame = panel.frame
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
    frame.size.width = min(720, bounds.width)
    frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
    frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
    panel.setFrame(frame, display: true)
  }

  @objc private func screensChanged() { placePanel(reset: false) }

  func windowDidMove(_ notification: Notification) {
    guard let origin = panel?.frame.origin else { return }
    defaults.set(["x": Double(origin.x), "y": Double(origin.y)], forKey: originKey)
  }

  deinit { NotificationCenter.default.removeObserver(self) }
}

private final class LyricsPanel: NSPanel {
  // 自动更新只 orderFront；用户主动定位窗口时允许键盘访问原生按钮。
  override var canBecomeKey: Bool { !ignoresMouseEvents }
  override var canBecomeMain: Bool { false }
}

private final class LyricsView: NSView {
  var onClose: (() -> Void)?
  var onLock: (() -> Void)?
  private let titleLabel = NSTextField(labelWithString: "忆光 · 桌面歌词")
  private let currentLabel = NSTextField(wrappingLabelWithString: "等待播放音乐…")
  private let nextLabel = NSTextField(labelWithString: "")
  private let lockButton = NSButton(title: "锁定", target: nil, action: nil)
  private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
  private var locked = false
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.backgroundColor = NSColor(srgbRed: 0.97, green: 0.99, blue: 0.96, alpha: 0.96).cgColor
    layer?.borderWidth = 1
    layer?.borderColor = NSColor(srgbRed: 0.70, green: 0.86, blue: 0.78, alpha: 1).cgColor
    let ink = NSColor(srgbRed: 0.15, green: 0.42, blue: 0.36, alpha: 1)
    titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
    titleLabel.textColor = ink.withAlphaComponent(0.8)
    titleLabel.lineBreakMode = .byTruncatingTail
    currentLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    currentLabel.textColor = ink
    currentLabel.alignment = .center
    currentLabel.maximumNumberOfLines = 1
    currentLabel.lineBreakMode = .byTruncatingTail
    nextLabel.font = .systemFont(ofSize: 13, weight: .medium)
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
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    titleLabel.frame = NSRect(x: 14, y: 6, width: max(0, bounds.width - 142), height: 16)
    lockButton.frame = NSRect(x: bounds.width - 122, y: 3, width: 52, height: 22)
    closeButton.frame = NSRect(x: bounds.width - 64, y: 3, width: 52, height: 22)
    currentLabel.frame = NSRect(x: 16, y: 29, width: bounds.width - 32, height: 24)
    nextLabel.frame = NSRect(x: 16, y: 57, width: bounds.width - 32, height: 19)
  }

  func update(title: String, current: String, next: String, playing: Bool, locked: Bool) {
    titleLabel.stringValue = "\(playing ? "正在播放" : "已暂停") · \(title)"
    currentLabel.stringValue = current
    nextLabel.stringValue = next
    setLocked(locked)
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
      layer?.backgroundColor = background.withAlphaComponent(0.96).cgColor
    }
    if let border = color("borderColor") { layer?.borderColor = border.cgColor }
    if let foreground = color("foregroundColor") { currentLabel.textColor = foreground }
    if let secondary = color("secondaryColor") {
      titleLabel.textColor = secondary
      nextLabel.textColor = secondary
    }
    if let dark = args["dark"] as? Bool {
      appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
  }

  func setLocked(_ value: Bool) {
    locked = value
    lockButton.isHidden = value
    closeButton.isHidden = value
  }

  override func mouseDown(with event: NSEvent) {
    if !locked { window?.performDrag(with: event) }
  }

  @objc private func lockLyrics() { onLock?() }
  @objc private func closeLyrics() { onClose?() }
}
