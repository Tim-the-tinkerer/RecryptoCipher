import Foundation

/// Where a dropped or opened file lands. A sheet is a Recrypto sheet, or text whose every token is a code.
enum DeskFile {
    enum Role: Equatable {
        case note, sheet, screen
    }

    static let screenMark = "RECRYPTO SCREEN"

    struct Incoming: Equatable {
        var name: String
        var text: String
    }

    struct Placement: Equatable {
        var note: Incoming?
        var sheet: Incoming?
        var screen: [String]?
        var status: String
        var isError: Bool
    }

    static let maxBytes = 1_000_000

    static func role(of text: String) -> Role {
        if screen(from: text) != nil { return .screen }
        if NoteCipher.looksLikeSheet(text) { return .sheet }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .note }
        guard let codes = try? NoteCipher.parse(trimmed), !codes.isEmpty else { return .note }
        return .sheet
    }

    /// Four numbered words under the screen mark. Nil unless the whole file is a screen.
    static func screen(from text: String) -> [String]? {
        let lines = text.split(whereSeparator: \.isNewline).map { ScreenWords.tidy(String($0)) }.filter { !$0.isEmpty }
        guard lines.first == screenMark, lines.count == 5 else { return nil }
        var words = [String?](repeating: nil, count: 4)
        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let number = screenNumber(parts[0]) else { return nil }
            if words[number - 1] != nil { return nil }
            words[number - 1] = String(parts[1])
        }
        let four = words.compactMap { $0 }
        guard four.count == 4, (try? ScreenWords.validated(four)) != nil else { return nil }
        return four
    }

    /// `1`, `1.`, `1)`, or `1:` — the digit has to be the whole number, so `10` does not count.
    private static func screenNumber(_ token: Substring) -> Int? {
        var core = String(token.trimmingCharacters(in: CharacterSet(charactersIn: ".)")))
        if core.hasSuffix(":") { core.removeLast() }
        guard let number = Int(core), (1...4).contains(number), String(number) == core else { return nil }
        return number
    }

    static func screenText(_ words: [String]) -> String {
        let lines = [screenMark] + words.enumerated().map { "\($0.offset + 1) \($0.element)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `destination` forces the first file onto that side. Nil classifies each file.
    static func place(_ files: [Incoming], destination: Role?) -> Placement {
        guard let first = files.first else {
            return Placement(note: nil, sheet: nil, screen: nil, status: "Drop a file.", isError: true)
        }
        if let destination {
            if first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Placement(note: nil, sheet: nil, screen: nil, status: "\(first.name) is empty.", isError: true)
            }
            if destination == .screen {
                guard let words = screen(from: first.text) else {
                    return Placement(
                        note: nil,
                        sheet: nil,
                        screen: nil,
                        status: "\(first.name) is not a screen of four words.",
                        isError: true
                    )
                }
                return Placement(
                    note: nil,
                    sheet: nil,
                    screen: words,
                    status: readStatus([first.name], left: files.count - 1),
                    isError: false
                )
            }
            var placement = Placement(note: nil, sheet: nil, screen: nil, status: readStatus([first.name], left: files.count - 1), isError: false)
            switch destination {
            case .note: placement.note = first
            case .sheet: placement.sheet = first
            case .screen: break
            }
            return placement
        }

        var notes: [Incoming] = []
        var sheets: [Incoming] = []
        var screens: [(name: String, words: [String])] = []
        for file in files {
            if file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let words = screen(from: file.text) {
                screens.append((file.name, words))
                continue
            }
            switch role(of: file.text) {
            case .note: notes.append(file)
            case .sheet: sheets.append(file)
            case .screen: break
            }
        }
        if notes.isEmpty, sheets.isEmpty, screens.isEmpty {
            return Placement(note: nil, sheet: nil, screen: nil, status: "\(first.name) is empty.", isError: true)
        }
        let chosen = [notes.first?.name, sheets.first?.name, screens.first?.name].compactMap { $0 }
        let left = files.count - chosen.count
        return Placement(
            note: notes.first,
            sheet: sheets.first,
            screen: screens.first?.words,
            status: readStatus(chosen, left: left),
            isError: false
        )
    }

    static func read(_ url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DeskFileError.unreadable(url.lastPathComponent)
        }
        if isDirectory.boolValue { throw DeskFileError.folder }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > Int64(maxBytes) { throw DeskFileError.tooBig }
        let data = try Data(contentsOf: url)
        if data.count > maxBytes { throw DeskFileError.tooBig }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { throw DeskFileError.notText }
            return text
        }
        guard var text = String(data: data, encoding: .utf8) else { throw DeskFileError.notText }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    static func url(from item: Any?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        guard let data = item as? Data else { return nil }
        if let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
        guard let string = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))),
              let url = URL(string: string), url.isFileURL
        else { return nil }
        return url
    }

    static func exportName(forNoteFile name: String?) -> String {
        guard let name, !name.isEmpty else { return "sheet.txt" }
        let stem = (name as NSString).deletingPathExtension
        guard !stem.isEmpty else { return "sheet.txt" }
        return "\(stem) sheet.txt"
    }

    static func wordsName(forNoteFile name: String?) -> String {
        guard let name, !name.isEmpty else { return "words.txt" }
        let stem = (name as NSString).deletingPathExtension
        guard !stem.isEmpty else { return "words.txt" }
        return "\(stem) words.txt"
    }

    private static func readStatus(_ names: [String], left: Int) -> String {
        let read = names.joined(separator: " and ")
        if left > 0 { return "Read \(read). Left the other files." }
        return "Read \(read)."
    }
}

enum DeskFileError: Error, CustomStringConvertible, LocalizedError {
    case folder
    case notText
    case tooBig
    case unreadable(String)

    var description: String {
        switch self {
        case .folder:
            return "Drop a file, not a folder."
        case .notText:
            return "That file is not text."
        case .tooBig:
            return "That file is too big for the desk."
        case .unreadable(let name):
            return "Could not read \(name)."
        }
    }

    var errorDescription: String? { description }
}
