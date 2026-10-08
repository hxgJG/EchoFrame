import AVFoundation
import QuartzCore

@main
struct SpectrumCaptureCheck {
  @MainActor
  static func main() async throws {
    checkPCM()
    try await checkPlayerTap()
  }

  static func checkPCM() {
    let capture = LumioSpectrumCapture()
    capture.prepare(AudioStreamBasicDescription(mSampleRate: 48000,
      mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
      mBitsPerChannel: 32, mReserved: 0))
    capture.enabled = true
    func feed(_ frequency: Double, _ amplitude: Double) -> [Double] {
      var samples = (0..<1024).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / 48000)) }
      return samples.withUnsafeMutableBytes { bytes in
        var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
          mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        capture.append(&buffer, frames: 1024, discontinuity: true)
        return capture.analyze()
      }
    }
    precondition(feed(0, 0).allSatisfy { $0 == 0 })
    let alignedFrequency = 48000.0 * 10 / 1024
    for amplitude in [0.0, 0.005, 0.25, 0.5, 1.0] {
      let peak = feed(alignedFrequency, amplitude).max()!
      precondition(abs(peak - amplitude) < 0.002)
    }
    precondition(feed(alignedFrequency, 2).max()! == 1)
    print("Fixed linear full-scale amplitude checks passed")
    let low = feed(250, 0.5), high = feed(8000, 0.5), quiet = feed(250, 0.005)
    precondition(low.indices.max(by: { low[$0] < low[$1] })! < high.indices.max(by: { high[$0] < high[$1] })!)
    precondition(low.max()! > quiet.max()! + 0.3)
    precondition(low.allSatisfy { $0.isFinite && (0...1).contains($0) })
    let start = CACurrentMediaTime()
    for _ in 0..<200 { _ = feed(1000, 0.5) }
    print("Mac PCM frequency/silence/amplitude checks passed; mean capture + FFT: \((CACurrentMediaTime() - start) * 1000 / 200) ms")
    Thread.sleep(forTimeInterval: 0.28)
    precondition(capture.analyze().allSatisfy { $0 == 0 })
    capture.enabled = false
    precondition(feed(1000, 0.5).allSatisfy { $0 == 0 })
    print("Stale and disabled capture checks passed")
  }

  @MainActor
  static func checkPlayerTap() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let url = root.appendingPathComponent("spectrum-test.caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 288000)!
    buffer.frameLength = buffer.frameCapacity
    for i in 0..<Int(buffer.frameLength) {
      let frequency = i < 144000 ? 250.0 : 8000.0
      buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * Double.pi * frequency * Double(i) / 48000))
    }
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      try file.write(from: buffer)
    }
    let item = AVPlayerItem(url: url)
    let track = try await item.asset.loadTracks(withMediaType: .audio).first!
    let capture = LumioSpectrumCapture()
    capture.enabled = true
    let input = AVMutableAudioMixInputParameters(track: track)
    input.audioTapProcessor = capture.makeTap()!
    let mix = AVMutableAudioMix()
    mix.inputParameters = [input]
    item.audioMix = mix
    let player = AVPlayer(playerItem: item)
    player.volume = 0
    player.play()
    func peak() async throws -> Int {
      for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 50_000_000)
        let bands = capture.analyze()
        if bands.max()! > 0.2 { return bands.indices.max(by: { bands[$0] < bands[$1] })! }
      }
      throw NSError(domain: "SpectrumCaptureCheck", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "AVPlayer tap unavailable; status=\(item.status.rawValue), time=\(player.currentTime().seconds), error=\(String(describing: item.error))"])
    }
    let low = try await peak()
    capture.clear()
    await withCheckedContinuation { continuation in
      player.seek(to: CMTime(seconds: 3.5, preferredTimescale: 48000),
        toleranceBefore: .zero, toleranceAfter: .zero) { _ in continuation.resume() }
    }
    let high = try await peak()
    precondition(low < high)
    player.pause()
    capture.enabled = false
    precondition(capture.analyze().allSatisfy { $0 == 0 })
    print("Real AVPlayer tap and seek checks passed: peak bands \(low) -> \(high)")
  }
}
