func outer(_ value: Int, label other: String) -> String {
    let local = value * 2
    var copy = local
    copy += 1
    return "\(other): \(copy)"
}
struct S<T> where T: Equatable { var item: T; static let shared = 0 }
