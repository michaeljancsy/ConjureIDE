import AppKit
import SwiftUI

/// A node in the bundle file-browser tree. Built fresh each render from the
/// bundle directory on disk — there's no persistent model; the view layer
/// re-walks when the bundle changes. Cheap enough for real-world bundles
/// (tens of files, not thousands) and keeps state handling trivial.
struct BundleFileNode: Identifiable, Hashable {
    let id: String            // relative path from bundle root, stable
    let url: URL              // absolute URL on disk
    let name: String          // display name (last path component)
    let relativePath: String  // relative to bundle root
    let kind: Kind
    let children: [BundleFileNode]

    enum Kind: Hashable {
        case entryScript      // the file named in manifest.entry
        case manifest         // manifest.json
        case uiFolder         // ui/
        case folder           // any other directory
        case textFile(String) // editable text file, ext
        case binaryFile       // not editable in Monaco (image/font/wasm/…)
    }
}

/// Walker that produces the tree for a given bundle. Runs on-demand each
/// time the browser re-renders. Orders siblings: entry script first in
/// root, manifest.json second, ui/ third, then everything else
/// alphabetically.
enum BundleFileTreeBuilder {
    /// Editable text extensions — same set as BundleFilePicker so the two
    /// surfaces agree on what's editable.
    static let editableExtensions: Set<String> = BundleFilePickerEntries.editableExtensions

    static func tree(for bundle: PresetBundle) -> [BundleFileNode] {
        let root = bundle.rootURL
        return children(of: root, bundle: bundle)
    }

    private static func children(of directory: URL, bundle: PresetBundle) -> [BundleFileNode] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootPath = bundle.rootURL.standardizedFileURL.path

        var nodes: [BundleFileNode] = urls.compactMap { url -> BundleFileNode? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            let relative: String = {
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
                return String(full.dropFirst(rootPath.count + 1))
            }()
            let name = url.lastPathComponent
            if isDir.boolValue {
                let kind: BundleFileNode.Kind = (name == "ui" && directory == bundle.rootURL)
                    ? .uiFolder
                    : .folder
                let sub = children(of: url, bundle: bundle)
                return BundleFileNode(
                    id: relative, url: url, name: name,
                    relativePath: relative, kind: kind, children: sub
                )
            } else {
                let ext = url.pathExtension.lowercased()
                let kind: BundleFileNode.Kind = {
                    if relative == bundle.manifest.entry { return .entryScript }
                    if name == PresetManifest.filename { return .manifest }
                    if editableExtensions.contains(ext) { return .textFile(ext) }
                    return .binaryFile
                }()
                return BundleFileNode(
                    id: relative, url: url, name: name,
                    relativePath: relative, kind: kind, children: []
                )
            }
        }

