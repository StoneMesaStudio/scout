import Foundation

/// A page of results plus how many there were altogether.
///
/// The total matters as much as the results: "6 of 2,367" tells you the search worked and there is
/// more to see, where a bare six looks like all there is.
public struct SearchPage<Item: Sendable>: Sendable {

    public let items: [Item]
    public let total: Int

    public init(items: [Item], total: Int) {
        self.items = items
        self.total = total
    }

    public static var empty: SearchPage<Item> { SearchPage(items: [], total: 0) }

    public var hiddenCount: Int { max(0, total - items.count) }
}
