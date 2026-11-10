import CoreGraphics
import CoreText
import Foundation

/// The printable report (docs/XIPPER_FORENSIC.md §4.7): an A4 PDF rendered from the JSON report
/// (`ForensicReport.build`), in Italian or English, for the written record. Every page carries the
/// case number, the archive's SHA-256 and "page n of N", so a page out of its bundle still says
/// what it belongs to. CoreText only: the CLI renders it too, without AppKit.
public enum ForensicPDF {
    public enum Language: String, Sendable, CaseIterable { case it, en }

    /// Renders `report` (a `ForensicReport.build` object).
    public static func render(_ report: [String: Any], language: Language = .it) -> Data {
        let t = Text(language)
        let s = Builder()
        let passed = report["passed"] as? Bool ?? false
        let checks = report["checks"] as? [[String: String]] ?? []
        let unreadable = report["unreadable"] as? [[String: Any]] ?? []
        let sources = report["source_hashes"] as? [[String: Any]] ?? []
        let archive = report["archive"] as? [String: Any] ?? [:]
        let caseInfo = (report["case"] as? [String: String] ?? [:]).filter { $0.key != "segment" }

        s.title(t["title"])
        s.line(t["generated"] + " " + time(report["generated"] as? String, language) + " · " + "xipper-forensic "
               + (report["tool_version"] as? String ?? ""), style: .small)
        s.space()

        // Outcome: three states, never one ambiguous "OK" (§4.3).
        let failed = !passed
        let warned = checks.contains { $0["status"] == "warning" } || !unreadable.isEmpty
        s.outcome(failed ? t["outcome.failed"] : warned ? t["outcome.warning"] : t["outcome.passed"],
                  color: failed ? .red : warned ? .orange : .green)
        for c in checks {
            let mark = switch c["status"] { case "passed": "✔"; case "warning": "⚠"; case "failed": "✖"; default: "–" }
            s.check(mark, t.check(c["name"] ?? ""), c["detail"] ?? "")
        }

        s.heading(t["section.case"])
        for (k, v) in ordered(caseInfo, first: ["case_number", "evidence_number", "title", "proceeding", "court", "examiner",
                                                 "organization", "location", "description", "notes"]) {
            s.field(t.field(k), v)
        }

        let devices = report["devices"] as? [[String: String]] ?? []
        if !devices.isEmpty {
            s.heading(t["section.device"])
            for (i, d) in devices.enumerated() {
                if i > 0 { s.space() }
                for (k, v) in ordered(d.filter { $0.key != "segment" }, first: ["model", "serial", "interface", "write_blocker", "path"]) {
                    s.field(t.field(k), v)
                }
            }
        }

        let acquisitions = report["acquisitions"] as? [[String: String]] ?? []
        if !acquisitions.isEmpty {
            s.heading(t["section.acquisition"])
            for (i, a) in acquisitions.enumerated() {
                if i > 0 { s.space() }
                for (k, v) in ordered(a.filter { $0.key != "segment" }, first: ["method", "sources", "started", "finished", "source_size",
                                                                               "files", "bytes", "skipped", "tool", "tool_version", "os"]) {
                    let hash = k.hasSuffix("sha256")
                    s.field(t.field(k), k == "method" ? t.method(v) : k == "started" || k == "finished" ? time(v, language) : v, mono: hash)
                }
            }
        }

        if !sources.isEmpty {
            s.heading(t["section.hashes"])
            for (i, h) in sources.enumerated() {
                if i > 0 { s.space() }
                s.field(t.field("path"), h["path"] as? String ?? "")
                s.field(t.field("size"), bytes(h["size"], language))
                s.field(t.field("started"), time(h["started"] as? String, language))
                s.field(t.field("finished"), time(h["finished"] as? String, language))
                s.field("SHA-256", h["sha256"] as? String ?? "", mono: true)
                if let m = h["md5"] as? String { s.field("MD5", m, mono: true) }
                if let m = h["sha1"] as? String { s.field("SHA-1", m, mono: true) }
            }
        }

        if !unreadable.isEmpty {
            s.heading(t["section.unreadable"])
            for u in unreadable {
                s.field(t.field("path"), u["path"] as? String ?? "")
                s.field(t.field("bytes"), bytes(u["bytes"], language))
                for r in (u["ranges"] as? [[String: Any]] ?? []).prefix(200) {
                    s.line("  offset \(r["offset"] ?? 0)  +\(r["length"] ?? 0)  errno \(r["error"] ?? 0)  ×\(r["attempts"] ?? 0)", style: .mono)
                }
            }
        }

        s.heading(t["section.archive"])
        s.field(t.field("name"), archive["name"] as? String ?? "")
        s.field(t.field("size"), bytes(archive["bytes"], language))
        s.field("SHA-256", archive["sha256"] as? String ?? "", mono: true)
        s.line(t["archive.note"], style: .small)

        let segments = report["segments"] as? [[String: Any]] ?? []
        if !segments.isEmpty {
            s.heading(t["section.signatures"])
            for g in segments {
                let ok = (g["signature_valid"] as? Bool ?? false) && (g["chain_ok"] as? Bool ?? false)
                var line = "\(ok ? "✔" : "✖") " + t["segment"] + " \(g["segment"] ?? "")"
                if let w = g["time"] as? String { line += " · " + time(w, language) }
                line += " · " + (g["signer"] as? String ?? "")
                s.line(line)
                s.line("  " + (g["key"] as? String ?? ""), style: .mono)
                if let ts = g["timestamp"] as? [String: Any] {
                    s.line("  " + t["timestamp"] + " " + time(ts["time"] as? String, language) + " · " + (ts["authority"] as? String ?? "")
                           + ((ts["trusted"] as? Bool ?? false) ? "" : " (" + t["untrusted"] + ")"), style: .small)
                }
            }
        }

        let custody = report["custody"] as? [[String: String]] ?? []
        s.heading(t["section.custody"])
        if custody.isEmpty { s.line(t["custody.none"], style: .small) }
        for (i, c) in custody.enumerated() {
            if i > 0 { s.space() }
            for (k, v) in ordered(c, first: ["time", "from", "to", "reason", "seals", "notes", "segment"]) {
                s.field(t.field(k), k == "time" ? time(v, language) : v)
            }
        }

        s.heading(t["section.verify"])
        s.line(t["verify.intro"], style: .small)
        for c in report["how_to_verify"] as? [String] ?? [] { s.line(c, style: .mono) }

        s.heading(t["section.limits"])
        s.line(t["limits.1"], style: .small)
        s.line(t["limits.2"], style: .small)

        s.space()
        s.space()
        s.line(t["signature.line"])

        let footer = t["footer.case"] + " " + (caseInfo["case_number"] ?? "—") + " · " + t["footer.archive"] + " "
            + (archive["name"] as? String ?? "")
        return s.pdf(footer: footer, hash: "SHA-256 " + (archive["sha256"] as? String ?? ""), pageLabel: t["page"], of: t["of"], title: t["title"])
    }

