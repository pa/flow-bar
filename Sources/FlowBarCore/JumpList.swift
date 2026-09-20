import Foundation

/// A short, ordered list of tasks you jump to by number — Harpoon's idea,
/// applied to work instead of files.
///
/// **Why this and not "recent".** A recents list reorders itself every time you
/// use it, so the position of a thing is never the same twice and you have to
/// read the list before you can act on it. A jump list is *placed by you and
/// stays put*: `⌘2` is the same task tomorrow, which is what makes it a reflex
/// rather than a lookup. That stability is the entire feature, so nothing here
/// ever reorders the list on its own.
///
/// Capped at nine because the keys run out — and because a jump list you have
/// to search is just the search you already had.
public struct JumpList: Equatable, Sendable, Codable {
    public static let capacity = 9

    public private(set) var slugs: [String]

    public init(_ slugs: [String] = []) {
        // Defensive: a persisted list can carry duplicates or overflow if it was
        // written by an older build or edited by hand.
        var seen = Set<String>()
        self.slugs = Array(slugs.filter { seen.insert($0).inserted }.prefix(Self.capacity))
    }

    public var isEmpty: Bool { slugs.isEmpty }
    public var isFull: Bool { slugs.count >= Self.capacity }
    public func contains(_ slug: String) -> Bool { slugs.contains(slug) }

    /// Its 1-based place, which is the key you press.
    public func number(of slug: String) -> Int? {
        slugs.firstIndex(of: slug).map { $0 + 1 }
    }

    /// The task at a 1-based position, or nil.
    public func slug(at number: Int) -> String? {
        let i = number - 1
        return slugs.indices.contains(i) ? slugs[i] : nil
    }

    /// What a toggle did, so the UI can say so.
    public enum Change: Equatable, Sendable {
        case added(Int)     // the number it was given
        case removed
        case full
    }

    /// Pin or unpin. New pins go on the end and keep their number for good.
    ///
    /// Unpinning renumbers everything after it, which is unavoidable — the
    /// alternative is holes in the list, and a `⌘4` that does nothing is worse
    /// than a `⌘4` that moved.
    @discardableResult
    public mutating func toggle(_ slug: String) -> Change {
        if let i = slugs.firstIndex(of: slug) {
            slugs.remove(at: i)
            return .removed
        }
        guard !isFull else { return .full }
        slugs.append(slug)
        return .added(slugs.count)
    }

    public mutating func remove(_ slug: String) {
        slugs.removeAll { $0 == slug }
    }

    /// Drop anything that no longer exists.
    ///
    /// A pinned task can be deleted or archived out from under the list, and a
    /// number that opens nothing is worse than one fewer number.
    public func pruned(to existing: Set<String>) -> JumpList {
        JumpList(slugs.filter { existing.contains($0) })
    }
}