        // Per-level ordering. At the bundle root, put entry script first,
        // manifest second, ui/ third, rest alphabetical. Inside other
        // directories, alphabetical only.
        if directory == bundle.rootURL {
            nodes.sort { (a, b) in
                func rank(_ n: BundleFileNode) -> Int {
                    switch n.kind {
                    case .entryScript: return 0
                    case .manifest:    return 1
                    case .uiFolder:    return 2
                    default:           return 3
                    }
                }
                let ra = rank(a); let rb = rank(b)
                if ra != rb { return ra < rb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } else {
            nodes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return nodes
    }
}

/// Collapsible left sidebar listing every file in the active preset bundle.
/// Tapping a text file opens it in Monaco; right-clicking exposes
/// create/rename/delete/duplicate actions. Factory bundles are read-only
/// except for "Duplicate bundle and edit this file", which forks the
/// factory into a writable user bundle and opens the equivalent file there.
struct BundleFileBrowser: View {
    let bundle: PresetBundle
    let isEditable: Bool
    let selectedRelativePath: String?
    /// Invoked when the user clicks a text file. Caller opens it in Monaco.
    var onOpen: (BundleFileNode) -> Void
    /// Invoked to create a new file in `parentRelativePath` with the given
    /// name + template. Caller writes to disk, commits, and opens in Monaco.
    var onCreateFile: (_ parentRelativePath: String, _ name: String, _ template: PresetManager.NewFileTemplate) -> Void
    /// Invoked to create a new folder.
    var onCreateFolder: (_ parentRelativePath: String, _ name: String) -> Void
    /// Invoked to rename a node.
    var onRename: (_ node: BundleFileNode, _ newName: String) -> Void
    /// Invoked to delete a node.
    var onDelete: (_ node: BundleFileNode) -> Void
    /// Invoked to duplicate a file node.
    var onDuplicate: (_ node: BundleFileNode) -> Void
    /// Invoked only for factory bundles — forks the bundle and opens the
    /// equivalent file in the new copy.
    var onDuplicateBundleAndEdit: (_ node: BundleFileNode) -> Void

    @State private var expanded: Set<String> = []
    @State private var showingNewFilePopover: Bool = false
    @State private var newFileParent: String = ""
    @State private var newFileName: String = ""
    @State private var newFileIsFolder: Bool = false
    @State private var showingRenamePopover: Bool = false
    @State private var renameNode: BundleFileNode? = nil
    @State private var renameInput: String = ""
    @State private var showingDeleteConfirm: Bool = false
    @State private var deleteNode: BundleFileNode? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(flattenedVisibleRows(), id: \.node.id) { entry in
                        row(entry.node, depth: entry.depth)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .popover(isPresented: $showingNewFilePopover) {
            NewBundleEntryPopover(
                isFolder: newFileIsFolder,
                parent: newFileParent,
                name: $newFileName,
                onConfirm: {
                    let trimmed = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if newFileIsFolder {
                        onCreateFolder(newFileParent, trimmed)
                    } else {
                        let template = PresetManager.NewFileTemplate.match(forFilename: trimmed)
                        onCreateFile(newFileParent, trimmed, template)
                    }
                    newFileName = ""
                    showingNewFilePopover = false
                },
                onCancel: {
                    newFileName = ""
                    showingNewFilePopover = false
                }
            )
        }
        .popover(isPresented: $showingRenamePopover) {
            if let node = renameNode {
                RenameEntryPopover(
                    currentName: node.name,
                    newName: $renameInput,
                    onConfirm: {
                        let trimmed = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != node.name else {
                            showingRenamePopover = false
                            return
                        }
                        onRename(node, trimmed)
                        showingRenamePopover = false
                    },
                    onCancel: { showingRenamePopover = false }
                )
            }
        }
        .confirmationDialog(
            deleteNode.map { "Delete \($0.relativePath)?" } ?? "Delete?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let node = deleteNode { onDelete(node) }
                deleteNode = nil
            }
            Button("Cancel", role: .cancel) { deleteNode = nil }
        } message: {
            Text("This can't be undone (but the file will remain in git history).")
        }
    }

    private var header: some View {
        HStack {
            Text("Files")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Spacer()
            if isEditable {
                Button(action: {
                    newFileParent = ""
                    newFileName = ""
                    newFileIsFolder = false
                    showingNewFilePopover = true
                }) {
                    Image(systemName: "plus")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("New file at bundle root")
                .accessibilityIdentifier("bundleFileBrowserAddButton")
            } else {
                Image(systemName: "lock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Factory bundles are read-only. Right-click a file to fork the bundle and edit it.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Walk the tree DFS-wise, producing a flat list of visible rows with
    /// their depth. Recursion lives here (in a concrete-typed function),
    /// not in the @ViewBuilder body where the opaque return type can't
    /// reference itself.
    private struct VisibleRow {
        let node: BundleFileNode
        let depth: Int
    }

    private func flattenedVisibleRows() -> [VisibleRow] {
        var out: [VisibleRow] = []
        let roots = BundleFileTreeBuilder.tree(for: bundle)
        func visit(_ node: BundleFileNode, depth: Int) {
            out.append(VisibleRow(node: node, depth: depth))
            let hasKids = !node.children.isEmpty
            if hasKids && expanded.contains(node.id) {
                for child in node.children {
                    visit(child, depth: depth + 1)
                }
            }
        }
        for n in roots { visit(n, depth: 0) }
        return out
    }

    @ViewBuilder
    private func row(_ node: BundleFileNode, depth: Int) -> some View {
        let isSelected = node.relativePath == selectedRelativePath
        // Align triangle visibility with the DFS traversal in
        // `flattenedVisibleRows`, which only emits children when
        // `children.isEmpty == false`. Previously we'd show a triangle
        // for every folder — including empty ones — so tapping it
        // flipped the chevron state without revealing anything.
        let hasChildren = !node.children.isEmpty

        HStack(spacing: 4) {
            // Indent
            Color.clear.frame(width: CGFloat(depth) * 10, height: 1)

            if hasChildren {
                Button(action: { toggleExpanded(node.id) }) {
                    Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 10)
            }

            Image(systemName: icon(for: node))
                .font(.caption)
                .foregroundStyle(iconColor(for: node))
                .frame(width: 14)

            Text(node.name)
                .font(.system(size: 11, weight: node.kind == .entryScript ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            switch node.kind {
            case .folder, .uiFolder:
                toggleExpanded(node.id)
            case .binaryFile:
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            default:
                onOpen(node)
            }
        }
        .contextMenu {
            contextMenu(for: node)
        }
        .accessibilityIdentifier("bundleFileRow_\(node.relativePath)")
    }

    @ViewBuilder
    private func contextMenu(for node: BundleFileNode) -> some View {
        Button("Open") {
            if case .binaryFile = node.kind {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            } else if node.kind == .folder || node.kind == .uiFolder {
                toggleExpanded(node.id)
            } else {
                onOpen(node)
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }

        Divider()

        if isEditable {
            if node.kind == .folder || node.kind == .uiFolder {
                Button("New File…") {
                    newFileParent = node.relativePath
                    newFileName = ""
                    newFileIsFolder = false
                    showingNewFilePopover = true
                }
                Button("New Folder…") {
                    newFileParent = node.relativePath
                    newFileName = ""
                    newFileIsFolder = true
                    showingNewFilePopover = true
                }
            } else {
                Button("Duplicate") { onDuplicate(node) }
            }

            Button("Rename…") {
                renameNode = node
                renameInput = node.name
                showingRenamePopover = true
            }
            .disabled(node.kind == .entryScript || node.kind == .manifest)

            Button("Delete", role: .destructive) {
                deleteNode = node
                showingDeleteConfirm = true
            }
            .disabled(node.kind == .entryScript || node.kind == .manifest)
        } else {
            // Factory bundle: the one destructive-ish action we DO allow
            // is forking the bundle and jumping into the equivalent file
            // in the copy. Everything else is greyed out.
            if case .textFile = node.kind {
                Button("Duplicate bundle and edit this file") {
                    onDuplicateBundleAndEdit(node)
                }
            } else if node.kind == .entryScript || node.kind == .manifest {
                Button("Duplicate bundle and edit this file") {
                    onDuplicateBundleAndEdit(node)
                }
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func icon(for node: BundleFileNode) -> String {
        switch node.kind {
        case .entryScript: return "chevron.right.square"
        case .manifest:    return "hammer"
        case .uiFolder:    return "paintpalette"
        case .folder:      return "folder"
        case .binaryFile:  return "photo"
        case .textFile(let ext):
            switch ext {
            case "html", "htm":      return "doc.richtext"
            case "css":              return "paintbrush"
            case "js", "mjs", "json": return "curlybraces"
            case "md", "txt":        return "doc.text"
            case "svg":              return "square.and.pencil"
            default:                 return "doc"
            }
        }
    }

    private func iconColor(for node: BundleFileNode) -> Color {
        switch node.kind {
        case .entryScript: return .accentColor
        case .uiFolder:    return .accentColor
        default:           return .secondary
        }
    }
}

// MARK: - New file / folder popover

private struct NewBundleEntryPopover: View {
    let isFolder: Bool
    let parent: String
    @Binding var name: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isFolder ? "New Folder" : "New File")
                .font(.headline)
            if !parent.isEmpty {
                Text("in \(parent)/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(isFolder ? "folder-name" : "filename.ext", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .onSubmit { onConfirm() }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isFolder ? "Create Folder" : "Create") {
                    onConfirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }
}

// MARK: - Rename popover

private struct RenameEntryPopover: View {
    let currentName: String
    @Binding var newName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename")
                .font(.headline)
            TextField(currentName, text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .onSubmit { onConfirm() }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newName == currentName)
            }
        }
        .padding()
    }
}
