import AVFoundation
import Foundation

final class AudioRecorder: @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()
    private let targetSampleRate: Double = 16000

    func startRecording() throws {
        lock.lock()
        samples = []
        lock.unlock()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatError
        }

        guard let conv = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioRecorderError.converterError
        }
        converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.convertAndAppend(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    func stopRecording() -> [Float] {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil

        lock.lock()
        let result = samples
        samples = []
        lock.unlock()
        return result
    }

    private func convertAndAppend(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetSampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let targetFormat = converter.outputFormat as AVAudioFormat?,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity)
        else { return }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil,
              let channelData = convertedBuffer.floatChannelData
        else { return }

        let count = Int(convertedBuffer.frameLength)
        let data = Array(UnsafeBufferPointer(start: channelData[0], count: count))

        lock.lock()
        samples.append(contentsOf: data)
        lock.unlock()
    }
}

enum AudioRecorderError: LocalizedError {
    case formatError
    case converterError

    var errorDescription: String? {
        switch self {
        case .formatError: "Failed to create target audio format"
        case .converterError: "Failed to create audio converter"
        }
    }
}
