import CZxcvbn
import Foundation
import Synchronization

/// How hard a password is to guess offline (3.5, docs/STUDIO_XIZ_ATTACCHI.md): zxcvbn's estimate
/// of the guesses an attacker with dictionaries and rules needs, not length times alphabet.
public struct PasswordStrength: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case weak = 1, fair, good, excellent
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// log2 of the guesses needed.
    public var bits: Double
    public var level: Level
    /// Seconds to find it on average against an encrypted XIZ (Argon2id 256 MiB, t=3) with
    /// 1000 high-end GPUs, about 500 guesses per second each (an estimate from memory bandwidth).
    public var crackSeconds: Double

    /// Below this, a XIZ protected by a password alone asks for an explicit confirmation.
    public static let minimumBits = 45.0
    static let guessesPerSecond = 5e5

    public var isWeak: Bool { bits < Self.minimumBits }

    /// The estimate for `password`; `userWords` are guessable words of this context (the archive's
    /// name, the user's name), weighed like dictionary words.
    public static func estimate(_ password: String, userWords: [String] = []) -> PasswordStrength {
        guard !password.isEmpty else { return PasswordStrength(bits: 0, level: .weak, crackSeconds: 0) }
        // zxcvbn knows single-byte text: estimate the NFC form and the form without diacritics
        // ("pässwörd" is "passwoerd"/"password" to an attacker) and keep the weaker.
        let nfc = password.precomposedStringWithCanonicalMapping
        let folded = nfc.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var bits = zxcvbn(nfc, userWords)
        if folded != nfc { bits = min(bits, zxcvbn(folded, userWords)) }
        let level: Level = bits < minimumBits ? .weak : bits < 60 ? .fair : bits < 77 ? .good : .excellent
        return PasswordStrength(bits: bits, level: level, crackSeconds: pow(2, bits - 1) / guessesPerSecond)
    }

    private static func zxcvbn(_ s: String, _ words: [String]) -> Double {
        let dict = words.filter { !$0.isEmpty }.map { strdup($0.lowercased()) }
        defer { dict.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = dict.map { UnsafePointer($0) } + [nil]
        return s.withCString { p in
            ptrs.withUnsafeMutableBufferPointer { ZxcvbnMatch(p, words.isEmpty ? nil : $0.baseAddress, nil) }
        }
    }
}

/// Diceware passphrases (3.5): words drawn uniformly with the system's secure generator from the
/// EFF large word list (English) or Tarin Gamberini's Italian list, 7776 words each (12.9 bits per
/// word: 6 words are 77 bits). The lists are data files next to the program (GPL-3.0 for the
/// Italian one, kept out of the binary), found in the app's Resources/Wordlists or in Vendor/.
public enum Passphrase {
    public enum Language: String, Sendable, CaseIterable {
        case english = "en", italian = "it"

        var fileName: String { self == .english ? "eff_large_wordlist" : "word_list_diceware_it-IT-4" }

        /// Italian when the user's first preferred language is Italian.
        public static var preferred: Language {
            (Locale.preferredLanguages.first ?? "en").hasPrefix("it") ? .italian : .english
        }
    }

    public static let defaultWords = 6

    /// A passphrase of `words` words joined by `separator`, or nil when the list is not installed.
    public static func generate(words: Int = defaultWords, language: Language = .preferred, separator: String = "-") -> String? {
        guard let list = wordList(language), list.count == 7776 else { return nil }
        var rng = SystemRandomNumberGenerator()
        return (0..<max(1, words)).map { _ in list[Int.random(in: 0..<list.count, using: &rng)] }.joined(separator: separator)
    }

    /// Bits of a passphrase of `words` words.
    public static func bits(words: Int) -> Double { Double(words) * log2(7776) }

    private static let cache = Mutex<[Language: [String]]>([:])

    /// The 7776 words of the list (the `11111 word` lines; headers and licence text skipped).
    public static func wordList(_ language: Language) -> [String]? {
        if let hit = cache.withLock({ $0[language] }) { return hit }
        for dir in searchDirectories() {
            let url = dir.appendingPathComponent(language.fileName + ".txt")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var words: [String] = []
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 2, parts[0].count == 5, parts[0].allSatisfy({ ("1"..."6").contains($0) }) else { continue }
                words.append(String(parts[1]))
            }
            guard words.count == 7776 else { continue }
            cache.withLock { $0[language] = words }
            return words
        }
        return nil
    }

    static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["XIPPER_WORDLISTS"] { dirs.append(URL(fileURLWithPath: env)) }
        if let r = Bundle.main.resourceURL { dirs += [r.appendingPathComponent("Wordlists"), r] }
        // The command-line tool inside the app: Contents/Helpers/xipper → Contents/Resources.
        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let resources = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        dirs += [resources.appendingPathComponent("Wordlists"), resources]
        // A development build: the repository's Vendor/wordlists.
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/wordlists"))
        return dirs
    }
}
