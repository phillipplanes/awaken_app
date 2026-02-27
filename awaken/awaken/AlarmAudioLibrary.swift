import Foundation
import AVFoundation
import CoreMedia
import Combine

struct AlarmAudioTrack: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    let displayName: String

    init(fileURL: URL) {
        self.id = fileURL.lastPathComponent
        self.fileURL = fileURL
        self.displayName = fileURL.deletingPathExtension().lastPathComponent
    }
}

@MainActor
final class AlarmAudioLibrary: ObservableObject {
    @Published private(set) var tracks: [AlarmAudioTrack] = []

    private let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "wav"]

    init() {
        do {
            try ensureLibraryDirectoryExists()
            refresh()
        } catch {
            print("AlarmAudioLibrary init error: \(error.localizedDescription)")
        }
    }

    func refresh() {
        do {
            try ensureLibraryDirectoryExists()
            let urls = try FileManager.default.contentsOfDirectory(
                at: libraryDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            tracks = urls
                .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
                .map(AlarmAudioTrack.init)
        } catch {
            print("AlarmAudioLibrary refresh error: \(error.localizedDescription)")
            tracks = []
        }
    }

    func importAudioFile(from sourceURL: URL) throws {
        try ensureLibraryDirectoryExists()

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw NSError(
                domain: "AlarmAudioLibrary",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported file type: \(ext)"]
            )
        }

        var destination = libraryDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = sourceURL.deletingPathExtension().lastPathComponent
            let unique = "\(base)-\(UUID().uuidString.prefix(8)).\(ext)"
            destination = libraryDirectoryURL.appendingPathComponent(unique)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destination)
        refresh()
    }

    func track(for id: String?) -> AlarmAudioTrack? {
        guard let id else { return nil }
        return tracks.first(where: { $0.id == id })
    }

    func pcmDataForDevice(from track: AlarmAudioTrack) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try await Self.decodeToDevicePCM8kMono16(url: track.fileURL)
        }.value
    }

    private func ensureLibraryDirectoryExists() throws {
        try FileManager.default.createDirectory(at: libraryDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    private var libraryDirectoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("AlarmAudio", isDirectory: true)
    }

    private nonisolated static func decodeToDevicePCM8kMono16(url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw NSError(
                domain: "AlarmAudioLibrary",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "No audio track found in \(url.lastPathComponent)"]
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(
                domain: "AlarmAudioLibrary",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode \(url.lastPathComponent)"]
            )
        }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "AlarmAudioLibrary",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start decoding \(url.lastPathComponent)"]
            )
        }

        var pcmData = Data()
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &dataPointer
                )
                if status == kCMBlockBufferNoErr, let dataPointer, length > 0 {
                    pcmData.append(
                        UnsafeBufferPointer(
                            start: UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self),
                            count: length
                        )
                    )
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "AlarmAudioLibrary",
                code: 23,
                userInfo: [NSLocalizedDescriptionKey: "Decoding failed for \(url.lastPathComponent)"]
            )
        }

        if pcmData.isEmpty {
            throw NSError(
                domain: "AlarmAudioLibrary",
                code: 24,
                userInfo: [NSLocalizedDescriptionKey: "Decoded audio was empty for \(url.lastPathComponent)"]
            )
        }

        return pcmData
    }
}