    /// Renders the report of `archive` straight to `pdf`.
    public static func write(archive: URL, to pdf: URL, password: String? = nil, language: Language = .it, now: Date? = nil) throws {
        let report = try ForensicReport.build(archive: archive, password: password, now: now)
        try render(report, language: language).write(to: pdf, options: .withoutOverwriting)
    }

    // MARK: formatting

    static func ordered(_ d: [String: String], first: [String]) -> [(String, String)] {
        var out = first.compactMap { k in d[k].flatMap { $0.isEmpty ? nil : (k, $0) } }
        out += d.keys.filter { !first.contains($0) }.sorted().compactMap { k in d[k].flatMap { $0.isEmpty ? nil : (k, $0) } }
        return out
    }

    static func time(_ s: String?, _ l: Language) -> String {
        guard let s else { return "" }
        let p = ISO8601DateFormatter()
        p.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let q = ISO8601DateFormatter()
        guard let d = p.date(from: s) ?? q.date(from: s) else { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: l == .it ? "it_IT" : "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMMM yyyy, HH:mm:ss.SSS 'UTC'"
        return f.string(from: d)
    }

    static func bytes(_ v: Any?, _ l: Language) -> String {
        let n = (v as? NSNumber)?.int64Value ?? (v as? String).flatMap { Int64($0) } ?? 0
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: l == .it ? "it_IT" : "en_GB")
        return (f.string(from: NSNumber(value: n)) ?? String(n)) + (l == .it ? " byte" : " bytes")
    }

    // MARK: words

