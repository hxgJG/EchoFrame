import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if let reply = LumioMacOSPlugins.subtitleWorkbench?.requestTermination(sender) { return reply }
    return super.applicationShouldTerminate(sender)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    // 桌面歌词可独立可见，不能据此认定主窗口也已经打开。
    mainFlutterWindow?.deminiaturize(nil)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
