import Foundation

// The load grammar: parse/format the canonical weight strings GymTrak stores.
// Storage stays a plain String; this file is the one place that understands it.
//   weight     → "225 lb"
//   machine    → "10" · "120 lb" · "Max" · "Max + 10"
//   plates     → "6 pl" · "5 pl + 25"
//   bodyweight → "BW" · "+70" · "−25"
//   free       → verbatim ("wtd", "heavy")

struct StructuredLoad: Equatable {
    var type: LoadType
    var n: Double? = nil      // weight lb · machine pin · plate count
    var max: Bool = false     // machine: top of the stack
    var add: Double? = nil    // Max extra · plates extra · bodyweight added/assisted
    var lb: Bool = false      // machine: pin reading is pounds
    var text: String? = nil   // free
}

// MARK: - Regex helpers

private func matches(_ s: String, _ pattern: String, _ options: NSRegularExpression.Options = []) -> Bool {
    s.range(of: pattern, options: options.contains(.caseInsensitive) ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
}

/// Capture groups of the first match (index 0 = whole match). Missing groups are nil.
private func capture(_ s: String, _ pattern: String, caseInsensitive: Bool = false) -> [String?]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}

private func firstNum(_ s: String) -> Double? {
    capture(s, #"-?\d+(?:\.\d+)?"#)?.first.flatMap { $0 }.flatMap(Double.init)
}

/// "225", "2.5" — drops a trailing ".0" so the stored string matches the PWA's.
func fmtNum(_ n: Double) -> String {
    n == n.rounded() ? String(Int(n)) : String(n)
}

// MARK: - Grammar

/// Infer a load type from a raw string, for untyped exercises. Order matters.
func inferLoadType(_ raw: String) -> LoadType {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return .weight }
    if matches(s, #"pl\b"#, .caseInsensitive) || matches(s, #"^\d+(?:\.\d+)?\s*\+\s*\d"#) { return .plates }
    if matches(s, #"^BW\b"#, .caseInsensitive) || matches(s, #"^[+−-]\s*\d"#) { return .bodyweight }
    if matches(s, #"^Max\b"#, .caseInsensitive) { return .machine }
    if matches(s, #"^\d+(?:\.\d+)?\s*(?:lb|lbs)$"#, .caseInsensitive) { return .weight }
    if matches(s, #"^\d+(?:\.\d+)?$"#) { return .machine }
    return .free
}

/// Parse a raw weight string into structured fields, honoring an explicit type.
func parseLoad(_ raw: String, type: LoadType? = nil) -> StructuredLoad {
    let s = raw.trimmingCharacters(in: .whitespaces)
    let t = type ?? inferLoadType(s)
    switch t {
    case .weight:
        let stripped = s.replacingOccurrences(of: "lbs|lb", with: "", options: [.regularExpression, .caseInsensitive])
        return StructuredLoad(type: .weight, n: firstNum(stripped))
    case .machine:
        if matches(s, #"^Max\b"#, .caseInsensitive) {
            let add = capture(s, #"\+\s*(\d+(?:\.\d+)?)"#)?[1].flatMap(Double.init)
            return StructuredLoad(type: .machine, max: true, add: add)
        }
        return StructuredLoad(type: .machine, n: firstNum(s), lb: matches(s, #"\blbs?\b"#, .caseInsensitive))
    case .plates:
        let m = capture(s, #"(\d+(?:\.\d+)?)\s*(?:pl(?:\.|ates)?)?(?:\s*\+\s*(\d+(?:\.\d+)?))?"#, caseInsensitive: true)
        return StructuredLoad(
            type: .plates,
            n: m?[1].flatMap(Double.init),
            add: m.flatMap { $0.count > 2 ? $0[2] : nil }.flatMap(Double.init)
        )
    case .bodyweight:
        guard let m = capture(s, #"([+\-−])\s*(\d+(?:\.\d+)?)"#), let sign = m[1], let num = m[2].flatMap(Double.init) else {
            return StructuredLoad(type: .bodyweight)
        }
        return StructuredLoad(type: .bodyweight, add: (sign == "+" ? 1 : -1) * num)
    case .free:
        return StructuredLoad(type: .free, text: raw)
    }
}

/// Format structured fields back to the canonical string.
func formatLoad(_ load: StructuredLoad) -> String {
    switch load.type {
    case .weight:
        return load.n.map { "\(fmtNum($0)) lb" } ?? ""
    case .machine:
        if load.max { return load.add.map { "Max + \(fmtNum($0))" } ?? "Max" }
        guard let n = load.n else { return "" }
        return load.lb ? "\(fmtNum(n)) lb" : fmtNum(n)
    case .plates:
        guard let n = load.n else { return "" }
        return load.add.map { "\(fmtNum(n)) pl + \(fmtNum($0))" } ?? "\(fmtNum(n)) pl"
    case .bodyweight:
        guard let add = load.add, add != 0 else { return "BW" }
        return add < 0 ? "−\(fmtNum(abs(add)))" : "+\(fmtNum(add))"
    case .free:
        return load.text ?? ""
    }
}

func canonicalLoad(_ raw: String, type: LoadType? = nil) -> String {
    formatLoad(parseLoad(raw, type: type))
}

/// One tap of the live-workout stepper on a load string.
func stepLoad(_ raw: String, type: LoadType, increment: Double, direction: Int) -> String? {
    guard type != .free else { return nil }
    var p = parseLoad(raw, type: type)
    let delta = increment * Double(direction)
    if type == .weight || type == .plates || (type == .machine && !p.max) {
        p.n = Swift.max(0, (p.n ?? 0) + delta)
    } else {
        p.add = (p.add ?? 0) + delta
    }
    return formatLoad(p)
}

// MARK: - Numeric equivalents (volume)

/// A plain numeric load, or nil for Max / BW / plates / free text.
func numericLoad(_ token: String) -> Double? {
    let cleaned = token.replacingOccurrences(of: "lbs|lb", with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespaces)
    return capture(cleaned, #"^[+]?(\d+(?:\.\d+)?)$"#)?[1].flatMap(Double.init)
}

/// Leading integer of a rep token ("× 6" → 6).
func numericReps(_ token: String) -> Double? {
    capture(token, #"(\d+)"#)?[1].flatMap(Double.init)
}

/// "× 6" → "6".
func bareReps(_ reps: String) -> String {
    reps.replacingOccurrences(of: #"^\s*[×x]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespaces)
}

/// "6" → "× 6"; leaves an already-prefixed or empty value alone.
func repsToken(_ input: String) -> String {
    let bare = bareReps(input)
    return bare.isEmpty ? "" : "× \(bare)"
}

/// The grey summary line: "2 sets of 220 lb × 6", "220 lb · 210 lb × 6", or each set in full.
func exerciseSummary(_ rows: [SetRow]) -> String {
    guard let first = rows.first else { return "" }
    func load(_ r: SetRow) -> String {
        let w = r.weight.trimmingCharacters(in: .whitespaces)
        let reps = bareReps(r.reps)
        return [w, reps].filter { !$0.isEmpty }.joined(separator: " × ")
    }
    if rows.allSatisfy({ $0 == first }) {
        let l = load(first)
        let setsText = "\(rows.count) \(rows.count == 1 ? "set" : "sets")"
        return l.isEmpty ? setsText : "\(setsText) of \(l)"
    }
    let shared = bareReps(first.reps)
    if !shared.isEmpty, rows.allSatisfy({ bareReps($0.reps) == shared }) {
        return rows.map { $0.weight.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ") + " × \(shared)"
    }
    return rows.map(load).joined(separator: " · ")
}

/// Seconds → "m:ss".
func fmtClock(_ totalSec: Double) -> String {
    let s = Swift.max(0, Int(totalSec.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Plate breakdown

/// Plate sizes for the breakdown, heaviest first.
let plateSizes: [Double] = [45, 35, 25, 10, 5, 2.5]

/// Greedy split of extra plate weight, heaviest first: 40 → [35, 5].
func plateBreakdown(add: Double) -> [Double] {
    var left = add
    var out: [Double] = []
    for size in plateSizes {
        while left >= size {
            out.append(size)
            left -= size
        }
    }
    return out
}

/// "4 pl + 40" → "4 × 45 + 35 + 5". Plates only; nil for every other load type.
func plateLine(_ raw: String, type: LoadType) -> String? {
    guard type == .plates else { return nil }
    let p = parseLoad(raw, type: .plates)
    guard let n = p.n else { return nil }
    let parts = ["\(fmtNum(n)) × 45"] + plateBreakdown(add: p.add ?? 0).map(fmtNum)
    return parts.joined(separator: " + ")
}