    struct Text {
        let l: Language
        init(_ l: Language) { self.l = l }
        subscript(_ k: String) -> String { (l == .it ? Self.it[k] : Self.en[k]) ?? k }
        func field(_ k: String) -> String { self["f." + k] == "f." + k ? k.replacingOccurrences(of: "_", with: " ") : self["f." + k] }
        func check(_ k: String) -> String { self["c." + k] == "c." + k ? k : self["c." + k] }
        func method(_ k: String) -> String { self["m." + k] == "m." + k ? k : self["m." + k] }

        static let it: [String: String] = [
            "title": "Rapporto di acquisizione forense",
            "generated": "Generato il",
            "outcome.passed": "✔ Acquisizione completa e verificata",
            "outcome.warning": "⚠ Acquisizione completa, con avvisi (vedi sotto)",
            "outcome.failed": "✖ Verifica NON superata",
            "section.case": "Caso", "section.device": "Reperto", "section.acquisition": "Acquisizione",
            "section.hashes": "Hash della sorgente", "section.unreadable": "Settori illeggibili",
            "section.archive": "Archivio", "section.signatures": "Firme dei segmenti",
            "section.custody": "Catena di custodia", "section.verify": "Come verificare",
            "section.limits": "Limiti",
            "archive.note": "Riportare questo SHA-256 nel verbale: è il riferimento esterno che rende evidente ogni modifica successiva, compresa la rimozione degli ultimi segmenti.",
            "segment": "Segmento", "timestamp": "Marca temporale", "untrusted": "autorità non verificata",
            "custody.none": "Nessun passaggio di mano registrato.",
            "verify.intro": "Chiunque riceva l'archivio può ripetere la verifica con questi comandi; xiz (libxiz) è un'implementazione indipendente del formato.",
            "limits.1": "XIZ rende evidente la manomissione, non la impedisce: confrontare lo SHA-256 dell'archivio con quello del verbale.",
            "limits.2": "Togliere gli ultimi segmenti lascia un archivio valido: anche il numero dei passaggi di custodia va riportato nel verbale.",
            "signature.line": "Firma dell'operatore  ______________________________        Data  ______________",
            "footer.case": "Caso", "footer.archive": "Archivio", "page": "Pagina", "of": "di",
            "c.structure": "Struttura del file", "c.segments": "Segmenti", "c.frame hashes": "Hash di ogni frame", "c.signatures": "Firme e catena dei segmenti",
            "c.time-stamps": "Marche temporali", "c.images": "Immagini: hash della sorgente", "c.files": "File: inventario firmato",
            "c.expected SHA-256": "SHA-256 atteso dal verbale", "c.content": "Contenuto",
            "f.case_number": "Numero del caso", "f.evidence_number": "Reperto", "f.title": "Titolo", "f.proceeding": "Procedimento",
            "f.court": "Autorità", "f.examiner": "Operatore", "f.organization": "Organizzazione", "f.location": "Luogo",
            "f.description": "Descrizione", "f.notes": "Note", "f.model": "Modello", "f.serial": "Numero di serie",
            "f.interface": "Interfaccia", "f.write_blocker": "Blocco di scrittura", "f.path": "Percorso", "f.method": "Metodo",
            "f.sources": "Sorgenti", "f.started": "Inizio", "f.finished": "Fine", "f.source_size": "Dimensione della sorgente",
            "f.files": "File", "f.bytes": "Byte", "f.skipped": "Non acquisiti", "f.tool": "Strumento", "f.tool_version": "Versione",
            "f.os": "Sistema operativo", "f.inventory_sha256": "SHA-256 dell'inventario", "f.size": "Dimensione", "f.name": "Nome",
            "f.time": "Ora", "f.from": "Da", "f.to": "A", "f.reason": "Motivo", "f.seals": "Sigilli", "f.segment": "Segmento",
            "f.description_device": "Descrizione", "f.seals_found": "Sigilli trovati", "f.operator": "Operatore",
            "m.logical": "logica (file e cartelle)", "m.physical": "fisica (immagine del disco)", "m.volume": "volume",
        ]
        static let en: [String: String] = [
            "title": "Forensic acquisition report",
            "generated": "Generated on",
            "outcome.passed": "✔ Acquisition complete and verified",
            "outcome.warning": "⚠ Acquisition complete, with warnings (see below)",
            "outcome.failed": "✖ Verification FAILED",
            "section.case": "Case", "section.device": "Evidence item", "section.acquisition": "Acquisition",
            "section.hashes": "Source hashes", "section.unreadable": "Unreadable sectors",
            "section.archive": "Archive", "section.signatures": "Segment signatures",
            "section.custody": "Chain of custody", "section.verify": "How to verify",
            "section.limits": "Limits",
            "archive.note": "Write this SHA-256 into the written record: it is the outside reference that makes any later change evident, removing the last segments included.",
            "segment": "Segment", "timestamp": "Time-stamp", "untrusted": "authority not verified",
            "custody.none": "No hand-over recorded.",
            "verify.intro": "Anyone who receives the archive can repeat the verification with these commands; xiz (libxiz) is an independent implementation of the format.",
            "limits.1": "XIZ makes tampering evident, not impossible: compare the archive's SHA-256 with the one in the written record.",
            "limits.2": "Removing the last segments leaves a valid archive: write the number of custody hand-overs into the record too.",
            "signature.line": "Operator's signature  ______________________________        Date  ______________",
            "footer.case": "Case", "footer.archive": "Archive", "page": "Page", "of": "of",
            "c.structure": "File structure", "c.segments": "Segments", "c.frame hashes": "Hash of every frame", "c.signatures": "Segment signatures and chain",
            "c.time-stamps": "Time-stamps", "c.images": "Images: source hash", "c.files": "Files: signed inventory",
            "c.expected SHA-256": "SHA-256 expected from the record", "c.content": "Content",
            "f.case_number": "Case number", "f.evidence_number": "Evidence item", "f.title": "Title", "f.proceeding": "Proceeding",
            "f.court": "Authority", "f.examiner": "Examiner", "f.organization": "Organization", "f.location": "Location",
            "f.description": "Description", "f.notes": "Notes", "f.model": "Model", "f.serial": "Serial number",
            "f.interface": "Interface", "f.write_blocker": "Write blocker", "f.path": "Path", "f.method": "Method",
            "f.sources": "Sources", "f.started": "Started", "f.finished": "Finished", "f.source_size": "Source size",
            "f.files": "Files", "f.bytes": "Bytes", "f.skipped": "Not acquired", "f.tool": "Tool", "f.tool_version": "Version",
            "f.os": "Operating system", "f.inventory_sha256": "Inventory SHA-256", "f.size": "Size", "f.name": "Name",
            "f.time": "Time", "f.from": "From", "f.to": "To", "f.reason": "Reason", "f.seals": "Seals", "f.segment": "Segment",
            "f.seals_found": "Seals found", "f.operator": "Operator",
            "m.logical": "logical (files and folders)", "m.physical": "physical (disk image)", "m.volume": "volume",
        ]
    }

