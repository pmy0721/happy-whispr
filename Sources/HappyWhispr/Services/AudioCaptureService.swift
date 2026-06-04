import AVFoundation
import Combine
import Foundation

final class AudioCaptureService: ObservableObject {

    // MARK: - Published State

    @Published var rmsPower: Float = 0.0
    @Published var isRecording: Bool = false
    var onMaxDurationExceeded: (() -> Void)?

    // MARK: - Private

    private let audioEngine = AVAudioEngine()
    private var pcmBuffer = Data()
    private var rmsTimer: Timer?
    private var maxLengthTimer: Timer?
    private var latestRms: Float = 0.0
    private let maxRecordingDuration: TimeInterval = 30.0

    // Audio format constants
    private let sampleRate: Double = 16000.0
    private let channels: UInt32 = 1
    private let bitsPerSample: UInt16 = 16

    // MARK: - WAV Buffer (public for STTService)

    private(set) var wavBuffer = Data()

    // MARK: - Public API

    func startCapture() {
        guard !isRecording else { return }
        guard checkPermissionInternal() else { return }

        pcmBuffer = Data()
        wavBuffer = Data()
        rmsPower = 0.0
        latestRms = 0.0

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Desired format: 16kHz, mono, 16-bit PCM
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            print("[AudioCaptureService] Failed to create recording format")
            return
        }

        // Install converter if needed
        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            print("[AudioCaptureService] Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, outputFormat: recordingFormat)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            print("[AudioCaptureService] Failed to start audio engine: \(error)")
            return
        }

        // RMS timer — publish every 50ms
        rmsTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.rmsPower = self.latestRms
        }

        // Max recording length timer
        maxLengthTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            self.stopCapture()
            self.onMaxDurationExceeded?()
        }
    }

    func stopCapture() {
        guard isRecording else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        rmsTimer?.invalidate()
        rmsTimer = nil
        maxLengthTimer?.invalidate()
        maxLengthTimer = nil
        isRecording = false

        // Encode accumulated PCM to WAV in memory
        wavBuffer = encodeToWAV(pcmData: pcmBuffer)
    }

    // MARK: - Permission

    static func checkPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // Synchronous request not recommended; checkPermissionInternal handles this
            return false
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func requestPermission() async -> Bool {
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    private func checkPermissionInternal() -> Bool {
        return Self.checkPermission()
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        // Calculate required output capacity
        let inputFrames = buffer.frameLength
        let outputCapacity = AVAudioFrameCount(
            Double(inputFrames) * outputFormat.sampleRate / buffer.format.sampleRate
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { return }

        outputBuffer.frameLength = outputCapacity

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("[AudioCaptureService] Conversion error: \(error)")
            return
        }

        // Append PCM data
        if let channelData = outputBuffer.int16ChannelData {
            let data = Data(
                bytes: channelData.pointee,
                count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
            )
            pcmBuffer.append(data)
        }

        // Calculate RMS
        if let channelData = outputBuffer.int16ChannelData {
            let frames = Int(outputBuffer.frameLength)
            let samples = channelData.pointee
            var sum: Float = 0.0
            for i in 0..<frames {
                let sample = Float(samples[i]) / Float(Int16.max)
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(max(frames, 1)))
            latestRms = rms
        }
    }

    // MARK: - WAV Encoding

    private func encodeToWAV(pcmData: Data) -> Data {
        var wav = Data()

        let sampleRate32: UInt32 = UInt32(sampleRate)
        let byteRate: UInt32 = sampleRate32 * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = UInt16(channels) * (bitsPerSample / 8)
        let dataSize: UInt32 = UInt32(pcmData.count)
        let fileSize: UInt32 = 36 + dataSize

        // RIFF header
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        wav.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // subchunk size
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM format
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) }) // channels
        wav.append(contentsOf: withUnsafeBytes(of: sampleRate32.littleEndian) { Array($0) }) // sample rate
        wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })     // byte rate
        wav.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })   // block align
        wav.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) }) // bits per sample

        // data subchunk
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        wav.append(pcmData)

        return wav
    }
}
