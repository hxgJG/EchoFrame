import Cocoa
import FlutterMacOS

@MainActor
enum LumioMacOSPlugins {
  private static var retainedPlugins: [AnyObject] = []
  static var subtitleWorkbench: LumioSubtitleWorkbenchPlugin?

  static func register(with registry: FlutterPluginRegistry, window: NSWindow) {
    let registrar = registry.registrar(forPlugin: "LumioMacOSPlugins")
    let bookmarkStore = SecurityScopedBookmarkStore()
    let storage = LumioAppStoragePlugin(registrar: registrar)
    let mediaLibrary = LumioMediaLibraryPlugin(
      registrar: registrar,
      bookmarkStore: bookmarkStore,
      window: window
    )
    let playback = LumioPlaybackPlugin(
      registrar: registrar,
      bookmarkStore: bookmarkStore,
      window: window
    )
    let desktopLyrics = LumioDesktopLyricsPlugin(registrar: registrar)
    let workbench = LumioSubtitleWorkbenchPlugin(registrar: registrar, window: window, bookmarks: bookmarkStore)
    subtitleWorkbench = workbench
    retainedPlugins = [storage, mediaLibrary, playback, desktopLyrics, workbench]
  }
}
