import Foundation

/// Precomputed match keys for one app (F-05): names in any language plus
/// pinyin, pinyin initials, zhuyin initials and zhuyin keyboard keys.
public struct SearchKeys: Hashable, Sendable {
    /// Matched anywhere (substring).
    public let names: [String]
    /// Matched as a prefix: full pinyin, initials, zhuyin.
    public let phonetic: [String]

    public init(names rawNames: [String]) {
        var names: [String] = []
        var phonetic: [String] = []
        for raw in rawNames {
            let folded = SearchKeys.fold(raw)
            if !folded.isEmpty, !names.contains(folded) { names.append(folded) }

            let syllables = SearchKeys.syllables(raw)
            guard !syllables.isEmpty else { continue }
            let initials = String(syllables.compactMap(\.first))
            let full = syllables.joined()
            for key in [initials, full] where key.count > 1 && !phonetic.contains(key) && !names.contains(key) {
                phonetic.append(key)
            }
            if raw.unicodeScalars.contains(where: SearchKeys.isHan) {
                let zhuyin = String(syllables.compactMap(Zhuyin.initial))
                let keys = String(zhuyin.compactMap { Zhuyin.keyboard[$0] })
                for key in [zhuyin, keys] where !key.isEmpty && !phonetic.contains(key) {
                    phonetic.append(key)
                }
            }
        }
        self.names = names
        self.phonetic = phonetic
    }

    /// Lower score is a better match; nil means no match.
    public func score(_ query: String) -> Int? {
        let q = SearchKeys.fold(query)
        guard !q.isEmpty else { return nil }
        if names.contains(where: { $0.hasPrefix(q) }) { return 0 }
        if phonetic.contains(where: { $0.hasPrefix(q) }) { return 1 }
        if names.contains(where: { $0.contains(q) }) { return 2 }
        return nil
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "")
    }

    static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }

    /// Splits a name into romanized syllables/words: "音樂" → ["yin", "le"], "Final Cut" → ["final", "cut"].
    static func syllables(_ s: String) -> [String] {
        let latin = (s.applyingTransform(.mandarinToLatin, reverse: false) ?? s)
            .applyingTransform(.stripDiacritics, reverse: false) ?? s
        return latin.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

public enum Search {
    public static func filter(_ apps: [AppInfo], query: String) -> [AppInfo] {
        var scored: [(app: AppInfo, score: Int)] = []
        for app in apps {
            if let s = app.search.score(query) { scored.append((app, s)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.app.name.localizedStandardCompare(b.app.name) == .orderedAscending
        }
        return scored.map(\.app)
    }
}

enum Zhuyin {
    /// First bopomofo symbol of a pinyin syllable.
    static func initial(_ syllable: String) -> Character? {
        let s = syllable.lowercased()
        let two: [String: Character] = ["zh": "ㄓ", "ch": "ㄔ", "sh": "ㄕ"]
        if let c = two[String(s.prefix(2))] { return c }
        let consonants: [Character: Character] = [
            "b": "ㄅ", "p": "ㄆ", "m": "ㄇ", "f": "ㄈ", "d": "ㄉ", "t": "ㄊ", "n": "ㄋ", "l": "ㄌ",
            "g": "ㄍ", "k": "ㄎ", "h": "ㄏ", "j": "ㄐ", "q": "ㄑ", "x": "ㄒ", "r": "ㄖ", "z": "ㄗ",
            "c": "ㄘ", "s": "ㄙ",
        ]
        guard let first = s.first else { return nil }
        if let c = consonants[first] { return c }
        if first == "y" { return s.hasPrefix("yu") || s.hasPrefix("yong") ? "ㄩ" : "ㄧ" }
        if first == "w" { return "ㄨ" }
        let finals: [(String, Character)] = [
            ("er", "ㄦ"), ("ang", "ㄤ"), ("eng", "ㄥ"), ("ai", "ㄞ"), ("ei", "ㄟ"), ("ao", "ㄠ"),
            ("ou", "ㄡ"), ("an", "ㄢ"), ("en", "ㄣ"), ("a", "ㄚ"), ("o", "ㄛ"), ("e", "ㄜ"),
        ]
        return finals.first { s.hasPrefix($0.0) }?.1
    }

    /// Standard (大千) zhuyin keyboard layout, for typing zhuyin with the ABC input source.
    static let keyboard: [Character: Character] = [
        "ㄅ": "1", "ㄆ": "q", "ㄇ": "a", "ㄈ": "z", "ㄉ": "2", "ㄊ": "w", "ㄋ": "s", "ㄌ": "x",
        "ㄍ": "e", "ㄎ": "d", "ㄏ": "c", "ㄐ": "r", "ㄑ": "f", "ㄒ": "v", "ㄓ": "5", "ㄔ": "t",
        "ㄕ": "g", "ㄖ": "b", "ㄗ": "y", "ㄘ": "h", "ㄙ": "n", "ㄧ": "u", "ㄨ": "j", "ㄩ": "m",
        "ㄚ": "8", "ㄛ": "i", "ㄜ": "k", "ㄞ": "9", "ㄟ": "o", "ㄠ": "l", "ㄡ": ".", "ㄢ": "0",
        "ㄣ": "p", "ㄤ": ";", "ㄥ": "/", "ㄦ": "-",
    ]
}
