import Foundation

/// A shape protocol.
protocol Shape { var area: Double { get } }

@MainActor
final class Circle: Shape, CustomStringConvertible {
    let radius: Double
    private(set) var tag: String? = nil
    init(radius: Double) { self.radius = radius }
    var area: Double { .pi * radius * radius }
    var description: String { "Circle(\(radius))" }
}

enum Direction: String { case north = "N", south }

func compute<T: Numeric>(_ values: [T], scale factor: T = 1) async throws -> T {
    guard !values.isEmpty else { throw NSError(domain: "x", code: 1) }
    return values.reduce(0, +) * factor
}
let c = Circle(radius: 2.5); print(c, true, nil as Int?)
