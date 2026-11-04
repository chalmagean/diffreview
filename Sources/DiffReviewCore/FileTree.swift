/// One row of the sidebar's folder tree.
public enum FileTreeNode: Equatable, Hashable, Identifiable, Sendable {
    /// `name` may span several folders ("lib/active_record") when the ones above held nothing else.
    case directory(name: String, path: String, children: [FileTreeNode])
    /// `index` is the file's position in the paths the tree was built from.
    case file(name: String, path: String, index: Int)

    public var name: String {
        switch self {
        case .directory(let name, _, _), .file(let name, _, _): return name
        }
    }

    public var path: String {
        switch self {
        case .directory(_, let path, _), .file(_, let path, _): return path
        }
    }

    public var children: [FileTreeNode]? {
        if case .directory(_, _, let children) = self { return children }
        return nil
    }

    public var id: String {
        switch self {
        case .directory(_, let path, _): return "d:" + path
        case .file(_, let path, _): return "f:" + path
        }
    }
}

public enum FileTree {
    /// Builds a GitHub-style tree from file paths. Entries keep the order they first appear
    /// in (the diff's order), and a folder whose only entry is another folder is joined with it.
    public static func build(paths: [String]) -> [FileTreeNode] {
        let root = Folder()
        for (index, path) in paths.enumerated() {
            var folder = root
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let fileName = parts.last else { continue }
            for part in parts.dropLast() { folder = folder.subfolder(part) }
            folder.entries.append(.file(fileName, index))
        }
        return root.nodes(prefix: "")
    }

    private final class Folder {
        enum Entry {
            case folder(String, Folder)
            case file(String, Int)
        }
        var entries: [Entry] = []

        func subfolder(_ name: String) -> Folder {
            for case .folder(let existing, let folder) in entries where existing == name { return folder }
            let folder = Folder()
            entries.append(.folder(name, folder))
            return folder
        }

        func nodes(prefix: String) -> [FileTreeNode] {
            entries.map { entry in
                switch entry {
                case .file(let name, let index):
                    return .file(name: name, path: prefix + name, index: index)
                case .folder(var name, var folder):
                    // Join chains of folders that hold nothing but one folder.
                    while folder.entries.count == 1, case .folder(let childName, let child) = folder.entries[0] {
                        name += "/" + childName
                        folder = child
                    }
                    let path = prefix + name
                    return .directory(name: name, path: path, children: folder.nodes(prefix: path + "/"))
                }
            }
        }
    }
}
