import Foundation

/// Compare two dotted version strings (e.g. "0.1.10" vs "0.1.9"). Tolerant of a
/// leading "v" and of pre-release suffixes (compares the numeric x.y.z only).
public func isVersion(_ a: String, newerThan b: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        let core = s.drop(while: { $0 == "v" || $0 == "V" })
        return core.split(separator: ".").prefix(3).map { seg in
            Int(seg.prefix(while: { $0.isNumber })) ?? 0
        }
    }
    let x = parts(a), y = parts(b)
    for i in 0..<3 {
        let xi = i < x.count ? x[i] : 0
        let yi = i < y.count ? y[i] : 0
        if xi != yi { return xi > yi }
    }
    return false
}
