import Foundation

/// Persisted sidebar metadata. Runtime objects intentionally never appear here.
struct ProjectSidebarWorkspace: Codable, Equatable {
    static let currentVersion = 2

    var groups: [ProjectSidebarGroup]
    var ungroupedProjects: [ProjectSidebarProject]
    var sidebarVisible: Bool
    var sidebarWidth: Double

    init(
        groups: [ProjectSidebarGroup] = [],
        ungroupedProjects: [ProjectSidebarProject] = [],
        sidebarVisible: Bool = true,
        sidebarWidth: Double = 240
    ) {
        self.groups = groups
        self.ungroupedProjects = ungroupedProjects
        self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth
    }

    /// Groups are intentionally listed first in the sidebar, followed by loose projects.
    var projects: [ProjectSidebarProject] {
        groups.flatMap(\.projects) + ungroupedProjects
    }

    private enum CodingKeys: String, CodingKey {
        case groups
        case ungroupedProjects
        case projects
        case sidebarVisible
        case sidebarWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([ProjectSidebarGroup].self, forKey: .groups) ?? []
        ungroupedProjects = try container.decodeIfPresent(
            [ProjectSidebarProject].self,
            forKey: .ungroupedProjects
        ) ?? container.decodeIfPresent([ProjectSidebarProject].self, forKey: .projects) ?? []
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 240
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groups, forKey: .groups)
        try container.encode(ungroupedProjects, forKey: .ungroupedProjects)
        try container.encode(sidebarVisible, forKey: .sidebarVisible)
        try container.encode(sidebarWidth, forKey: .sidebarWidth)
    }
}

struct ProjectSidebarGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var projects: [ProjectSidebarProject]
    var isExpanded: Bool

    init(
        id: UUID = UUID(),
        name: String,
        projects: [ProjectSidebarProject] = [],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.projects = projects
        self.isExpanded = isExpanded
    }
}

struct ProjectSidebarProject: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var baseFolder: String
    var terminals: [ProjectSidebarTerminal]
    var isExpanded: Bool

    init(
        id: UUID = UUID(),
        name: String,
        baseFolder: String,
        terminals: [ProjectSidebarTerminal] = [],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name
        self.baseFolder = baseFolder
        self.terminals = terminals
        self.isExpanded = isExpanded
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseFolder
        case terminals
        case isExpanded
        case groups
        case ungroupedEntries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseFolder = try container.decode(String.self, forKey: .baseFolder)
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        if let decoded = try container.decodeIfPresent([ProjectSidebarTerminal].self, forKey: .terminals) {
            terminals = decoded
        } else {
            let ungrouped = try container.decodeIfPresent(
                [ProjectSidebarTerminal].self,
                forKey: .ungroupedEntries
            ) ?? []
            let legacyGroups = try container.decodeIfPresent(
                [LegacyProjectSidebarTerminalGroup].self,
                forKey: .groups
            ) ?? []
            terminals = ungrouped + legacyGroups.flatMap(\.entries)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseFolder, forKey: .baseFolder)
        try container.encode(terminals, forKey: .terminals)
        try container.encode(isExpanded, forKey: .isExpanded)
    }
}

private struct LegacyProjectSidebarTerminalGroup: Decodable {
    let entries: [ProjectSidebarTerminal]
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

struct ProjectSidebarProjectLocation: Equatable {
    let groupIndex: Int?
    let projectIndex: Int
}

extension ProjectSidebarWorkspace {
    @discardableResult
    mutating func appendProject(_ project: ProjectSidebarProject, toGroup groupID: UUID?) -> Bool {
        if let groupID {
            guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return false }
            groups[groupIndex].projects.append(project)
            groups[groupIndex].isExpanded = true
        } else {
            ungroupedProjects.append(project)
        }
        return true
    }

    func location(ofProject projectID: UUID) -> ProjectSidebarProjectLocation? {
        for (groupIndex, group) in groups.enumerated() {
            if let projectIndex = group.projects.firstIndex(where: { $0.id == projectID }) {
                return .init(groupIndex: groupIndex, projectIndex: projectIndex)
            }
        }
        if let projectIndex = ungroupedProjects.firstIndex(where: { $0.id == projectID }) {
            return .init(groupIndex: nil, projectIndex: projectIndex)
        }
        return nil
    }

    func project(at location: ProjectSidebarProjectLocation) -> ProjectSidebarProject {
        if let groupIndex = location.groupIndex {
            return groups[groupIndex].projects[location.projectIndex]
        }
        return ungroupedProjects[location.projectIndex]
    }

