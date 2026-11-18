/// Groups a file's diff rows into chunks for the diff's lazy stack.
///
/// The lazy stack walks every item before the visible one when it places rows, and before
/// the target when it scrolls to an id. With one item per diff line those walks grow with
/// the size of the whole diff; with one item per chunk they're `size` times shorter.
public enum RowChunks {
    public static func ranges(count: Int, size: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    }
}

/// Decides when a jump to a file has landed, so it stops being re-issued.
public enum ScrollSettle {
    /// - Parameters:
    ///   - top: the y of the target file's first row in the viewport, `nil` while it isn't built.
    ///   - previousTop: the same, when last checked.
    /// - Returns: whether the target is at the top of the viewport, or has stopped moving
    ///   short of it (the last files of a diff can't scroll all the way up).
    public static func isSettled(top: Double?, previousTop: Double?) -> Bool {
        guard let top else { return false }
        if abs(top) < 1 { return true }
        guard let previousTop else { return false }
        return abs(top - previousTop) < 1
    }
}
