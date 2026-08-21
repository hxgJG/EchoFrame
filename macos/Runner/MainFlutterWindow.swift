import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 900, height: 600)
    if self.frame.width < 1180 || self.frame.height < 760 {
      self.setContentSize(NSSize(width: 1180, height: 760))
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)
    LumioMacOSPlugins.register(with: flutterViewController, window: self)

    super.awakeFromNib()
    self.title = "忆光"
  }
}
