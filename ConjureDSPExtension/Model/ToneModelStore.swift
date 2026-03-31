//
//  ToneModelStore.swift
//  ConjureDSPExtension
//
//  Manages downloaded NAM (.nam) tone model files in the App Group container.
//  Downloads from tone3000 presigned URLs via URLSession; no companion app needed.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "ToneStore")

@Observable
@MainActor
final class ToneModelStore {
    private static let appGroupID = "group.com.MichaelJancsy.ConjureDSP"
    private static let tonesDir = "tones"

    // MARK: - Observable State

    private(set) var downloadedModels: [DownloadedModel] = []
    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0
    private(set) var lastError: String?

    // MARK: - Models

    struct DownloadedModel: Identifiable, Hashable {
        var id: String { "\(toneId)/\(modelId)" }
        let toneId: String
        let modelId: String
        let toneName: String
        let modelName: String
        let modelSize: String    // e.g. "standard", "lite"
        let gear: String
        let author: String
        let downloadDate: Date
        let fileSize: Int64

        /// Path suitable for use in `load_model("tone3000://toneId/modelId")`
        var tone3000Path: String { "tone3000://\(toneId)/\(modelId)" }
    }

    struct ToneMetadata: Codable {
        let toneId: String
        let toneName: String
        let gear: String
        let author: String
        let models: [ModelMetadata]
    }

    struct ModelMetadata: Codable {
        let modelId: String
        let modelName: String
        let modelSize: String
        let downloadDate: Date
    }

    // MARK: - Initialization

    init() {
        refreshFromDisk()
    }

    // MARK: - Download

    /// Download a .nam model file from a presigned URL.
    func download(
        toneId: String,
        toneName: String,
        gear: String,
        author: String,
        modelId: String,
        modelName: String,
        modelSize: String,
        modelURL: URL,
        accessToken: String
    ) async throws {
        guard let tonesURL = tonesDirectoryURL() else {
            throw ToneStoreError.noAppGroup
        }

        isDownloading = true
        downloadProgress = 0
        lastError = nil

        defer { isDownloading = false }

        // Create tone directory
        let toneDir = tonesURL.appendingPathComponent(toneId)
        try FileManager.default.createDirectory(at: toneDir, withIntermediateDirectories: true)

        // Download the .nam file
        var request = URLRequest(url: modelURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ConjureDSP-AUv3", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ToneStoreError.downloadFailed("HTTP \(status)")
        }

        // Write .nam file
        let namFile = toneDir.appendingPathComponent("\(modelId).nam")
        try data.write(to: namFile, options: .atomic)

        // Update metadata
        var metadata = loadToneMetadata(toneId: toneId, tonesURL: tonesURL) ?? ToneMetadata(
            toneId: toneId, toneName: toneName, gear: gear, author: author, models: []
        )
        var models = metadata.models.filter { $0.modelId != modelId }
        models.append(ModelMetadata(
            modelId: modelId, modelName: modelName,
            modelSize: modelSize, downloadDate: Date()
        ))
        metadata = ToneMetadata(
            toneId: toneId, toneName: toneName, gear: gear, author: author, models: models
        )
        saveToneMetadata(metadata, tonesURL: tonesURL)

        log.info("Downloaded tone model: \(toneName)/\(modelName) (\(data.count) bytes)")

        refreshFromDisk()
    }

    // MARK: - Query

    /// Returns the filesystem URL for a downloaded .nam file, or nil if not downloaded.
    func modelURL(toneId: String, modelId: String) -> URL? {
        guard let tonesURL = tonesDirectoryURL() else { return nil }
        let url = tonesURL
            .appendingPathComponent(toneId)
            .appendingPathComponent("\(modelId).nam")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns the tones directory path (for CONJUREDSP_TONES_DIR).
    var tonesDirectoryPath: String? {
        tonesDirectoryURL()?.path
    }

    // MARK: - Delete

    func delete(toneId: String, modelId: String) {
        guard let tonesURL = tonesDirectoryURL() else { return }

        let namFile = tonesURL
            .appendingPathComponent(toneId)
            .appendingPathComponent("\(modelId).nam")
        try? FileManager.default.removeItem(at: namFile)

        // Update metadata
        if var metadata = loadToneMetadata(toneId: toneId, tonesURL: tonesURL) {
            metadata = ToneMetadata(
                toneId: metadata.toneId, toneName: metadata.toneName,
                gear: metadata.gear, author: metadata.author,
                models: metadata.models.filter { $0.modelId != modelId }
            )
            if metadata.models.isEmpty {
                // Remove entire tone directory
                let toneDir = tonesURL.appendingPathComponent(toneId)
                try? FileManager.default.removeItem(at: toneDir)
            } else {
                saveToneMetadata(metadata, tonesURL: tonesURL)
            }
        }

        refreshFromDisk()
    }

    // MARK: - Refresh

    func refreshFromDisk() {
        guard let tonesURL = tonesDirectoryURL() else {
            downloadedModels = []
            return
        }

        var models: [DownloadedModel] = []

        guard let toneDirs = try? FileManager.default.contentsOfDirectory(
            at: tonesURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            downloadedModels = []
            return
        }

        for toneDir in toneDirs {
            guard let isDir = try? toneDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir else { continue }

            let toneId = toneDir.lastPathComponent
            let metadata = loadToneMetadata(toneId: toneId, tonesURL: tonesURL)

            // Scan for .nam files
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: toneDir, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "nam" {
                let modelId = file.deletingPathExtension().lastPathComponent
                let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let modelMeta = metadata?.models.first { $0.modelId == modelId }

                models.append(DownloadedModel(
                    toneId: toneId,
                    modelId: modelId,
                    toneName: metadata?.toneName ?? toneId,
                    modelName: modelMeta?.modelName ?? modelId,
                    modelSize: modelMeta?.modelSize ?? "unknown",
                    gear: metadata?.gear ?? "",
                    author: metadata?.author ?? "",
                    downloadDate: modelMeta?.downloadDate ?? Date.distantPast,
                    fileSize: Int64(fileSize)
                ))
            }
        }

        downloadedModels = models.sorted { $0.downloadDate > $1.downloadDate }
    }

    // MARK: - Helpers

    private func tonesDirectoryURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
            .appendingPathComponent(Self.tonesDir)
    }

    private func loadToneMetadata(toneId: String, tonesURL: URL) -> ToneMetadata? {
        let metaURL = tonesURL
            .appendingPathComponent(toneId)
            .appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(ToneMetadata.self, from: data)
    }

    private func saveToneMetadata(_ metadata: ToneMetadata, tonesURL: URL) {
        let metaURL = tonesURL
            .appendingPathComponent(metadata.toneId)
            .appendingPathComponent("metadata.json")
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    // MARK: - Errors

    enum ToneStoreError: LocalizedError {
        case noAppGroup
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAppGroup:
                return "App Group container not available"
            case .downloadFailed(let reason):
                return "Download failed: \(reason)"
            }
        }
    }
}
