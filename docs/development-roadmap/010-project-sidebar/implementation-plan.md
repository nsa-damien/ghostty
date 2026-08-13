## Brief

- Goal brief: `docs/development-roadmap/010-project-sidebar/project-sidebar-goal.md`
- Goal brief blob: `95280442e216efe44cd93391cc5e7436ef32a6b8`

## Approach

Introduce a macOS-only `Project Sidebar` feature area with three deliberately separate layers:

1. A persistent workspace model owns top-level folders, projects, terminal entries, ordering, saved launch directories, and layout preferences. Stable UUIDs identify every folder, project, and terminal entry. Folders store ordered projects, the workspace stores ordered ungrouped projects, and each project stores one ordered terminal array. This nested shape makes one-level project organization structural and gives every project and terminal exactly one location without duplicate membership references.
2. A workspace store writes a versioned JSON envelope in Ghostty's Application Support directory. It validates before save and after load or migration, writes through atomic replacement, and retains one last-known-good backup. It never stores a `SurfaceView`, split tree, process state, terminal output, shell-reported working directory, or running flag.
3. An app-lifetime runtime registry maps stable terminal-entry IDs to optional live runtimes. Each runtime owns the entry's complete `SplitTree<Ghostty.SurfaceView>` and focused surface. The single workspace window mounts only the selected runtime, while the registry keeps every other runtime alive and marks its surfaces unfocused and visually occluded without stopping terminal I/O.

`AppDelegate` strongly owns one workspace controller. The controller owns the workspace window controller, persistent model/store, and runtime registry. The red window control orders the workspace window out instead of closing it. Dock reopen reveals that retained window. App termination and destructive operations query the registry, so hidden and unselected entries are included in running-entry counts.

The workspace becomes the restoration authority for regular terminal entries. Its window does not participate in `NSWindowRestoration`, and legacy regular-window restoration records are declined before decoding while the workspace is active. Workspace data loads independently of `window-save-state`; all restored entries begin stopped, no entry is selected for launch, and the content area asks the user to select a terminal. Quick Terminal keeps its existing separate restoration path.

The workspace window composes a SwiftUI sidebar with the existing `TerminalView` and `TerminalSplitTreeView` detail stack. One sidebar terminal row represents one complete split tree, never an individual pane. The row's saved name and aggregate status come from workspace state; the focused pane's shell-generated title may be shown only as secondary text. Pane focus, creation, resizing, reordering within the tree, zoom, and pane-level closing remain inside the selected entry. Native AppKit tabs are not created for workspace entries, and split extraction cannot turn an entry into a second workspace or native-tab navigation hierarchy.

Workspace commands are routed at the workspace controller/responder boundary. `Command-T` creates an entry in the selected project or starts project creation when no project is selected. `Command-W` stops the selected entry's entire runtime without registering terminal undo, then leaves its persistent record stopped. Existing pane-level close actions continue to use current split behavior.

Folder and name rules are centralized in model services so the UI and persisted-state validator cannot disagree. Names are non-empty after trimming surrounding whitespace and compare by a normalized, case-insensitive key in their required uniqueness scope while preserving the accepted display spelling. Reachable project folders compare by standardized, symlink-resolved filesystem identity, with a normalized-path fallback. Terminal launch directories remain explicit strings and may be outside the project base folder.

Directory availability is derived at display and immediately before launch; it is not persisted. Runtime status resolves in this order: running when the registry owns at least one live process for the entry, unavailable when no runtime is live and the saved launch directory cannot be used, otherwise stopped. Editing a running entry's launch directory changes only its next launch. Replacing a project base folder changes only that project field.

Add an opt-in strict-working-directory launch policy across the macOS surface configuration and core process-launch boundary. Workspace launches use it so a directory failure aborts process creation instead of taking the existing fallback path; all existing callers retain their current behavior by default. A failed launch disposes of any incomplete runtime, leaves the entry stopped in place, and exposes Retry, Change Folder, and Delete.

Keep shared terminal rendering, terminal emulation, the split-tree implementation, Quick Terminal, non-workspace configuration behavior, GTK, repository contents, and process/output restoration outside this change except for the narrow strict-directory and app-global surface-lookup hooks required by workspace runtimes.

## Resolved open questions

