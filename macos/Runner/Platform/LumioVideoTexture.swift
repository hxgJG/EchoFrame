import AVFoundation
import CoreVideo
import FlutterMacOS
import QuartzCore

final class LumioVideoTexture: NSObject, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private let lock = NSLock()
  private var videoOutput: AVPlayerItemVideoOutput?
  private var latestPixelBuffer: CVPixelBuffer?
  private var frameTimer: Timer?
  private(set) var textureID: Int64 = 0

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  func register() -> Int64 {
    textureID = registry.register(self)
    return textureID
  }

  func attach(to item: AVPlayerItem) {
    detach()
    if textureID == 0 {
      _ = register()
    }
    let output = AVPlayerItemVideoOutput(
      pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      ]
    )
    item.add(output)
    lock.lock()
    videoOutput = output
    lock.unlock()
    startFrameTimer()
    notifyFrameAvailable()
  }

  func detach() {
    stopFrameTimer()
    lock.lock()
    videoOutput = nil
    latestPixelBuffer = nil
    lock.unlock()
  }

  func dispose() {
    detach()
    guard textureID != 0 else { return }
    let id = textureID
    textureID = 0
    DispatchQueue.main.async { [registry] in
      registry.unregisterTexture(id)
    }
  }

  func notifyFrameAvailable() {
    guard textureID != 0 else { return }
    registry.textureFrameAvailable(textureID)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let output = videoOutput else { return nil }
    let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
    if output.hasNewPixelBuffer(forItemTime: itemTime),
       let buffer = output.copyPixelBuffer(
         forItemTime: itemTime,
         itemTimeForDisplay: nil
       ) {
      latestPixelBuffer = buffer
    }
    guard let latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(latestPixelBuffer)
  }

  func onTextureUnregistered(_ texture: FlutterTexture) {
    detach()
  }

  private func startFrameTimer() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.frameTimer?.invalidate()
      self.frameTimer = Timer.scheduledTimer(
        withTimeInterval: 1.0 / 60.0,
        repeats: true
      ) { [weak self] _ in
        self?.notifyFrameAvailable()
      }
      if let frameTimer = self.frameTimer {
        RunLoop.main.add(frameTimer, forMode: .common)
      }
    }
  }

  private func stopFrameTimer() {
    DispatchQueue.main.async { [weak self] in
      self?.frameTimer?.invalidate()
      self?.frameTimer = nil
    }
  }
}
