import Foundation

/// A small inventory model: enough declarations to show the symbol sidebar.
public struct Item: Codable, Hashable {
    public let id: UUID
    public var name: String
    public var quantity: Int
    public var price: Decimal

    public init(name: String, quantity: Int = 0, price: Decimal = 0) {
        self.id = UUID()
        self.name = name
        self.quantity = quantity
        self.price = price
    }

    public var total: Decimal { price * Decimal(quantity) }
}

public enum InventoryError: Error, CustomStringConvertible {
    case notFound(UUID)
    case insufficientStock(requested: Int, available: Int)

    public var description: String {
        switch self {
        case .notFound(let id): "No item \(id)"
        case let .insufficientStock(requested, available): "Wanted \(requested), have \(available)"
        }
    }
}

public final class Inventory {
    private var items: [UUID: Item] = [:]

    public func add(_ item: Item) {
        items[item.id] = item
    }

    public func remove(_ id: UUID, count: Int) throws {
        guard var item = items[id] else { throw InventoryError.notFound(id) }
        guard item.quantity >= count else {
            throw InventoryError.insufficientStock(requested: count, available: item.quantity)
        }
        item.quantity -= count
        items[id] = item
    }

    public var value: Decimal {
        items.values.reduce(0) { $0 + $1.total }
    }

    public func lowStock(below threshold: Int = 5) -> [Item] {
        items.values.filter { $0.quantity < threshold }.sorted { $0.name < $1.name }
    }
}

extension Inventory: CustomStringConvertible {
    public var description: String {
        let lines = items.values.map { "\($0.name): \($0.quantity) @ \($0.price)" }
        return lines.sorted().joined(separator: "\n")
    }
}

func demo() async throws {
    let inventory = Inventory()
    inventory.add(Item(name: "Widget", quantity: 12, price: 2.50))
    inventory.add(Item(name: "Gadget", quantity: 3, price: 19.99))
    print(inventory.value, inventory.lowStock().map(\.name))
    let raw = #"Raw strings keep \n as typed"#
    print(raw, 0x1F, 1_000_000, 3.14e-2)
}
