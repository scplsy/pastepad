/// Preserves the user's row positions until the history panel is opened again.
/// Existing recency changes never move rows; new entries arrive in recency order.
enum ClipboardPresentationOrder {
    static func merging<ID: Hashable>(_ displayed: [ID], current: [ID]) -> [ID] {
        let currentIDs = Set(current)
        let displayedIDs = Set(displayed)
        return current.filter { !displayedIDs.contains($0) }
            + displayed.filter { currentIDs.contains($0) }
    }
}