    // MARK: layout

    enum Style { case title, heading, body, small, mono, outcome }

    final class Builder {
        let out = NSMutableAttributedString()
        static let width: CGFloat = 595.28, height: CGFloat = 841.89, margin: CGFloat = 56

        func font(_ s: Style) -> CTFont {
            switch s {
            case .title: CTFontCreateUIFontForLanguage(.emphasizedSystem, 20, nil)!
            case .heading: CTFontCreateUIFontForLanguage(.emphasizedSystem, 13, nil)!
            case .outcome: CTFontCreateUIFontForLanguage(.emphasizedSystem, 14, nil)!
            case .body: CTFontCreateUIFontForLanguage(.system, 10, nil)!
            case .small: CTFontCreateUIFontForLanguage(.system, 8.5, nil)!
            case .mono: CTFontCreateWithName("Menlo-Regular" as CFString, 8.5, nil)
            }
        }

        func paragraph(before: CGFloat = 0, after: CGFloat = 2, indent: CGFloat = 0, head: CGFloat = 0, tab: CGFloat? = nil, chars: Bool = false) -> CTParagraphStyle {
            var b = before, a = after, i = indent, h = head
            var mode: CTLineBreakMode = chars ? .byCharWrapping : .byWordWrapping
            var tabs: CFArray = [] as CFArray
            if let tab { tabs = [CTTextTabCreate(.left, Double(tab), nil)] as CFArray }
            return withUnsafeBytes(of: &b) { pb in withUnsafeBytes(of: &a) { pa in withUnsafeBytes(of: &i) { pi in
                withUnsafeBytes(of: &h) { ph in withUnsafeBytes(of: &mode) { pm in withUnsafeBytes(of: &tabs) { pt in
                    let settings = [
                        CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: MemoryLayout<CGFloat>.size, value: pb.baseAddress!),
                        CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: pa.baseAddress!),
                        CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: pi.baseAddress!),
                        CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: ph.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: pm.baseAddress!),
                        CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: pt.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                } } }
            } } }
        }

        func append(_ text: String, _ style: Style, color: CGColor = CGColor(gray: 0, alpha: 1), paragraph p: CTParagraphStyle? = nil) {
            var a: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(style),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            if let p { a[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = p }
            out.append(NSAttributedString(string: text, attributes: a))
        }

        func title(_ s: String) { append(s + "\n", .title, paragraph: paragraph(after: 4)) }
        func heading(_ s: String) { append(s + "\n", .heading, color: CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1), paragraph: paragraph(before: 14, after: 5)) }
        func space() { append("\n", .small) }
        func line(_ s: String, style: Style = .body) {
            append(s + "\n", style, color: style == .small ? CGColor(gray: 0.3, alpha: 1) : CGColor(gray: 0, alpha: 1),
                   paragraph: paragraph(after: 2, chars: style == .mono))
        }
        func outcome(_ s: String, color: Outcome) { append(s + "\n", .outcome, color: color.cg, paragraph: paragraph(before: 4, after: 6)) }
        func check(_ mark: String, _ name: String, _ detail: String) {
            let p = paragraph(after: 2, indent: 16, head: 0, tab: 16)
            append(mark + "\t", .body, color: mark == "✔" ? Outcome.green.cg : mark == "✖" ? Outcome.red.cg : Outcome.orange.cg, paragraph: p)
            append(name, .body, paragraph: p)
            append(detail.isEmpty ? "\n" : " — " + detail + "\n", .small, color: CGColor(gray: 0.3, alpha: 1), paragraph: p)
        }
        func field(_ label: String, _ value: String, mono: Bool = false) {
            let p = paragraph(after: 2, indent: 150, tab: 150, chars: mono)
            append(label + "\t", .small, color: CGColor(gray: 0.35, alpha: 1), paragraph: p)
            append(value + "\n", mono ? .mono : .body, paragraph: p)
        }

        enum Outcome {
            case green, orange, red
            var cg: CGColor {
                switch self {
                case .green: CGColor(red: 0.05, green: 0.5, blue: 0.2, alpha: 1)
                case .orange: CGColor(red: 0.75, green: 0.45, blue: 0, alpha: 1)
                case .red: CGColor(red: 0.75, green: 0.1, blue: 0.1, alpha: 1)
                }
            }
        }

        /// Lays the text out on A4 pages; two passes, so every footer knows the page count.
        func pdf(footer: String, hash: String, pageLabel: String, of: String, title: String) -> Data {
            let setter = CTFramesetterCreateWithAttributedString(out)
            let body = CGRect(x: Self.margin, y: Self.margin + 24, width: Self.width - 2 * Self.margin, height: Self.height - 2 * Self.margin - 24)
            var ranges: [CFRange] = []
            var start = 0
            while start < out.length {
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), CGPath(rect: body, transform: nil), nil)
                let r = CTFrameGetVisibleStringRange(frame)
                guard r.length > 0 else { break }
                ranges.append(r)
                start += r.length
            }
            let data = NSMutableData()
            var media = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
            let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "xipper-forensic"] as CFDictionary
            guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &media, info) else { return Data() }
            for (i, r) in ranges.enumerated() {
                ctx.beginPDFPage(nil)
                let frame = CTFramesetterCreateFrame(setter, r, CGPath(rect: body, transform: nil), nil)
                CTFrameDraw(frame, ctx)
                let f = Builder()
                let grey = CGColor(gray: 0.4, alpha: 1)
                f.append(footer + " · \(pageLabel) \(i + 1) \(of) \(ranges.count)\n", .small, color: grey)
                f.append(hash, .mono, color: grey)
                let fs = CTFramesetterCreateWithAttributedString(f.out)
                let fr = CGRect(x: Self.margin, y: Self.margin - 30, width: Self.width - 2 * Self.margin, height: 44)
                CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: fr, transform: nil), nil), ctx)
                ctx.setStrokeColor(CGColor(gray: 0.7, alpha: 1))
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: Self.margin, y: Self.margin + 16))
                ctx.addLine(to: CGPoint(x: Self.width - Self.margin, y: Self.margin + 16))
                ctx.strokePath()
                ctx.endPDFPage()
            }
            ctx.closePDF()
            return data as Data
        }
    }
}
