import Foundation

/// The persisted state of the Project Sidebar workspace.
///
/// Runtime objects intentionally do not appear here. A decoded workspace is always a
/// description of entries that may be launched, never a description of processes that should
/// be restored automatically.
struct ProjectSidebarWorkspace: Codable, Equatable {
    static let currentVersion = 1

    var projects: [ProjectSidebarProject]
    var sidebarVisible: Bool
    var sidebarWidth: Double

    init(
        projects: [ProjectSidebarProject] = [],
        sidebarVisible: Bool = true,
        sidebarWidth: Double = 240
    ) {
        self.projects = projects
        self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth
    }
}

struct ProjectSidebarProject: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var baseFolder: String
    var groups: [ProjectSidebarGroup]
    var ungroupedEntries: [ProjectSidebarTerminal]
    var isExpanded: Bool

    init(
        id: UUID = UUID(),
        name: String,
        baseFolder: String,
        groups: [ProjectSidebarGroup] = [],
        ungroupedEntries: [ProjectSidebarTerminal] = [],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.baseFolder = baseFolder
        self.groups = groups
        self.ungroupedEntries = ungroupedEntries
        self.isExpanded = isExpanded
    }

    var allEntries: [ProjectSidebarTerminal] {
        ungroupedEntries + groups.flatMap(\.entries)
    }
}

struct ProjectSidebarGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var entries: [ProjectSidebarTerminal]
    var isExpanded: Bool

    init(
        id: UUID = UUID(),
        name: String,
        entries: [ProjectSidebarTerminal] = [],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.isExpanded = isExpanded
    }
}

struct ProjectSidebarTerminal: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var launchDirectory: String

    init(id: UUID = UUID(), name: String, launchDirectory: String) {
        self.id = id
        self.name = name
        self.launchDirectory = launchDirectory
    }
}

enum ProjectSidebarNameScope: Equatable {
    case projects
    case groups(projectID: UUID)
    case terminals(projectID: UUID, groupID: UUID?)
}

enum ProjectSidebarValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName
    case duplicateBaseFolder
    case invalidSidebarWidth
    case orphanedGroup
    case orphanedTerminal
    case duplicateIdentifier
    case baseFolderUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName: "Name cannot be empty."
        case .duplicateName: "That name is already in use."
        case .duplicateBaseFolder: "That folder is already assigned to a project."
        case .invalidSidebarWidth: "Sidebar width is outside the supported range."
        case .orphanedGroup: "A group belongs to a project that does not exist."
        case .orphanedTerminal: "A terminal entry is not owned by a project."
        case .duplicateIdentifier: "Workspace identifiers must be unique."
        case .baseFolderUnavailable: "Choose an existing folder."
        }
    }
}

enum ProjectSidebarWorkspaceValidator {
    static let minimumSidebarWidth = 160.0
    static let maximumSidebarWidth = 560.0

    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    static func displayName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(_ workspace: ProjectSidebarWorkspace) throws {
        guard workspace.sidebarWidth >= minimumSidebarWidth,
              workspace.sidebarWidth <= maximumSidebarWidth else {
            throw ProjectSidebarValidationError.invalidSidebarWidth
        }

        var identifiers = Set<UUID>()
        var projectNames = Set<String>()
        var folders = Set<String>()

        for project in workspace.projects {
            guard identifiers.insert(project.id).inserted else { throw ProjectSidebarValidationError.duplicateIdentifier }
            try validateName(project.name, in: &projectNames)
            guard !project.baseFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectSidebarValidationError.orphanedGroup
            }

            let folderKey = canonicalFolderKey(project.baseFolder)
            guard folders.insert(folderKey).inserted else {
                throw ProjectSidebarValidationError.duplicateBaseFolder
            }

            var groupNames = Set<String>()
            for group in project.groups {
                guard identifiers.insert(group.id).inserted else { throw ProjectSidebarValidationError.duplicateIdentifier }
                try validateName(group.name, in: &groupNames)
                try validateEntries(group.entries, projectID: project.id, groupID: group.id, identifiers: &identifiers)
            }

            try validateEntries(project.ungroupedEntries, projectID: project.id, groupID: nil, identifiers: &identifiers)
        }
    }

    static func validateName(_ name: String, in names: inout Set<String>) throws {
        let key = normalizedName(name)
        guard !key.isEmpty else { throw ProjectSidebarValidationError.emptyName }
        guard names.insert(key).inserted else { throw ProjectSidebarValidationError.duplicateName }
    }

    static func canonicalFolderKey(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        return (resolved.isEmpty ? url.path : resolved)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private static func validateEntries(
        _ entries: [ProjectSidebarTerminal],
        projectID: UUID,
        groupID: UUID?,
        identifiers: inout Set<UUID>
    ) throws {
        var names = Set<String>()
        for entry in entries {
            guard identifiers.insert(entry.id).inserted else { throw ProjectSidebarValidationError.duplicateIdentifier }
            try validateName(entry.name, in: &names)
            guard !entry.launchDirectory.isEmpty else { throw ProjectSidebarValidationError.orphanedTerminal }
        }
    }

    static func isDirectoryAvailable(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

extension ProjectSidebarWorkspace {
    static var empty: Self { .init() }

    func validated() throws -> Self {
        try ProjectSidebarWorkspaceValidator.validate(self)
        return self
    }
}
