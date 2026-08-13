import Foundation

struct ProjectSidebarEnvelope: Codable, Equatable {
    let version: Int
    let workspace: ProjectSidebarWorkspace

    init(version: Int = ProjectSidebarWorkspace.currentVersion, workspace: ProjectSidebarWorkspace) {
        self.version = version
        self.workspace = workspace
    }
}

enum ProjectSidebarStoreError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidWorkspace(ProjectSidebarValidationError)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Workspace version \(version) is newer than this Ghostty version."
        case .invalidWorkspace(let error): error.localizedDescription
        case .unavailable: "The workspace could not be read."
        }
    }
}

struct ProjectSidebarLoadResult {
    let workspace: ProjectSidebarWorkspace
    let recoveredFromBackup: Bool
    let notice: String?
}

/// Versioned persistence for the sidebar's metadata. The store has no knowledge of live
/// surfaces or processes, which makes a successful load safe to perform during app startup.
final class ProjectSidebarStore {
    let directoryURL: URL
    let primaryURL: URL
    let backupURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.primaryURL = directoryURL.appendingPathComponent("workspace.json")
        self.backupURL = directoryURL.appendingPathComponent("workspace.backup.json")
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static var `default`: ProjectSidebarStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleName = Bundle.main.bundleIdentifier ?? "com.mitchell.Ghostty"
        return .init(directoryURL: support.appendingPathComponent(bundleName).appendingPathComponent("Project Sidebar"))
    }

    func load() -> ProjectSidebarLoadResult {
        let hasPrimary = fileManager.fileExists(atPath: primaryURL.path)
        let hasBackup = fileManager.fileExists(atPath: backupURL.path)
        if !hasPrimary && !hasBackup {
            return .init(workspace: .empty, recoveredFromBackup: false, notice: nil)
        }

        do {
            let workspace = try read(primaryURL)
            return .init(workspace: workspace, recoveredFromBackup: false, notice: nil)
        } catch let error as ProjectSidebarStoreError {
            switch error {
            case .unsupportedVersion:
                return .init(
                    workspace: .empty,
                    recoveredFromBackup: false,
                    notice: error.localizedDescription
                )
            case .invalidWorkspace:
                quarantine(primaryURL, suffix: "primary")
            case .unavailable:
                break
            }
        } catch is DecodingError {
            quarantine(primaryURL, suffix: "primary")
        } catch {
            // Preserve a potentially valid primary file on transient filesystem failures.
        }

        do {
            let workspace = try read(backupURL)
            return .init(
                workspace: workspace,
                recoveredFromBackup: true,
                notice: "Ghostty recovered your Project Sidebar from its backup."
            )
        } catch {
            return .init(
                workspace: .empty,
                recoveredFromBackup: false,
                notice: "The saved Project Sidebar could not be read. A new empty workspace was opened."
            )
        }
    }

    func save(_ workspace: ProjectSidebarWorkspace) throws {
        do {
            try ProjectSidebarWorkspaceValidator.validate(workspace)
        } catch let error as ProjectSidebarValidationError {
            throw ProjectSidebarStoreError.invalidWorkspace(error)
        }

        let data = try encoder.encode(ProjectSidebarEnvelope(workspace: workspace))
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = directoryURL.appendingPathComponent("workspace.\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: [.atomic])
        defer { try? fileManager.removeItem(at: temporaryURL) }

        if fileManager.fileExists(atPath: primaryURL.path) {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: primaryURL, to: backupURL)
            _ = try fileManager.replaceItemAt(primaryURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: primaryURL)
        }
    }

    private func read(_ url: URL) throws -> ProjectSidebarWorkspace {
        let data = try Data(contentsOf: url)
        let envelope = try decoder.decode(ProjectSidebarEnvelope.self, from: data)
        guard envelope.version <= ProjectSidebarWorkspace.currentVersion else {
            throw ProjectSidebarStoreError.unsupportedVersion(envelope.version)
        }

        let migrated = try migrate(envelope)
        do {
            return try migrated.validated()
        } catch let error as ProjectSidebarValidationError {
            throw ProjectSidebarStoreError.invalidWorkspace(error)
        }
    }

    private func migrate(_ envelope: ProjectSidebarEnvelope) throws -> ProjectSidebarWorkspace {
        switch envelope.version {
        case 0...ProjectSidebarWorkspace.currentVersion:
            return envelope.workspace
        default:
            throw ProjectSidebarStoreError.unsupportedVersion(envelope.version)
        }
    }

    private func quarantine(_ url: URL, suffix: String) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let quarantined = directoryURL.appendingPathComponent(
            "workspace.\(suffix).\(UUID().uuidString).json"
        )
        try? fileManager.moveItem(at: url, to: quarantined)
    }
}
