import Foundation
import Combine
import AVFoundation
import os

@MainActor
final class VoiceMessageViewModel: ObservableObject {
    private let logger = Logger(subsystem: "com.phillipplanes.awaken", category: "voice")
    enum Status {
        case idle
        case generating
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "No voice message generated yet."
            case .generating:
                return "Generating message..."
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

    private var audioURL: URL?
    private var audioPlayer: AVAudioPlayer?

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
            do {
                let previewWav = makeWAVFileData(from: pcm24kData, sampleRate: 24000)
                audioURL = try writeAudioFile(data: previewWav, fileExtension: "wav")
                deviceUploadPCMData = pcm24kData
            } catch {
                throw OpenAIServiceError.invalidResponse("Audio processing failed: \(describe(error))")
            }

            scriptText = script
            devicePCMData = deviceUploadPCMData
            devicePCMSampleRate = 24000
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

    func playAlarmAudioIfAvailable() {
        guard let audioURL else { return }
        playAudioFile(url: audioURL, loops: true)
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
        audioPlayer?.stop()
    }

    private func playAudioFile(url: URL, loops: Bool) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = loops ? -1 : 0
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            status = .failed("Could not play generated audio.")
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
