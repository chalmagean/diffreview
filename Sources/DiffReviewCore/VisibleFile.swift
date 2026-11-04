/// Works out which file the diff is scrolled to, for highlighting it in the sidebar.
public enum VisibleFile {
    /// - Parameters:
    ///   - tops: file id → the y of that file's first row, relative to the top of the viewport,
    ///     for the files whose first row is currently built. Ids follow display order.
    ///   - threshold: how far down the viewport a file's top must reach to become current
    ///     (just under the pinned file header).
    /// - Returns: the last file whose top has reached the threshold; if none has, the file before
    ///   the first tracked one, whose top row has scrolled away while its lines fill the view.
    public static func current(tops: [Int: Double], threshold: Double) -> Int? {
        guard let first = tops.keys.min() else { return nil }
        if let reached = tops.filter({ $0.value <= threshold }).keys.max() { return reached }
        return max(first - 1, 0)
    }
}
