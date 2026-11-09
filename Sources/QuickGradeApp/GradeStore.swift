import CryptoKit
import Foundation
import QuickGradeCore

enum GradeStore {
    static func load(for file: URL) -> GradeSettings? {
        let url = storeURL(for: file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GradeSettings.self, from: data)
    }

    static func save(_ settings: GradeSettings, for file: URL) {
        let url = storeURL(for: file)
        if settings.isNeutral {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Pixels to grade. Once a thumbnail has been published, the file in Finder
    /// is the graded copy and this returns the untouched original.
    static func originalURL(for file: URL) -> URL {
        let stash = originalFileURL(for: file)
        if FileManager.default.fileExists(atPath: stash.path) { return stash }
        return file
    }

    static func iconIsCurrent(_ settings: GradeSettings, for file: URL) -> Bool {
        if settings.isNeutral {
            return !FileManager.default.fileExists(atPath: originalFileURL(for: file).path)
        }
        guard let data = try? Data(contentsOf: iconMarkURL(for: file)),
              let saved = try? JSONDecoder().decode(GradeSettings.self, from: data) else { return false }
        return saved == settings
    }

    /// Copies the file aside the first time. Later calls keep that first copy,
    /// so a graded Finder file is never treated as the original.
    static func preserveOriginal(of file: URL) -> Bool {
        let stash = originalFileURL(for: file)
        if FileManager.default.fileExists(atPath: stash.path) { return true }
        do {
            try FileManager.default.copyItem(at: file, to: stash)
            return true
        } catch {
            return false
        }
    }

    static func restoreOriginal(of file: URL) {
        let stash = originalFileURL(for: file)
        guard FileManager.default.fileExists(atPath: stash.path) else { return }
        let ext = file.pathExtension.isEmpty ? "jpg" : file.pathExtension
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickgrade-restore-" + UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try FileManager.default.copyItem(at: stash, to: temp)
            try swapIn(temp, replacing: file)
            try? FileManager.default.removeItem(at: stash)
            clearIconMark(for: file)
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    static func markIcon(_ settings: GradeSettings, for file: URL) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: iconMarkURL(for: file), options: .atomic)
    }

    static func clearIconMark(for file: URL) {
        try? FileManager.default.removeItem(at: iconMarkURL(for: file))
    }

    /// Replaces the bytes at `file` so Finder rebuilds the thumbnail.
    /// The path and extension stay put. A sibling `*.quickgrade-bak` rename
    /// makes Finder follow the old inode and stop treating the selection as a photo.
    static func swapIn(_ temp: URL, replacing file: URL) throws {
        let file = ImageKind.posixFileURL(file)
        let keptExtension = file.pathExtension
        do {
            let replaced = try FileManager.default.replaceItemAt(
                file,
                withItemAt: temp,
                backupItemName: nil,
                options: []
            )
            if let replaced {
                let parked = ImageKind.posixFileURL(replaced)
                if parked.path != file.path {
                    if FileManager.default.fileExists(atPath: file.path) {
                        try? FileManager.default.removeItem(at: parked)
                    } else {
                        try FileManager.default.moveItem(at: parked, to: file)
                    }
                }
            }
        } catch {
            let data = try Data(contentsOf: temp)
            let handle = try FileHandle(forWritingTo: file)
            do {
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try? FileManager.default.removeItem(at: temp)
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !keptExtension.isEmpty, file.pathExtension.lowercased() != keptExtension.lowercased() {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    /// Moves the grade, the stashed original and the icon mark to a renamed file.
    static func move(from old: URL, to new: URL) {
        let pairs = [
            (storeURL(for: old), storeURL(for: new)),
            (originalFileURL(for: old), originalFileURL(for: new)),
            (iconMarkURL(for: old), iconMarkURL(for: new))
        ]
        for (from, to) in pairs where FileManager.default.fileExists(atPath: from.path) {
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }

    private static func storeURL(for file: URL) -> URL {
        let folder = directory()
        return folder.appendingPathComponent(key(for: file)).appendingPathExtension("json")
    }

    private static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickGrade", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func key(for file: URL) -> String {
        let path = ImageKind.posixFileURL(file).path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func originalFileURL(for file: URL) -> URL {
        let file = ImageKind.posixFileURL(file)
        let ext = file.pathExtension.isEmpty ? "bin" : file.pathExtension
        return directory().appendingPathComponent(key(for: file) + ".original").appendingPathExtension(ext)
    }

    private static func iconMarkURL(for file: URL) -> URL {
        directory().appendingPathComponent(key(for: file)).appendingPathExtension("icon")
    }
}
