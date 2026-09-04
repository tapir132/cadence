import FluidAudio
import Foundation

/// macOS purges purgeable caches, including Core ML's compiled-model cache,
/// when free space runs low. Cadence then recompiles the encoders for 20-60 s
/// at every launch, which looks like a download or an update problem.
enum SystemStorage {
    static let comfortableFreeBytes: Int64 = 20_000_000_000

    static func availableBytes() -> Int64? {
        try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    static func lowSpaceWarning(availableBytes: Int64?) -> String? {
        guard let availableBytes, availableBytes < comfortableFreeBytes else { return nil }
        let free = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        return "Only \(free) free on this disk. macOS purges the compiled speech-model cache when space runs low, so every launch recompiles for 20-60 seconds until you free about 20 GB."
    }
}

struct SpeechModelArtifact: Equatable, Sendable {
    let relativePath: String
    let isCompiledModel: Bool
}

/// Keeps every model Cadence can select outside the application bundle. Sparkle
/// replaces `Cadence.app` during an update, while Application Support remains
/// in place, so a complete model set is downloaded only once per user account.
struct SpeechModelStore: Sendable {
    let applicationSupportDirectory: URL

    init(applicationSupportDirectory: URL? = nil) {
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
    }

    var baseDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("FluidAudio", isDirectory: true)
    }

    var modelsDirectory: URL {
        baseDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    var requiredArtifacts: [SpeechModelArtifact] {
        let parakeetDirectory = Repo.parakeetUnified.folderName
        let vadDirectory = Repo.vad.folderName
        let sharedParakeetFiles = ModelNames.ParakeetUnified.requiredModels(variant: nil)
        let encoderFiles = RecognitionProfile.allCases.map {
            ModelNames.ParakeetUnified.streamingEncoderFile(
                precision: .int8,
                contextSuffix: $0.unifiedConfig.contextSuffix
            )
        }
        let parakeet = sharedParakeetFiles.union(encoderFiles).map {
            SpeechModelArtifact(
                relativePath: "\(parakeetDirectory)/\($0)",
                isCompiledModel: $0.hasSuffix(".mlmodelc")
            )
        }
        let vad = ModelNames.VAD.requiredModels.map {
            SpeechModelArtifact(
                relativePath: "\(vadDirectory)/\($0)",
                isCompiledModel: $0.hasSuffix(".mlmodelc")
            )
        }
        return (parakeet + vad).sorted { $0.relativePath < $1.relativePath }
    }

    func allRequiredModelsAreInstalled(fileManager: FileManager = .default) -> Bool {
        requiredArtifacts.allSatisfy { artifact in
            let url = modelsDirectory.appendingPathComponent(artifact.relativePath)
            if artifact.isCompiledModel {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      fileManager.fileExists(
                          atPath: url.appendingPathComponent("coremldata.bin").path
                      ) else { return false }
                return !containsPartialDownload(at: url, fileManager: fileManager)
            }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    /// Downloads both latency encoders and the VAD into the shared persistent
    /// directory. Existing complete artifacts are checked locally and never
    /// sent through the network downloader again.
    func installAll(
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        let parakeetArtifacts = requiredArtifacts.filter {
            $0.relativePath.hasPrefix("\(Repo.parakeetUnified.folderName)/")
        }
        let vadArtifacts = requiredArtifacts.filter {
            $0.relativePath.hasPrefix("\(Repo.vad.folderName)/")
        }
        let needsParakeet = !artifactsAreInstalled(parakeetArtifacts)
        let needsVad = !artifactsAreInstalled(vadArtifacts)
        guard needsParakeet || needsVad else { return }

        let parakeetWeight = needsParakeet && needsVad ? 0.995 : (needsParakeet ? 1 : 0)
        let vadWeight = needsParakeet && needsVad ? 0.005 : (needsVad ? 1 : 0)
        var completedWeight = 0.0

        if needsParakeet {
            let progressBase = completedWeight
            let encoders = Set(RecognitionProfile.allCases.map {
                ModelNames.ParakeetUnified.streamingEncoderFile(
                    precision: .int8,
                    contextSuffix: $0.unifiedConfig.contextSuffix
                )
            })
            try await ModelHub.download(
                .parakeetUnified,
                to: modelsDirectory,
                additionalModelNames: encoders
            ) { progress in
                onProgress(Self.aggregate(progress, base: progressBase, weight: parakeetWeight))
            }
            completedWeight += parakeetWeight
            onProgress(completedWeight)
        }

        if needsVad {
            let progressBase = completedWeight
            try await ModelHub.download(.vad, to: modelsDirectory) { progress in
                onProgress(Self.aggregate(progress, base: progressBase, weight: vadWeight))
            }
            completedWeight += vadWeight
            onProgress(completedWeight)
        }

        guard allRequiredModelsAreInstalled() else {
            throw SpeechEngineError.modelUnavailable(
                "The downloaded Fast, Accurate, or voice-activity model is incomplete."
            )
        }
    }

    private func artifactsAreInstalled(
        _ artifacts: [SpeechModelArtifact],
        fileManager: FileManager = .default
    ) -> Bool {
        artifacts.allSatisfy { artifact in
            let url = modelsDirectory.appendingPathComponent(artifact.relativePath)
            if artifact.isCompiledModel {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      fileManager.fileExists(
                          atPath: url.appendingPathComponent("coremldata.bin").path
                      ) else { return false }
                return !containsPartialDownload(at: url, fileManager: fileManager)
            }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    private func containsPartialDownload(at url: URL, fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let fileURL as URL in enumerator
        where fileURL.lastPathComponent.hasSuffix(".partial") {
            return true
        }
        return false
    }

    private static func aggregate(
        _ progress: DownloadProgress,
        base: Double,
        weight: Double
    ) -> Double? {
        switch progress.phase {
        case .listing:
            return base == 0 ? nil : base
        case .downloading:
            // Repository downloads reserve the upper half of FluidAudio's
            // progress range for model compilation, which this install-only
            // call does not perform.
            let downloadFraction = min(max(progress.fractionCompleted * 2, 0), 1)
            return min(base + downloadFraction * weight, 1)
        case .compiling:
            return min(base + weight, 1)
        }
    }
}
