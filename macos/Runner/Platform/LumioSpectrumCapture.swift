import AVFoundation
import MediaToolbox
import QuartzCore

final class LumioSpectrumCapture {
  private let lock = NSLock()
  private var active = false
  var enabled: Bool {
    get { lock.lock(); defer { lock.unlock() }; return active }
    set { lock.lock(); active = newValue; if !newValue { count = 0 }; lock.unlock() }
  }
  private let ring = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
  private var count = 0
  private var sampleRate = 44100.0
  private var format = AudioStreamBasicDescription()
  private var lastAt = 0.0
  private static let window = (0..<1024).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 1023) }

  init() { ring.initialize(repeating: 0, count: 4096) }
  deinit { ring.deinitialize(count: 4096); ring.deallocate() }

  func clear() { lock.lock(); count = 0; lastAt = 0; lock.unlock() }

  func makeTap() -> MTAudioProcessingTap? {
    let retained = Unmanaged.passRetained(self).toOpaque()
    var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: retained,
      init: { _, info, storage in storage.pointee = info },
      finalize: { tap in
        Unmanaged<LumioSpectrumCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
      },
      prepare: { tap, _, format in
        Unmanaged<LumioSpectrumCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
          .takeUnretainedValue().prepare(format.pointee)
      },
      unprepare: nil,
      process: { tap, frames, _, buffers, framesOut, flagsOut in
        let status = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut)
        guard status == noErr else { framesOut.pointee = 0; return }
        Unmanaged<LumioSpectrumCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
          .takeUnretainedValue().append(buffers, frames: framesOut.pointee,
            discontinuity: flagsOut.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0)
      })
    var tap: MTAudioProcessingTap?
    guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
      kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr, let tap else {
      Unmanaged<LumioSpectrumCapture>.fromOpaque(retained).release()
      return nil
    }
    return tap
  }

  func prepare(_ value: AudioStreamBasicDescription) {
    lock.lock(); format = value; sampleRate = value.mSampleRate; count = 0; lock.unlock()
  }

  func append(_ pointer: UnsafeMutablePointer<AudioBufferList>, frames: Int, discontinuity: Bool) {
    guard lock.try() else { return }
    defer { lock.unlock() }
    guard active, frames > 0, format.mFormatID == kAudioFormatLinearPCM else { return }
    let buffer = pointer.pointee.mBuffers
    guard let data = buffer.mData else { return }
    let stride = max(1, Int(buffer.mNumberChannels))
    let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
    let integer = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && format.mBitsPerChannel == 16
    guard floating || integer else { return }
    let capacity = Int(buffer.mDataByteSize) / (floating ? 4 : 2) / stride
    let total = min(frames, capacity)
    if discontinuity { count = 0 }
    for i in max(0, total - 4096)..<total {
      let sample = floating ? data.assumingMemoryBound(to: Float.self)[i * stride]
        : Float(data.assumingMemoryBound(to: Int16.self)[i * stride]) / 32768
      ring[count % 4096] = sample.isFinite ? sample : 0
      count += 1
    }
    lastAt = CACurrentMediaTime()
  }

  func analyze() -> [Double] {
    var real = [Double](repeating: 0, count: 1024)
    lock.lock()
    guard active, sampleRate > 0, count >= 1024, CACurrentMediaTime() - lastAt < 0.25 else {
      lock.unlock(); return [Double](repeating: 0, count: 24)
    }
    for i in 0..<1024 { real[i] = Double(ring[(count - 1024 + i) % 4096]) * Self.window[i] }
    let rate = sampleRate
    lock.unlock()
    var imaginary = [Double](repeating: 0, count: 1024)
    var j = 0
    for i in 1..<1024 {
      var bit = 512
      while j & bit != 0 { j ^= bit; bit >>= 1 }
      j ^= bit
      if i < j { real.swapAt(i, j) }
    }
    var length = 2
    while length <= 1024 {
      let angle = -2 * Double.pi / Double(length)
      let wr = cos(angle), wi = sin(angle)
      for start in stride(from: 0, to: 1024, by: length) {
        var ar = 1.0, ai = 0.0
        for k in 0..<(length / 2) {
          let a = start + k, b = a + length / 2
          let br = real[b] * ar - imaginary[b] * ai
          let bi = real[b] * ai + imaginary[b] * ar
          real[b] = real[a] - br; imaginary[b] = imaginary[a] - bi
          real[a] += br; imaginary[a] += bi
          let next = ar * wr - ai * wi
          ai = ar * wi + ai * wr; ar = next
        }
      }
      length *= 2
    }
    let high = min(16000, rate * 0.48)
    return (0..<24).map { band in
      let lowBin = max(1, Int(60 * pow(high / 60, Double(band) / 24) * 1024 / rate))
      let highBin = min(511, max(lowBin, Int(60 * pow(high / 60, Double(band + 1) / 24) * 1024 / rate)))
      var power = 0.0
      for bin in lowBin...highBin { power = max(power, real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) }
      let magnitude = sqrt(power) * 4 / 1024
      // Fixed full-scale PCM reference; do not amplify quiet tracks or normalize per song.
      return min(1, max(0, magnitude))
    }
  }
}