    mutating func replaceProject(
        at location: ProjectSidebarProjectLocation,
        with project: ProjectSidebarProject
    ) {
        if let groupIndex = location.groupIndex {
            groups[groupIndex].projects[location.projectIndex] = project
        } else {
            ungroupedProjects[location.projectIndex] = project
        }
    }

    @discardableResult
    mutating func removeProject(at location: ProjectSidebarProjectLocation) -> ProjectSidebarProject {
        if let groupIndex = location.groupIndex {
            return groups[groupIndex].projects.remove(at: location.projectIndex)
        }
        return ungroupedProjects.remove(at: location.projectIndex)
    }

    @discardableResult
    mutating func moveProject(
        _ projectID: UUID,
        toGroup groupID: UUID?,
        before destinationID: UUID?
    ) -> Bool {
        guard projectID != destinationID,
              let source = location(ofProject: projectID) else { return projectID == destinationID }
        let destinationGroupIndex: Int?
        if let groupID {
            guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
            destinationGroupIndex = index
        } else {
            destinationGroupIndex = nil
        }

        let project = removeProject(at: source)
        if let destinationGroupIndex {
            let destination = destinationID.flatMap { id in
                groups[destinationGroupIndex].projects.firstIndex(where: { $0.id == id })
            } ?? groups[destinationGroupIndex].projects.count
            groups[destinationGroupIndex].projects.insert(project, at: destination)
        } else {
            let destination = destinationID.flatMap { id in
                ungroupedProjects.firstIndex(where: { $0.id == id })
            } ?? ungroupedProjects.count
            ungroupedProjects.insert(project, at: destination)
        }
        return true
    }

    @discardableResult
    mutating func moveGroup(_ groupID: UUID, before destinationID: UUID?) -> Bool {
        guard groupID != destinationID,
              let source = groups.firstIndex(where: { $0.id == groupID }) else {
            return groupID == destinationID
        }
        let group = groups.remove(at: source)
        let destination = destinationID.flatMap { id in
            groups.firstIndex(where: { $0.id == id })
        } ?? groups.count
        groups.insert(group, at: destination)
        return true
    }
}

enum ProjectSidebarNameScope: Equatable {
    case projects
    case groups
    case terminals(projectID: UUID)
}

enum ProjectSidebarValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateName
    case duplicateBaseFolder
    case invalidSidebarWidth
    case orphanedProject
    case orphanedTerminal
    case duplicateIdentifier
    case baseFolderUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName: "Name cannot be empty."
        case .duplicateName: "That name is already in use."
        case .duplicateBaseFolder: "That folder is already assigned to a project."
        case .invalidSidebarWidth: "Sidebar width is outside the supported range."
        case .orphanedProject: "A project must have a base folder."
        case .orphanedTerminal: "A terminal entry must have a launch folder."
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
        var groupNames = Set<String>()
        var projectNames = Set<String>()
        var folders = Set<String>()

        for group in workspace.groups {
            guard identifiers.insert(group.id).inserted else {
                throw ProjectSidebarValidationError.duplicateIdentifier
            }
            try validateName(group.name, in: &groupNames)
            for project in group.projects {
                try validateProject(
                    project,
                    identifiers: &identifiers,
                    projectNames: &projectNames,
                    folders: &folders
                )
            }
        }

        for project in workspace.ungroupedProjects {
            try validateProject(
                project,
                identifiers: &identifiers,
                projectNames: &projectNames,
                folders: &folders
            )
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

    static func isDirectoryAvailable(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func validateProject(
        _ project: ProjectSidebarProject,
        identifiers: inout Set<UUID>,
        projectNames: inout Set<String>,
        folders: inout Set<String>
    ) throws {
        guard identifiers.insert(project.id).inserted else {
            throw ProjectSidebarValidationError.duplicateIdentifier
        }
        try validateName(project.name, in: &projectNames)
        guard !project.baseFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectSidebarValidationError.orphanedProject
        }
        guard folders.insert(canonicalFolderKey(project.baseFolder)).inserted else {
            throw ProjectSidebarValidationError.duplicateBaseFolder
        }

        var terminalNames = Set<String>()
        for terminal in project.terminals {
            guard identifiers.insert(terminal.id).inserted else {
                throw ProjectSidebarValidationError.duplicateIdentifier
            }
            try validateName(terminal.name, in: &terminalNames)
            guard !terminal.launchDirectory.isEmpty else {
                throw ProjectSidebarValidationError.orphanedTerminal
            }
        }
    }
}

extension ProjectSidebarWorkspace {
    static var empty: Self { .init() }

    func validated() throws -> Self {
        try ProjectSidebarWorkspaceValidator.validate(self)
        return self
    }
}
