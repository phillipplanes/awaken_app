import Foundation
import Combine
import AVFoundation
import os

@MainActor
final class VoiceMessageViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private let logger = Logger(subsystem: "com.phillipplanes.awaken", category: "voice")
    enum Status {
        case idle
        case generating
        case recording
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "No voice message generated yet."
            case .generating:
                return "Generating message..."
            case .recording:
                return "Recording..."
            case .ready:
                return "Voice message ready."
            case .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var scriptText = ""
    @Published private(set) var devicePCMData: Data?
    @Published private(set) var devicePCMSampleRate: Int = 24000
    @Published private(set) var isRecording = false
    @Published private(set) var recordingTimeRemaining: Int = 0

    private(set) var audioURL: URL?
    private var audioPlayer: AVAudioPlayer?
    private var audioRecorder: AVAudioRecorder?
    private var recordingTimer: Timer?
    private static let maxRecordingSeconds = 15

    func generate(alarmType: AlarmType, alarmTime: Date, weatherSummary: String, voice: String) async {
        status = .generating

        do {
            let key = try apiKey()
            logger.info("Using OpenAI key: \(self.maskSecret(key), privacy: .public)")
            let service = OpenAIService(apiKey: key)
            let script: String
            do {
                script = try await service.generateScript(
                    alarmType: alarmType,
                    alarmTime: alarmTime,
                    weatherSummary: weatherSummary
                )
            } catch {
                throw OpenAIServiceError.invalidResponse("Script generation failed: \(describe(error))")
            }

            let pcm24kData: Data
            do {
                pcm24kData = try await service.synthesizeSpeech(text: script, voice: voice, format: "pcm")
                logger.info("Received TTS PCM bytes: \(pcm24kData.count)")
            } catch {
                throw OpenAIServiceError.invalidResponse("Speech synthesis failed: \(describe(error))")
            }

            let deviceUploadPCMData: Data
            let deviceUploadRate: Int
            do {
                // Preview WAV uses original 24kHz (phone speaker handles any rate)
                let previewWav = makeWAVFileData(from: pcm24kData, sampleRate: 24000)
                audioURL = try writeAudioFile(data: previewWav, fileExtension: "wav")
                // Resample to 44100Hz — the native A2DP/I2S rate on the device.
                // This avoids I2S reconfiguration and is proven to work with MAX98357A.
                let resampled = resamplePCM(from: pcm24kData, inputRate: 24000, outputRate: 44100)
                deviceUploadPCMData = resampled
                deviceUploadRate = 44100
                logger.info("Resampled \(pcm24kData.count) bytes @ 24kHz → \(resampled.count) bytes @ 44100Hz for device")
                // Save a ≤30s version as the notification sound for lock-screen alarms
                let notifWav = makeNotificationSoundWAV(from: pcm24kData, sampleRate: 24000, maxSeconds: 30)
                AlarmNotificationManager.shared.saveCustomAlarmSound(wavData: notifWav)
            } catch {
                throw OpenAIServiceError.invalidResponse("Audio processing failed: \(describe(error))")
            }

            scriptText = script
            devicePCMData = deviceUploadPCMData
            devicePCMSampleRate = deviceUploadRate
            status = .ready
        } catch {
            logger.error("Voice generation failed: \(error.localizedDescription, privacy: .public)")
            let nsError = error as NSError
            logger.error("Voice generation NSError domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            audioURL = nil
            devicePCMData = nil
            devicePCMSampleRate = 24000
            status = .failed(error.localizedDescription)
        }
    }

    func playPreview() {
        guard let audioURL else { return }
        playAudioFile(url: audioURL, loops: false)
    }

    private var isPlayingAlarm = false
    private var alarmReplayWork: DispatchWorkItem?
    private static let alarmReplayDelay: TimeInterval = 6.0

    func playAlarmAudioIfAvailable() {
        guard let audioURL else {
            logger.warning("playAlarmAudioIfAvailable: no audioURL")
            return
        }
        // Guard against re-entry — only one alarm audio instance at a time
        guard !isPlayingAlarm else {
            logger.info("playAlarmAudioIfAvailable: already playing, skipping")
            return
        }
        logger.info("playAlarmAudioIfAvailable: starting alarm audio")
        isPlayingAlarm = true
        playAudioFile(url: audioURL, loops: false)
    }

    func playTestTone(frequencyHz: Double, durationSeconds: Double = 0.3) {
        let safeFrequency = min(max(frequencyHz, 120), 4000)
        let safeDuration = min(max(durationSeconds, 0.1), 2.0)
        let wavData = makeSineWaveWAV(frequencyHz: safeFrequency, durationSeconds: safeDuration, sampleRate: 24000)

        do {
            audioPlayer = try AVAudioPlayer(data: wavData)
            audioPlayer?.numberOfLoops = 0
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            status = .failed("Could not play test tone.")
        }
    }

    func stopAlarmAudio() {
        logger.info("stopAlarmAudio called")
        alarmReplayWork?.cancel()
        alarmReplayWork = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingAlarm = false
    }

    // MARK: - Microphone Recording

    func startRecording() {
        stopAlarmAudio()
        audioPlayer = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            status = .failed("Microphone access failed: \(error.localizedDescription)")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("awaken-recording-\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder.prepareToRecord()
            recorder.record(forDuration: TimeInterval(Self.maxRecordingSeconds))
            audioRecorder = recorder
            isRecording = true
            status = .recording
            scriptText = ""
            recordingTimeRemaining = Self.maxRecordingSeconds

            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else {
                        self?.recordingTimer?.invalidate()
                        self?.recordingTimer = nil
                        return
                    }
                    self.recordingTimeRemaining -= 1
                    if self.recordingTimeRemaining <= 0 {
                        self.stopRecording()
                    }
                }
            }
        } catch {
            status = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard let recorder = audioRecorder, isRecording else { return }
        recorder.stop()
        isRecording = false
        let recordedURL = recorder.url
        audioRecorder = nil

        // Restore audio session for playback
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.allowBluetoothA2DP, .mixWithOthers])
        try? session.setActive(true)

        processRecordedFile(url: recordedURL)
    }

    private func processRecordedFile(url: URL) {
        do {
            let wavData = try Data(contentsOf: url)
            // WAV header is 44 bytes; extract raw PCM after it
            guard wavData.count > 44 else {
                status = .failed("Recording too short.")
                return
            }
            let pcmData = wavData.subdata(in: 44..<wavData.count)
            logger.info("Recorded PCM: \(pcmData.count) bytes @ 44100Hz")

            // Preview file is the recorded WAV itself
            audioURL = url
            // Device upload: already at 44100Hz mono 16-bit — no resampling needed
            devicePCMData = pcmData
            devicePCMSampleRate = 44100
            scriptText = "Recorded \(String(format: "%.1f", Double(pcmData.count) / (2.0 * 44100.0)))s voice message"

            // Save notification sound (trimmed to 30s)
            let notifWav = makeNotificationSoundWAV(from: pcmData, sampleRate: 44100, maxSeconds: 30)
            AlarmNotificationManager.shared.saveCustomAlarmSound(wavData: notifWav)

            status = .ready
        } catch {
            status = .failed("Failed to process recording: \(error.localizedDescription)")
        }
    }

    private func playAudioFile(url: URL, loops: Bool) {
        // Stop any existing player to prevent overlapping audio instances
        audioPlayer?.stop()
        audioPlayer = nil
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = loops ? -1 : 0
            player.delegate = self
            player.prepareToPlay()
            player.play()
            audioPlayer = player
        } catch {
            status = .failed("Could not play generated audio.")
        }
    }

    // Called when playback finishes — replays alarm audio after a 6s pause
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logger.info("audioPlayerDidFinishPlaying: flag=\(flag), isPlayingAlarm=\(self.isPlayingAlarm)")
            guard self.isPlayingAlarm, let url = self.audioURL else { return }
            self.logger.info("Scheduling alarm replay in \(Self.alarmReplayDelay)s")
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isPlayingAlarm, let url = self.audioURL else { return }
                self.logger.info("Replaying alarm audio")
                self.playAudioFile(url: url, loops: false)
            }
            self.alarmReplayWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.alarmReplayDelay, execute: work)
        }
    }

    private func apiKey() throws -> String {
        let infoCandidates: [String?] = [
            Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String,
            Bundle.main.object(forInfoDictionaryKey: "openai_api_key") as? String,
            Bundle.main.object(forInfoDictionaryKey: "OpenAI_API_KEY") as? String,
            Bundle.main.object(forInfoDictionaryKey: "INFOPLIST_KEY_OPENAI_API_KEY") as? String
        ]
        let envCandidates: [String?] = [
            ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            ProcessInfo.processInfo.environment["openai_api_key"]
        ]
        let defaultsCandidates: [String?] = [
            UserDefaults.standard.string(forKey: "OPENAI_API_KEY"),
            UserDefaults.standard.string(forKey: "openai_api_key")
        ]
        let candidates = infoCandidates + envCandidates + defaultsCandidates
        logger.info("OpenAI key candidates - info:\(infoCandidates.count) env:\(envCandidates.count) defaults:\(defaultsCandidates.count)")
        if let info = Bundle.main.infoDictionary {
            let openAIKeys = info.keys.filter { $0.lowercased().contains("openai") }.sorted().joined(separator: ", ")
            logger.info("Info.plist OpenAI-related keys present: \(openAIKeys, privacy: .public)")
        }

        for candidate in candidates {
            guard let value = candidate else { continue }
            let normalized = normalizeKey(value)
            if !normalized.isEmpty && !normalized.contains("$(") {
                logger.info("Resolved non-empty OpenAI key candidate: \(self.maskSecret(normalized), privacy: .public)")
                return normalized
            }
        }

        let resolvedInfoValue = (Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String) ?? "<nil>"
        let maskedResolved = maskSecret(resolvedInfoValue)
        throw OpenAIServiceError.invalidResponse("Missing OPENAI_API_KEY. Resolved Info value: \(maskedResolved). Set target Build Settings > OPENAI_API_KEY for the active run configuration, then delete app from simulator/device and rerun.")
    }

    private func maskSecret(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "<nil>" else { return trimmed }
        if trimmed.count <= 10 { return String(repeating: "*", count: trimmed.count) }
        let prefix = trimmed.prefix(6)
        let suffix = trimmed.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    private func normalizeKey(_ rawValue: String) -> String {
        var result = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.hasPrefix("Bearer ") || result.hasPrefix("bearer ") {
            result = String(result.dropFirst(7))
        }

        if result.hasPrefix("\""), result.hasSuffix("\""), result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = result.range(of: "sk-") {
            let suffix = result[range.lowerBound...]
            let token = suffix.prefix { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
            return String(token)
        }

        return result
    }

    private func writeAudioFile(data: Data, fileExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alarm-voice-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makeSineWaveWAV(frequencyHz: Double, durationSeconds: Double, sampleRate: Int) -> Data {
        let frameCount = max(1, Int(Double(sampleRate) * durationSeconds))
        var pcm = Data(capacity: frameCount * 2)
        let amplitude = 0.28

        for n in 0..<frameCount {
            let t = Double(n) / Double(sampleRate)
            let sample = sin(2.0 * .pi * frequencyHz * t)
            let intSample = Int16(max(-1.0, min(1.0, sample * amplitude)) * Double(Int16.max))
            var le = intSample.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }

        return makeWAVFileData(from: pcm, sampleRate: sampleRate)
    }

    /// Resample 16-bit mono PCM to a different sample rate.
    /// Uses integer duplication when outputRate is an exact multiple of inputRate,
    /// otherwise falls back to linear interpolation.
    private func resamplePCM(from data: Data, inputRate: Int, outputRate: Int) -> Data {
        guard inputRate != outputRate else { return data }
        let inputCount = data.count / 2

        // Exact integer multiple — duplicate each sample N times (zero-computation path)
        if outputRate % inputRate == 0 {
            let factor = outputRate / inputRate
            var output = Data(capacity: inputCount * factor * 2)
            data.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<samples.count {
                    var s = samples[i]
                    for _ in 0..<factor {
                        withUnsafeBytes(of: &s) { output.append(contentsOf: $0) }
                    }
                }
            }
            return output
        }

        // General case — linear interpolation
        let ratio = Double(inputRate) / Double(outputRate)
        let outputCount = Int(Double(inputCount) / ratio)
        var output = Data(capacity: outputCount * 2)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<outputCount {
                let srcPos = Double(i) * ratio
                let idx = Int(srcPos)
                let frac = srcPos - Double(idx)
                let s0 = samples[min(idx, samples.count - 1)]
                let s1 = samples[min(idx + 1, samples.count - 1)]
                var sample = Int16(Double(s0) + frac * (Double(s1) - Double(s0)))
                withUnsafeBytes(of: &sample) { output.append(contentsOf: $0) }
            }
        }
        return output
    }

    private func makeNotificationSoundWAV(from pcmData: Data, sampleRate: Int, maxSeconds: Int) -> Data {
        let bytesPerSample = 2
        let maxBytes = sampleRate * bytesPerSample * maxSeconds
        let trimmed = pcmData.count > maxBytes ? pcmData.prefix(maxBytes) : pcmData
        return makeWAVFileData(from: Data(trimmed), sampleRate: sampleRate)
    }

    private func makeWAVFileData(from pcmData: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let subchunk2Size: UInt32 = UInt32(pcmData.count)
        let chunkSize: UInt32 = 36 + subchunk2Size

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(littleEndianBytes(chunkSize))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(littleEndianBytes(UInt32(16)))
        wav.append(littleEndianBytes(UInt16(1)))
        wav.append(littleEndianBytes(channels))
        wav.append(littleEndianBytes(UInt32(sampleRate)))
        wav.append(littleEndianBytes(byteRate))
        wav.append(littleEndianBytes(blockAlign))
        wav.append(littleEndianBytes(bitsPerSample))
        wav.append("data".data(using: .ascii)!)
        wav.append(littleEndianBytes(subchunk2Size))
        wav.append(pcmData)
        return wav
    }

    private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }
}
