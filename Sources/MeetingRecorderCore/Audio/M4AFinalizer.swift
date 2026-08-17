@preconcurrency import AVFoundation
import Darwin
import Foundation

public struct M4AFinalizer: Sendable {
    public init() {}

    public func recover(
        workingURL: URL,
        recoveredURL: URL
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: workingURL.path) else {
            throw failure("The working recording does not exist.")
        }
        guard !FileManager.default.fileExists(atPath: recoveredURL.path) else {
            throw failure("The destination recording already exists and was not replaced.")
        }
        guard workingURL.standardizedFileURL != recoveredURL.standardizedFileURL else {
            throw failure("The working and destination recording paths must be different.")
        }

        let temporaryURL = recoveredURL.deletingLastPathComponent()
            .appendingPathComponent(".\(recoveredURL.lastPathComponent).\(UUID().uuidString).tmp.m4a")
        defer { _ = temporaryURL.path.withCString { unlink($0) } }

        let asset = AVURLAsset(url: workingURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw failure("The working recording cannot be exported as M4A.")
        }
        do {
            try await exporter.export(to: temporaryURL, as: .m4a)
        } catch {
            throw failure("Could not export the working recording: \(error.localizedDescription)")
        }
        try await validateM4A(at: temporaryURL)

        let publishResult = temporaryURL.path.withCString { temporaryPath in
            recoveredURL.path.withCString { recoveredPath in
                link(temporaryPath, recoveredPath)
            }
        }
        guard publishResult == 0 else {
            let reason = String(cString: strerror(errno))
            throw failure("Could not publish the recovered recording without overwriting: \(reason)")
        }

        guard workingURL.path.withCString({ unlink($0) }) == 0 else {
            let reason = String(cString: strerror(errno))
            throw failure("Recovered audio was published, but the working file could not be removed: \(reason)")
        }
        return recoveredURL
    }

    func merge(
        segmentURLs: [URL],
        outputURL: URL
    ) async throws -> URL {
        guard !segmentURLs.isEmpty else {
            throw failure("There are no completed audio segments to merge.")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw failure("The destination recording already exists and was not replaced.")
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw failure("Could not create the merged audio track.")
        }
        var insertionTime = CMTime.zero
        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1 else {
                throw failure("A completed segment did not contain exactly one audio track.")
            }
            let duration = try await asset.load(.duration)
            do {
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: tracks[0],
                    at: insertionTime
                )
            } catch {
                throw failure("Could not add an audio segment: \(error.localizedDescription)")
            }
            insertionTime = insertionTime + duration
        }

        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.m4a")
        defer { _ = temporaryURL.path.withCString { unlink($0) } }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw failure("The completed audio segments cannot be exported as M4A.")
        }
        do {
            try await exporter.export(to: temporaryURL, as: .m4a)
        } catch {
            throw failure("Could not merge completed audio segments: \(error.localizedDescription)")
        }
        try await validateM4A(at: temporaryURL)

        let publishResult = temporaryURL.path.withCString { temporaryPath in
            outputURL.path.withCString { outputPath in
                link(temporaryPath, outputPath)
            }
        }
        guard publishResult == 0 else {
            let reason = String(cString: strerror(errno))
            throw failure("Could not publish merged audio without overwriting: \(reason)")
        }
        return outputURL
    }

    private func validateM4A(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let playable: Bool
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            playable = try await asset.load(.isPlayable)
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw failure("Could not read the exported M4A: \(error.localizedDescription)")
        }
        guard duration.isValid, duration.isNumeric, CMTimeGetSeconds(duration) > 0 else {
            throw failure("The exported M4A did not have a valid positive duration.")
        }
        guard playable, tracks.count == 1 else {
            throw failure("The exported M4A was not playable with exactly one audio track.")
        }
        let descriptions: [CMFormatDescription]
        do {
            descriptions = try await tracks[0].load(.formatDescriptions)
        } catch {
            throw failure("Could not inspect the exported audio format: \(error.localizedDescription)")
        }
        guard descriptions.contains(where: {
            CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC
        }) else {
            throw failure("The exported audio track was not AAC.")
        }
    }

    private func failure(_ message: String) -> RecordingFailure {
        RecordingFailure(code: .finalize, message: message)
    }
}