- **How should saved workspace organization coexist with Ghostty's existing macOS restoration behavior?** The workspace is the sole restoration authority for regular workspace entries. It persists metadata independently, disables AppKit restoration on its window, declines legacy regular-window restoration while active, and always restores entries without runtimes. This prevents the existing restorable `SurfaceView` graph from launching shells or importing shell-reported working directories. Quick Terminal remains independently restored.
- **What app-level ownership should keep running terminals alive while the workspace window is hidden?** `AppDelegate` retains a single workspace controller, which retains a runtime registry keyed by terminal-entry UUID. Each runtime retains its complete split tree. Hiding or switching presentation never releases that tree. This follows the existing app-retained Quick Terminal ownership pattern while making running-entry enumeration independent of `NSApp.windows`.
- **How should the sidebar represent terminal entries that contain split panes without creating a second navigation hierarchy?** One sidebar row represents one logical terminal entry and its complete split tree. The sidebar reports aggregate entry state and the saved entry name; pane focus and all split navigation stay in the selected detail view. Native tabs are not used for entries.
- **What migration and recovery strategy should protect saved workspace data across future versions or malformed state?** Decode the JSON envelope version first, migrate supported older versions through explicit deterministic steps, reject and preserve unsupported newer versions, and validate semantic invariants. Save only validated snapshots by atomic replacement while keeping one known-good backup. On primary failure, quarantine it and try the backup; if both fail, preserve both, open an empty workspace, and show a recovery notice rather than crashing, partially loading, or overwriting evidence.

## Confirmed assumptions

- **Confirmed:** The workspace serves one local user and requires no accounts, sharing, permissions, synchronization, or collaboration model.
- **Confirmed:** A terminal launch directory may be anywhere on the local filesystem, including outside its project base folder and in an existing worktree. Project membership is organizational, not a filesystem boundary.
- **Confirmed:** Ghostty's existing terminal-termination protections continue within each running entry. The brief's explicit entry, deletion, project, and quit behaviors take precedence at their corresponding workspace actions.

## Dependencies

None. Use Foundation, AppKit, SwiftUI, and existing Ghostty core and macOS helpers.

## Work units

### U1 - Workspace model, persistence, and stopped-state restoration

- **Delivers:** B13
- **Touches:** new `macos/Sources/Features/Project Sidebar/` model, validation, migration, and store types; `macos/Sources/App/AppDelegate.swift`; new `macos/Tests/Project Sidebar/` persistence and migration fixtures
- **Order:** serial, no dependencies
- **Character:** risk-sensitive
- **Done when:** a relaunch restores the complete saved organization and layout with an empty runtime registry, every entry stopped, no prior output, no selected terminal launch, supported old fixtures migrated, and corrupt or future-version snapshots preserved and recovered through the documented fallback.

### U2 - App-owned workspace window and project creation

- **Delivers:** B1, B2, B22
- **Touches:** new workspace controller, window controller, runtime registry foundation, folder-selection coordinator, empty-state and workspace-shell views under `macos/Sources/Features/Project Sidebar/`; `macos/Sources/App/AppDelegate.swift`; `macos/Sources/Features/Terminal/TerminalRestorable.swift`; macOS unit and UI tests
- **Order:** serial, depends on U1
- **Character:** risk-sensitive
- **Done when:** a fresh app presents an explanatory workspace with folder and project creation actions; choosing a folder or dropping one from Finder creates the default-named project and running editable `Terminal 1` there; a folder-row drop assigns the new project to that folder while other sidebar drops leave it ungrouped; closing and reopening the workspace preserves that live runtime; quitting or an explicit stop ends it.

### U3 - Sidebar organization, validation, ordering, and layout

- **Delivers:** B3, B5, B6, B7, B8, B17
- **Touches:** workspace model mutation services from U1; sidebar tree, inline editor, drag-and-drop, layout, and context-action views under `macos/Sources/Features/Project Sidebar/`; model, migration, interaction, persistence, and UI tests
- **Order:** serial, depends on U1 and U2
- **Character:** design-sensitive
- **Done when:** cancelled or duplicate repository-folder selection creates nothing; invalid names retain input with inline errors; top-level folders, projects, and terminal entries can be renamed and reordered only within their allowed scope; projects can move between folders and the ungrouped area while terminals remain in their project; collapse, sidebar visibility, width, and ordering survive relaunch; deleting a folder moves its projects to the workspace's ungrouped area without changing runtime state; and version-1 terminal groups migrate by flattening each terminal into its original project exactly once.

### U4 - Safe terminal launching, runtime status, and folder repair

- **Delivers:** B4, B9, B12, B14, B15
- **Touches:** workspace runtime registry and launch coordinator; status and recovery views under `macos/Sources/Features/Project Sidebar/`; `Ghostty.SurfaceConfiguration` bridging; the narrow core surface/process launch path under `src/` needed for opt-in strict working-directory handling; Swift and focused Zig regression tests
- **Order:** serial, depends on U1, U2, and U3
- **Character:** risk-sensitive
- **Done when:** new and restarted entries use only their explicit saved directory; shell `cd` and running-directory edits do not mutate or restart them; every row accurately reports running, stopped, or unavailable without losing its saved name; missing project or entry folders offer the specified repair behavior; and preflight or launch-time directory failure cannot start a shell elsewhere and leaves the organized stopped entry with Retry, Change Folder, and Delete.

