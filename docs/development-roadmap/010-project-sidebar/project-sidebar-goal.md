# Project Sidebar

## Feature

A macOS workspace for organizing terminal sessions in a persistent left sidebar. Users create projects tied to base folders, keep named terminal entries for different working directories, and organize those entries into one level of groups.

## Users & outcomes

Individual developers can keep multiple coding-agent and shell sessions running across repositories and worktrees, switch among them without interruption, and recover their workspace organization after restarting the app without automatically restarting terminal processes.

## In-scope behaviors

- **B1** — The app presents one main workspace window with a left sidebar and one selected terminal area; closing the window hides it without stopping running terminals.
- **B2** — A user creates a project by choosing an existing base folder. Its editable name defaults to the folder name, and an editable “Terminal 1” entry launches immediately in that folder.
- **B3** — A base folder belongs to at most one project; cancelling folder selection or choosing a duplicate creates nothing.
- **B4** — Creating another terminal immediately launches it in the project base folder and saves an independently editable launch directory. Shell navigation never changes that saved directory, and editing it affects only future launches.
- **B5** — Project names are non-empty and globally unique; group names are non-empty and unique within a project; terminal names are non-empty and unique among siblings. All can be renamed without changing paths or running processes.
- **B6** — Each project supports ungrouped terminal entries and one level of named groups containing terminal entries; groups cannot nest.
- **B7** — Users manually reorder projects, groups, and terminal entries, and move entries between ungrouped and grouped positions within one project. Entries cannot move between projects.
- **B8** — Projects and groups can be collapsed. The sidebar can be resized or hidden. Expansion, visibility, width, and manual ordering persist without affecting running terminals.
- **B9** — Every terminal entry visibly reports whether it is running, stopped, or unavailable. A stable saved name remains primary; shell-generated titles may appear only as secondary information.
- **B10** — Terminals in multiple projects continue running concurrently while selecting an entry changes only the terminal displayed in the main area.
- **B11** — Closing a terminal stops its process but preserves its name, launch directory, group, and position for later reuse.
- **B12** — Selecting a stopped entry launches a fresh terminal in its saved directory. An unavailable directory never falls back silently to another location.
- **B13** — Restarting the app restores projects, groups, terminal entries, names, paths, ordering, and layout, but does not restore processes or terminal output. No terminal launches until the user explicitly selects one.
- **B14** — If a project base folder becomes unavailable, the project remains visible and can be assigned a replacement. New default terminals are disabled until repair, and replacement does not rewrite existing terminal directories.
- **B15** — If a terminal directory is unavailable, its entry remains visible and offers replacement or deletion. If terminal launch fails, the stopped entry and its organization remain, with Retry, Change Folder, and Delete actions.
- **B16** — Deleting a running terminal entry requires confirmation and stops its process; deleting a stopped entry removes it directly.
- **B17** — Deleting a group moves its entries to the project’s ungrouped area without stopping processes.
- **B18** — Deleting a project requires confirmation, states how many running terminals will stop, and removes the project, its groups, and its terminal entries.
- **B19** — Quitting with running terminals requires confirmation stating how many sessions will stop. Relaunch restores their saved entries as stopped.
- **B20** — Sidebar terminal entries replace native tabs as the primary session navigation, while existing terminal and split-pane behavior remains available within the selected entry.
- **B21** — `Command-T` creates and launches a terminal in the selected project, or opens project creation when none is selected. `Command-W` stops the selected process but preserves its entry.
- **B22** — With no projects, the workspace explains the project model and provides a single Create Project action.

## Acceptance checks

- **B1** — Verified when closing a workspace containing running terminals removes the window, reopening it shows the same live terminals, and only quitting or explicit stop actions end them.
- **B2** — Verified when selecting a folder creates a project named from that folder and immediately displays a running, editable “Terminal 1” entry whose shell starts there.
- **B3** — Verified when a second project cannot use an already assigned base folder and cancelling the folder picker leaves the workspace unchanged.
- **B4** — Verified when a new entry starts in the project base folder, can be assigned another directory for its next launch, and running `cd` does not alter that assignment.
- **B5** — Verified when empty or conflicting names show an inline error without discarding input, and valid renames leave paths and running processes unchanged.
- **B6** — Verified when entries can be ungrouped or placed in one named group and no action allows a group inside another group.
- **B7** — Verified when drag-and-drop changes and preserves all supported orders and group membership, while no drop target permits a cross-project move.
- **B8** — Verified when collapse state, sidebar visibility, sidebar width, and order survive relaunch and hidden entries continue running.
- **B9** — Verified when entries accurately show running, stopped, and unavailable states and a shell title change does not replace the saved sidebar name.
- **B10** — Verified when terminals in two projects continue producing output while the user switches the main view among them.
- **B11** — Verified when closing a running terminal ends its process, marks the entry stopped, and preserves its saved metadata and placement.
- **B12** — Verified when selecting a stopped entry launches a new process in its saved directory and selecting an unavailable entry launches nothing elsewhere.
- **B13** — Verified when relaunch restores the saved workspace into a “Select a terminal to start” state with every entry stopped and no prior output present.
- **B14** — Verified when a missing project folder leaves the project visible, blocks default-terminal creation, and accepting a replacement changes only the project base folder.
- **B15** — Verified when missing-directory and shell-launch failures preserve the entry and present the specified recovery actions without starting in a fallback directory.
- **B16** — Verified when deleting a running entry warns before stopping it, while deleting a stopped entry removes it without a process warning.
- **B17** — Verified when deleting a populated group leaves all its entries running or stopped as before in the ungrouped area.
- **B18** — Verified when project deletion reports the correct running-terminal count, changes nothing if cancelled, and removes all contained state if confirmed.
- **B19** — Verified when quitting reports the correct live-session count, can be cancelled without effect, and a confirmed quit restores all entries as stopped on relaunch.
- **B20** — Verified when sidebar selection provides terminal navigation without a native tab bar and split panes still work inside the selected entry.
- **B21** — Verified when `Command-T` and `Command-W` produce the stated sidebar behaviors both with and without a selected project or running terminal.
- **B22** — Verified when a fresh workspace shows the explanation and Create Project action, which opens folder selection.

## Non-goals / out of scope

- Git repository or worktree creation, discovery, inspection, or deletion.
- Coding-agent integration, command templates, task management, or project status features.
- Terminal process or output restoration after app termination.
- Nested groups or terminal movement between projects.
- Multiple workspace windows.
- Cloud sync, accounts, collaboration, or shared workspaces.
- GTK or other non-macOS implementations.

## Constraints & non-negotiables

- macOS only for this feature.
- The project base folder and each terminal launch directory are explicit saved choices, not values inferred from a shell’s live working directory.
- Workspace persistence must never cause terminal processes to start without an explicit user action.
- Existing Ghostty terminal rendering and split-pane behavior must remain available.
- The feature remains a local terminal manager and does not interpret or modify repository contents.

## Assumptions

- The workspace is for one local user and requires no account or sharing model.
- A terminal launch directory may be outside its project base folder, including an existing worktree directory.
- Ghostty’s normal terminal-termination protections remain applicable within each running entry.

## Open questions for plan

- How should saved workspace organization coexist with Ghostty’s existing macOS restoration behavior?
- What app-level ownership should keep running terminals alive while the workspace window is hidden?
- How should the sidebar represent terminal entries that contain split panes without creating a second navigation hierarchy?
- What migration and recovery strategy should protect saved workspace data across future versions or malformed state?
