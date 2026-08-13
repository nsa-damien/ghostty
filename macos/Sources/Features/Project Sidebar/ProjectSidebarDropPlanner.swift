import Foundation

enum ProjectSidebarDraggedItem: Equatable {
    case group(UUID)
    case project(UUID)
    case terminal(UUID)
    case folderURL(URL)
}

enum ProjectSidebarDropTarget: Equatable {
    case folders(index: Int)
    case folder(UUID)
    case projects(groupID: UUID?, index: Int)
    case terminals(projectID: UUID, index: Int)
}

enum ProjectSidebarDropPlan: Equatable {
    case moveGroup(UUID, before: UUID?)
    case moveProject(UUID, toGroup: UUID?, before: UUID?)
    case moveTerminal(UUID, before: UUID?)
    case createProject(URL, inGroup: UUID?)
}

enum ProjectSidebarDropPlanner {
    static func plan(
        dragging item: ProjectSidebarDraggedItem,
        onto target: ProjectSidebarDropTarget,
        in workspace: ProjectSidebarWorkspace
    ) -> ProjectSidebarDropPlan? {
        switch (item, target) {
        case (.group(let groupID), .folders(let index)):
            guard workspace.groups.contains(where: { $0.id == groupID }) else { return nil }
            return .moveGroup(groupID, before: workspace.groups[safe: index]?.id)

        case (.project(let projectID), .folder(let groupID)):
            guard workspace.location(ofProject: projectID) != nil,
                  workspace.groups.contains(where: { $0.id == groupID }) else { return nil }
            return .moveProject(projectID, toGroup: groupID, before: nil)

        case (.project(let projectID), .projects(let groupID, let index)):
            guard workspace.location(ofProject: projectID) != nil,
                  let projects = projects(in: groupID, workspace: workspace) else { return nil }
            return .moveProject(projectID, toGroup: groupID, before: projects[safe: index]?.id)

        case (.terminal(let terminalID), .terminals(let projectID, let index)):
            guard let source = workspace.location(ofTerminal: terminalID),
                  source.projectID == projectID,
                  let location = workspace.location(ofProject: projectID) else { return nil }
            let project = workspace.project(at: location)
            return .moveTerminal(terminalID, before: project.terminals[safe: index]?.id)

        case (.folderURL(let url), .folder(let groupID)):
            guard workspace.groups.contains(where: { $0.id == groupID }) else { return nil }
            return .createProject(url, inGroup: groupID)

        case (.folderURL(let url), .projects(let groupID, _)):
            if let groupID, !workspace.groups.contains(where: { $0.id == groupID }) { return nil }
            return .createProject(url, inGroup: groupID)

        default:
            return nil
        }
    }

    private static func projects(
        in groupID: UUID?,
        workspace: ProjectSidebarWorkspace
    ) -> [ProjectSidebarProject]? {
        guard let groupID else { return workspace.ungroupedProjects }
        return workspace.groups.first(where: { $0.id == groupID })?.projects
    }
}

private extension ProjectSidebarWorkspace {
    func location(ofTerminal terminalID: UUID) -> (projectID: UUID, terminalIndex: Int)? {
        for project in projects {
            if let terminalIndex = project.terminals.firstIndex(where: { $0.id == terminalID }) {
                return (project.id, terminalIndex)
            }
        }
        return nil
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
