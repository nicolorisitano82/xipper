import Foundation

/// Names made to look like something else: right-to-left override characters that reverse the
/// visible end of a name ("fattura" + U+202E + "fdp.app" shows as "fatturappa.pdf"), a document extension in
/// front of an executable one ("fattura.pdf.app", with the real one hidden by the Finder), or
/// spaces pushing the real extension out of sight. Extraction still works; Xipper warns.
public enum DeceptiveName {
    public enum Reason: Sendable, Equatable {
        /// Bidirectional control characters (U+202A–202E, U+2066–2069, U+200E/F, U+061C).
        case bidiControl
        /// "x.pdf.app": `shown` is what the name pretends to be, `real` what it is.
        case doubleExtension(shown: String, real: String)
        /// "x.pdf            .app": runs of spaces before an executable extension.
        case paddedExtension(real: String)
    }

    static let bidi: Set<Unicode.Scalar> = Set((0x202A...0x202E).compactMap(Unicode.Scalar.init)
        + (0x2066...0x2069).compactMap(Unicode.Scalar.init) + [0x200E, 0x200F, 0x061C].compactMap(Unicode.Scalar.init))

    /// Extensions that run something when opened, on macOS or on the Windows and Linux machines the
    /// files may travel to.
    static let executable: Set<String> = [
        "app", "command", "tool", "sh", "zsh", "bash", "csh", "pkg", "mpkg", "scpt", "scptd", "applescript",
        "workflow", "action", "terminal", "jar", "webloc", "inetloc", "fileloc",
        "exe", "bat", "cmd", "com", "scr", "msi", "ps1", "vbs", "vbe", "js", "jse", "wsf", "hta", "lnk", "url", "pif", "cpl",
    ]
    /// Extensions people trust: documents, pictures, media, archives.
    static let document: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "rtf", "txt", "csv", "pages", "numbers", "key",
        "jpg", "jpeg", "png", "gif", "heic", "tif", "tiff", "bmp", "svg", "mp3", "m4a", "wav", "mp4", "mov", "avi",
        "zip", "rar", "7z", "html", "htm", "eml",
    ]

    /// Why the last component of `name` is deceptive, or nil.
    public static func check(_ name: String) -> Reason? {
        if name.unicodeScalars.contains(where: bidi.contains) { return .bidiControl }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 || (parts.count == 2 && parts[0].hasSuffix("   ")) else { return nil }
        let real = parts.last!.lowercased()
        guard executable.contains(real) else { return nil }
        let before = parts[parts.count - 2]
        if before.hasSuffix("   ") || before.contains("\u{3000}") { return .paddedExtension(real: real) }
        let shown = before.trimmingCharacters(in: .whitespaces).lowercased()
        if parts.count >= 3, document.contains(shown) { return .doubleExtension(shown: shown, real: real) }
        return nil
    }

    /// The first deceptive component of a "/"-separated path, with its reason.
    public static func check(path: String) -> (component: String, reason: Reason)? {
        for c in path.split(separator: "/") { if let r = check(String(c)) { return (String(c), r) } }
        return nil
    }

    /// `name` with the invisible controls spelled out ("fattura⟨U+202E⟩fdp.app") and runs of more
    /// than three spaces shortened to "␣…␣", for showing what a name really is.
    public static func visible(_ name: String) -> String {
        var out = ""
        var spaces = 0
        func flush() {
            out += spaces > 3 ? "␣…␣" : String(repeating: " ", count: spaces)
            spaces = 0
        }
        for s in name.unicodeScalars {
            if s == " " { spaces += 1; continue }
            flush()
            if bidi.contains(s) { out += String(format: "⟨U+%04X⟩", s.value) } else { out.unicodeScalars.append(s) }
        }
        flush()
        return out
    }
}