### U5 - Concurrent entry presentation, split containment, and workspace commands

- **Delivers:** B10, B20, B21
- **Touches:** workspace detail host and command router; runtime surface registry and app-global surface lookup; `macos/Sources/Features/Terminal/BaseTerminalController.swift`; `macos/Sources/Features/Terminal/TerminalView.swift`; `macos/Sources/Features/Splits/`; `macos/Sources/App/AppDelegate.swift`; menu responder integration and macOS UI tests
- **Order:** serial, depends on U4
- **Character:** risk-sensitive
- **Done when:** terminals in multiple projects continue producing output while selection only swaps the displayed retained split tree; sidebar rows replace native tabs as entry navigation while all split behavior remains inside the selected entry; and `Command-T` and `Command-W` produce the briefed results with and without the required selection.

### U6 - Entry stopping, destructive actions, and quit handling

- **Delivers:** B11, B16, B18, B19
- **Touches:** workspace runtime registry, controller, deletion coordinators, and confirmation views; `macos/Sources/App/AppDelegate.swift` termination flow; lifecycle unit and UI tests
- **Order:** serial, depends on U3, U4, and U5
- **Character:** risk-sensitive
- **Done when:** stopping a running entry tears down its complete runtime without terminal undo and preserves its saved record; running-entry deletion confirms while stopped-entry deletion does not; project deletion reports and stops the exact number of running sidebar entries only after confirmation; and quit reports every live workspace entry, can be cancelled without effect, and relaunches confirmed entries as stopped.

## Behavior coverage

| Behavior | Unit |
|---|---|
| B1 | U2 |
| B2 | U2 |
| B3 | U3 |
| B4 | U4 |
| B5 | U3 |
| B6 | U3 |
| B7 | U3 |
| B8 | U3 |
| B9 | U4 |
| B10 | U5 |
| B11 | U6 |
| B12 | U4 |
| B13 | U1 |
| B14 | U4 |
| B15 | U4 |
| B16 | U6 |
| B17 | U3 |
| B18 | U6 |
| B19 | U6 |
| B20 | U5 |
| B21 | U5 |
| B22 | U2 |

## Risks & mitigations

- **A deselected or hidden runtime is accidentally released and its process stops.** Keep runtime ownership exclusively in the app-retained registry, test switching and window hiding with continuously producing terminals, and make view mounting a presentation concern rather than an ownership transfer.
- **AppKit restoration competes with workspace restoration and launches processes.** Make the workspace window non-restorable, decline legacy regular-window records before surface decoding, keep workspace persistence independent of `window-save-state`, and add a launch-count regression test around cold restoration.
- **A directory becomes unavailable between UI validation and process startup.** Recheck immediately before launch and use the opt-in core strict-working-directory policy so the process fails instead of inheriting or falling back to another directory.
- **Hidden runtimes disappear from callbacks, automation, bell state, or termination counts because existing lookups enumerate windows.** Register workspace surfaces at app scope and derive entry and quit state from the runtime registry while retaining existing lookup compatibility for Quick Terminal.
- **Stopping through existing close-with-undo paths retains a split tree and leaves processes alive.** Give workspace entry stop a dedicated non-undo teardown path and assert process termination before dropping the registry entry.
- **Native tab or split-extraction paths break the one-entry/one-tree model.** Route workspace new-terminal actions above `TerminalController`, suppress AppKit tab creation for workspace entries, and constrain workspace split moves to the selected entry while leaving internal split operations unchanged.
- **Persistence corruption causes data loss or an unrecoverable launch loop.** Validate before every save, atomically replace, retain one known-good backup, quarantine unreadable or unsupported input, and never overwrite preserved data during fallback.
- **Name, folder membership, and path invariants diverge between the UI and decoded data.** Use the same domain validator for mutations, load validation, migration output, and pre-save validation, with fixture and property-oriented tests for duplicate and orphaned records.

## Out of plan

- Importing legacy AppKit-restored regular windows, live shell working directories, split layouts, terminal output, or processes into project entries. There is no source-faithful mapping to the brief's explicit saved launch choices.
- Redesigning Quick Terminal restoration or lifecycle. It remains a separate feature and data path.
- Preserving split layouts after an entry is stopped or after app termination. The brief preserves entry metadata, not runtime pane state.
- Nested sidebar folders, native-tab navigation for workspace entries, multiple workspace windows, or detaching a workspace split into another window.
- Git repository or worktree awareness, coding-agent integration, command templates, cloud sync, accounts, collaboration, or GTK support.
