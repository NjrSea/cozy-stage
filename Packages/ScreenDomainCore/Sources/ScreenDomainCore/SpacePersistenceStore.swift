import Foundation

// MARK: - Phase 1B: Atomic Space persistence store

/// Protocol for loading and atomically saving Saved Spaces. The store persists
/// only structural data (layout geometry, bundle IDs, routing rules, slot
/// status) — never screenshots, document bodies, browser contents, terminal
/// jobs, passwords, or user input.
public protocol SpacePersisting: AnyObject {
    /// Loads all saved spaces from the checkpoint. Returns an empty array if the
    /// checkpoint does not exist yet (first launch).
    func load() throws -> [SavedSpace]

    /// Atomically writes the full set of saved spaces. Uses a write-temp →
    /// fsync → rename pattern so a crash during write never leaves a corrupt or
    /// partial checkpoint.
    func saveAtomically(_ spaces: [SavedSpace]) throws
}

/// Errors specific to the local persistence store.
public enum SpacePersistenceError: Error, Equatable {
    /// The checkpoint file exists but could not be decoded (corruption,
    /// schema mismatch, or unknown keys).
    case checkpointCorrupted
    /// The checkpoint directory does not exist or is not writable.
    case directoryUnavailable
}

/// File-system backed implementation of `SpacePersisting`. Writes are atomic:
/// data is serialized to a temporary file in the same directory, fsync'd, then
/// renamed over the target path. This guarantees that a crash mid-write leaves
/// the previous checkpoint intact.
public final class LocalSpacePersistenceStore: SpacePersisting {

    private let url: URL
    private let fileManager: FileManager
    private let directoryURL: URL

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        self.directoryURL = url.deletingLastPathComponent()
    }

    public func load() throws -> [SavedSpace] {
        guard fileManager.fileExists(atPath: url.path) else {
            // First launch: no checkpoint yet.
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SpacePersistenceError.checkpointCorrupted
        }

        guard !data.isEmpty else {
            return []
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode([SavedSpace].self, from: data)
        } catch {
            // Corrupted or schema-mismatched checkpoint.
            throw SpacePersistenceError.checkpointCorrupted
        }
    }

    public func saveAtomically(_ spaces: [SavedSpace]) throws {
        // Ensure the directory exists.
        if !fileManager.fileExists(atPath: directoryURL.path) {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                throw SpacePersistenceError.directoryUnavailable
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(spaces)
        } catch {
            // Encoding should never fail for well-formed SavedSpace values.
            throw SpacePersistenceError.checkpointCorrupted
        }

        // Write to a temp file in the SAME directory (so rename is atomic on the
        // same volume).
        let tempURL = directoryURL.appendingPathComponent(".checkpoint-tmp-\(UUID().uuidString)")

        do {
            fileManager.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            try handle.write(contentsOf: data)

            // fsync to force the data to disk before renaming.
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw SpacePersistenceError.directoryUnavailable
        }

        // Atomic rename over the target.
        do {
            // On APFS/HFS+, rename is atomic when source and destination are in
            // the same directory.
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            // Fallback: remove old, then rename.
            try? fileManager.removeItem(at: url)
            do {
                try fileManager.moveItem(at: tempURL, to: url)
            } catch {
                try? fileManager.removeItem(at: tempURL)
                throw SpacePersistenceError.directoryUnavailable
            }
        }
    }
}
