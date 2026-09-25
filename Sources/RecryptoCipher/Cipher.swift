import Foundation
import Security

/// A note sealed as code cards, with a fresh salt, a fresh nonce, and size padding.
///
/// The screen is four words numbered 1–4. A code is three different digits
/// from 1 to 4. There are 24, in the same order the table generates them.
///
/// Three SplitMix64 streams share the screen and stay independent by label:
/// `DECK` is the screen and the salt, `MASK` and `XOR` add the nonce. The
/// modulo in `int(below:)` belongs to the deck and the digit mask. Do not
/// replace it, and do not reseed a stream between cards. The XOR stream is
/// its own generator: the low 8 bits of each step, one byte per framed byte.
///
/// A non-empty note is padded with random bytes up to the next size bucket
/// (32, 64, 128, 256, 512, 1024, 2048, 4096, 8192). The frame is marker 0x52,
/// a 4-byte length, the note, the pad, and CRC-16/CCITT-FALSE (init 0xFFFF,
/// poly 0x1021) of the length, the note, and the pad. That whole frame is
/// XORed with the keystream. Each whitened byte is two base-24 digits, high
/// digit first, and each digit is one card after the modulo-24 mask. An empty
/// note is an empty sheet. The four words stay off the sheet.

struct Code: Equatable, Hashable {
    let a: Int
    let b: Int
    let c: Int

    var digits: [Int] { [a, b, c] }
    var sheet: String { "\(a).\(b).\(c)" }

    init?(digits: [Int]) {
        guard digits.count == 3,
              Set(digits).count == 3,
              digits.allSatisfy({ (1...4).contains($0) })
        else { return nil }
        a = digits[0]
        b = digits[1]
        c = digits[2]
    }

    /// `4.2.1`, `4-2-1`, `4·2·1`, `4/2/1`, or `421`.
    init?(token: String) {
        let separators: Set<Character> = [".", "-", "·", "•", "/"]
        var digits: [Int] = []
        for character in token {
            if separators.contains(character) { continue }
            guard let value = character.wholeNumberValue, (1...4).contains(value) else { return nil }
            digits.append(value)
        }
        self.init(digits: digits)
    }

    static let all: [Code] = {
        var out: [Code] = []
        for x in 1...4 {
            for y in 1...4 where y != x {
                for z in 1...4 where z != x && z != y {
                    if let code = Code(digits: [x, y, z]) {
                        out.append(code)
                    }
                }
            }
        }
        return out
    }()
}

struct CodeReading: Equatable {
    var sheet: String
    var words: [String]
}

struct SealedNote: Equatable {
    var note: String
    var sheet: String
    var readings: [CodeReading]
    var bytes: Int
    /// The size bucket the note was stored in. Zero when the note is empty.
    var paddedBytes: Int
    var codes: Int
    var salt: [UInt8]
    var nonce: [UInt8]
}

struct SheetParts: Equatable {
    var salt: [UInt8]
    var nonce: [UInt8]
    var codes: [Code]
}

enum CipherError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case emptyWord(Int)
    case longWord(Int)
    case duplicateWord
    case unreadable(String)
    case incomplete
    case tooLong
    case longSheet
    case refuses
    case notSheet
    case olderSheet
    case newerSheet
    case badSalt
    case badNonce
    case badPad
    case entropy

    var description: String {
        switch self {
        case .emptyWord(let index):
            return "Word \(index) is empty."
        case .longWord(let index):
            return "Word \(index) is too long for the screen."
        case .duplicateWord:
            return "Every word on the screen has to be different."
        case .unreadable(let token):
            return "“\(token)” is not a code. Use three different digits from 1 to 4."
        case .incomplete:
            return "That sheet stops in the middle of a code."
        case .tooLong:
            return "That note is too long for a code sheet."
        case .longSheet:
            return "That sheet is too long."
        case .refuses:
            return "This screen does not open that sheet."
        case .notSheet:
            return "That sheet is not a Recrypto sheet."
        case .olderSheet:
            return "That sheet was sealed before the XOR layer. Seal it again."
        case .newerSheet:
            return "That sheet uses a Recrypto version this app does not read."
        case .badSalt:
            return "The salt on that sheet is not 16 bytes."
        case .badNonce:
            return "The nonce on that sheet is not 12 bytes."
        case .badPad:
            return "The pad does not fill the size bucket."
        case .entropy:
            return "Could not draw a salt and a nonce."
        }
    }

    var errorDescription: String? { description }
}

enum ScreenWords {
    static let maxLength = 32

    static func tidy(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Same folding as the table. "Oak" and "oak" match. "black" does not match "blackboard".
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US")
        )
        let lowered = folded.lowercased()
        let spaced = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return tidy(String(spaced))
    }

    static func validated(_ words: [String]) throws -> [String] {
        guard words.count == 4 else { throw CipherError.emptyWord(1) }
        var cleaned: [String] = []
        var seen = Set<String>()
        for (offset, item) in words.enumerated() {
            let index = offset + 1
            let tidyWord = tidy(item)
            let key = normalize(tidyWord)
            if key.isEmpty { throw CipherError.emptyWord(index) }
            if tidyWord.count > maxLength { throw CipherError.longWord(index) }
            if seen.contains(key) { throw CipherError.duplicateWord }
            seen.insert(key)
            cleaned.append(tidyWord)
        }
        return cleaned
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func int(below n: Int) -> Int {
        precondition(n > 0)
        return Int(next() % UInt64(n))
    }
}

enum FNV {
    private static let prime: UInt64 = 1099511628211
    private static let offset: UInt64 = 14695981039346656037

    static func hash64(_ text: String) -> UInt64 {
        var hash = offset
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }

    /// Domain-separated mix. `label` names the stream, then the normalized
    /// screen, then each chunk (salt, then nonce) introduced by 0x1E.
    static func fold(label: String, material: String, chunks: [[UInt8]]) -> UInt64 {
        var hash = hash64(label)
        hash ^= 0x1F
        hash &*= prime
        for byte in material.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        for chunk in chunks {
            hash ^= 0x1E
            hash &*= prime
            for byte in chunk {
                hash ^= UInt64(byte)
                hash &*= prime
            }
        }
        return hash
    }
}

enum Entropy {
    static func bytes(_ count: Int) throws -> [UInt8] {
        if count == 0 { return [] }
        var out = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        guard status == errSecSuccess else { throw CipherError.entropy }
        return out
    }
}

struct Screen: Equatable {
    let words: [String]
    /// Normalized words joined by U+001F. This is the screen half of every seed.
    let material: String

    /// Deck shuffle. The nonce stays out of this seed.
    func shuffleSeed(salt: [UInt8]) -> UInt64 {
        FNV.fold(label: "DECK", material: material, chunks: [salt])
    }

    /// Digit mask, modulo 24. Independent of the deck stream and the XOR stream.
    func maskSeed(salt: [UInt8], nonce: [UInt8]) -> UInt64 {
        FNV.fold(label: "MASK", material: material, chunks: [salt, nonce])
    }

    /// Byte keystream. Same inputs as the mask, different label, own SplitMix64 state.
    func xorSeed(salt: [UInt8], nonce: [UInt8]) -> UInt64 {
        FNV.fold(label: "XOR", material: material, chunks: [salt, nonce])
    }

    /// One Fisher–Yates pass. Always draws 23 indexes, so encrypt and decrypt stay on the same stream.
    static func deal(from rng: inout SplitMix64) -> [Code] {
        var deck = Code.all
        var index = deck.count - 1
        while index > 0 {
            let swap = rng.int(below: index + 1)
            if swap != index {
                deck.swapAt(index, swap)
            }
            index -= 1
        }
        return deck
    }

    static func make(_ words: [String]) throws -> Screen {
        let cleaned = try ScreenWords.validated(words)
        let material = cleaned.map(ScreenWords.normalize).joined(separator: "\u{1F}")
        return Screen(words: cleaned, material: material)
    }
}

enum NoteCipher {
    static let formatMark = "RECRYPTO/2"
    /// Sheets sealed before the XOR layer.
    static let olderMark = "RECRYPTO/1"
    static let saltSize = 16
    static let nonceSize = 12
    static let maxNoteBytes = 8000
    /// Above the longest sheet a max-length note can produce.
    static let maxSheetCodes = 20_000
    static let marker: UInt8 = 0x52
    static let buckets = [32, 64, 128, 256, 512, 1024, 2048, 4096, 8192]

    /// Smallest bucket that can hold `count` note bytes. Nil when the note is empty or past 8000 bytes.
    static func paddedLength(_ count: Int) -> Int? {
        guard (1...maxNoteBytes).contains(count) else { return nil }
        return buckets.first { $0 >= count }
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ text: String) -> [UInt8]? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            out.append(value)
            index = next
        }
        return out
    }

    static func looksLikeSheet(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { ScreenWords.tidy(String($0)) }.filter { !$0.isEmpty }
        guard let mark = lines.first.flatMap(formatToken) else { return false }
        return mark == formatMark || mark.hasPrefix("RECRYPTO/")
    }

    /// The version token is the first word of the first line, so a smashed header is not a new version.
    private static func formatToken(_ line: String) -> String? {
        line.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    static func encrypt(note: String, words: [String]) throws -> SealedNote {
        let salt = try Entropy.bytes(saltSize)
        let nonce = try Entropy.bytes(nonceSize)
        return try encrypt(note: note, words: words, salt: salt, nonce: nonce, pad: nil)
    }

    /// `pad` fills the bucket when a test needs a frozen sheet. Nil draws random pad bytes.
    static func encrypt(
        note: String,
        words: [String],
        salt: [UInt8],
        nonce: [UInt8],
        pad: [UInt8]?
    ) throws -> SealedNote {
        guard salt.count == saltSize else { throw CipherError.badSalt }
        guard nonce.count == nonceSize else { throw CipherError.badNonce }
        let screen = try Screen.make(words)
        let data = Array(note.utf8)
        if data.isEmpty {
            return SealedNote(
                note: "", sheet: "", readings: [], bytes: 0, paddedBytes: 0, codes: 0, salt: salt, nonce: nonce
            )
        }
        if data.count > maxNoteBytes { throw CipherError.tooLong }
        guard let bucket = paddedLength(data.count) else { throw CipherError.tooLong }
        let padBytes: [UInt8]
        if let pad {
            guard pad.count == bucket - data.count else { throw CipherError.badPad }
            padBytes = pad
        } else {
            padBytes = try Entropy.bytes(bucket - data.count)
        }
        let framed = frame(note: data, pad: padBytes)
        let whitened = whiten(framed, salt: salt, nonce: nonce, on: screen)
        let codes = codes(for: whitened, salt: salt, nonce: nonce, on: screen)
        return SealedNote(
            note: note,
            sheet: formatSheet(salt: salt, nonce: nonce, codes: codes),
            readings: readings(codes, on: screen),
            bytes: data.count,
            paddedBytes: bucket,
            codes: codes.count,
            salt: salt,
            nonce: nonce
        )
    }

    static func decrypt(sheet: String, words: [String]) throws -> SealedNote {
        let screen = try Screen.make(words)
        if sheet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SealedNote(
                note: "", sheet: "", readings: [], bytes: 0, paddedBytes: 0, codes: 0, salt: [], nonce: []
            )
        }
        let opened = try parseSheet(sheet)
        if opened.codes.count > maxSheetCodes { throw CipherError.longSheet }
        let data = try bytes(from: opened.codes, salt: opened.salt, nonce: opened.nonce, on: screen)
        guard let note = String(bytes: data, encoding: .utf8) else { throw CipherError.refuses }
        return SealedNote(
            note: note,
            sheet: formatSheet(salt: opened.salt, nonce: opened.nonce, codes: opened.codes),
            readings: readings(opened.codes, on: screen),
            bytes: data.count,
            paddedBytes: paddedLength(data.count) ?? data.count,
            codes: opened.codes.count,
            salt: opened.salt,
            nonce: opened.nonce
        )
    }

    static func formatSheet(salt: [UInt8], nonce: [UInt8], codes: [Code]) -> String {
        let head = [
            formatMark,
            "salt \(hex(salt))",
            "nonce \(hex(nonce))",
        ]
        let body = format(codes)
        if body.isEmpty { return head.joined(separator: "\n") }
        return (head + [body]).joined(separator: "\n")
    }

    static func parseSheet(_ raw: String) throws -> SheetParts {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { ScreenWords.tidy(String($0)) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, let mark = formatToken(first) else { throw CipherError.notSheet }
        if mark == olderMark { throw CipherError.olderSheet }
        if mark != formatMark {
            if mark.hasPrefix("RECRYPTO/") { throw CipherError.newerSheet }
            throw CipherError.notSheet
        }
        guard first == formatMark, lines.count >= 3 else { throw CipherError.notSheet }
        let salt = try labeled(lines[1], label: "salt", count: saltSize, error: .badSalt)
        let nonce = try labeled(lines[2], label: "nonce", count: nonceSize, error: .badNonce)
        let codes = try parse(lines.dropFirst(3).joined(separator: " "))
        return SheetParts(salt: salt, nonce: nonce, codes: codes)
    }

    private static func labeled(_ line: String, label: String, count: Int, error: CipherError) throws -> [UInt8] {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == label else { throw CipherError.notSheet }
        guard let bytes = unhex(parts[1]), bytes.count == count else { throw error }
        return bytes
    }

    private static func codes(for data: [UInt8], salt: [UInt8], nonce: [UInt8], on screen: Screen) -> [Code] {
        var shuffle = SplitMix64(seed: screen.shuffleSeed(salt: salt))
        var mask = SplitMix64(seed: screen.maskSeed(salt: salt, nonce: nonce))
        var codes: [Code] = []
        codes.reserveCapacity(data.count * 2)
        for byte in data {
            codes.append(card(for: Int(byte) / 24, shuffle: &shuffle, mask: &mask))
            codes.append(card(for: Int(byte) % 24, shuffle: &shuffle, mask: &mask))
        }
        return codes
    }

    private static func bytes(from codes: [Code], salt: [UInt8], nonce: [UInt8], on screen: Screen) throws -> [UInt8] {
        guard codes.count.isMultiple(of: 2), !codes.isEmpty else { throw CipherError.refuses }
        var shuffle = SplitMix64(seed: screen.shuffleSeed(salt: salt))
        var mask = SplitMix64(seed: screen.maskSeed(salt: salt, nonce: nonce))
        var raw: [UInt8] = []
        raw.reserveCapacity(codes.count / 2)
        var index = 0
        while index < codes.count {
            let hi = try digit(of: codes[index], shuffle: &shuffle, mask: &mask)
            let lo = try digit(of: codes[index + 1], shuffle: &shuffle, mask: &mask)
            let value = hi * 24 + lo
            guard hi < 11, value <= 255 else { throw CipherError.refuses }
            raw.append(UInt8(value))
            index += 2
        }
        return try unframe(whiten(raw, salt: salt, nonce: nonce, on: screen))
    }

    /// XOR the completed frame, marker through CRC. The same call reverses it.
    static func whiten(_ bytes: [UInt8], salt: [UInt8], nonce: [UInt8], on screen: Screen) -> [UInt8] {
        var rng = SplitMix64(seed: screen.xorSeed(salt: salt, nonce: nonce))
        return bytes.map { byte in
            byte ^ UInt8(truncatingIfNeeded: rng.next())
        }
    }

    private static func card(for digit: Int, shuffle: inout SplitMix64, mask: inout SplitMix64) -> Code {
        let deck = Screen.deal(from: &shuffle)
        let hidden = (digit + mask.int(below: 24)) % 24
        return deck[hidden]
    }

    private static func digit(of code: Code, shuffle: inout SplitMix64, mask: inout SplitMix64) throws -> Int {
        let deck = Screen.deal(from: &shuffle)
        let shift = mask.int(below: 24)
        guard let hidden = deck.firstIndex(of: code) else { throw CipherError.refuses }
        return (hidden - shift + 24) % 24
    }

    /// 0x52, the length, the note, the pad, and the seal over everything after the marker.
    private static func frame(note: [UInt8], pad: [UInt8]) -> [UInt8] {
        let count = UInt32(note.count)
        var body: [UInt8] = [
            UInt8((count >> 24) & 0xFF),
            UInt8((count >> 16) & 0xFF),
            UInt8((count >> 8) & 0xFF),
            UInt8(count & 0xFF),
        ]
        body.append(contentsOf: note)
        body.append(contentsOf: pad)
        let crc = crc16(body)
        var out: [UInt8] = [marker]
        out.append(contentsOf: body)
        out.append(UInt8(crc >> 8))
        out.append(UInt8(crc & 0xFF))
        return out
    }

    private static func unframe(_ raw: [UInt8]) throws -> [UInt8] {
        guard raw.first == marker, raw.count >= 7 else { throw CipherError.refuses }
        let count = (Int(raw[1]) << 24) | (Int(raw[2]) << 16) | (Int(raw[3]) << 8) | Int(raw[4])
        guard count >= 1, count <= maxNoteBytes, let bucket = paddedLength(count) else {
            throw CipherError.refuses
        }
        guard raw.count == 1 + 4 + bucket + 2 else { throw CipherError.refuses }
        let body = Array(raw[1..<(raw.count - 2)])
        let recorded = (UInt16(raw[raw.count - 2]) << 8) | UInt16(raw[raw.count - 1])
        guard crc16(body) == recorded else { throw CipherError.refuses }
        return Array(body[4..<(4 + count)])
    }

    static func parse(_ raw: String) throws -> [Code] {
        let parts = raw.split { character in
            character.isWhitespace || character == "," || character == ";" || character == "|"
        }.map(String.init)
        var codes: [Code] = []
        var pending: [Int] = []
        for token in parts {
            if token.count == 1, let value = token.first?.wholeNumberValue, (1...4).contains(value) {
                pending.append(value)
                if pending.count == 3 {
                    guard let code = Code(digits: pending) else {
                        throw CipherError.unreadable(pending.map(String.init).joined(separator: " "))
                    }
                    codes.append(code)
                    pending.removeAll()
                }
                continue
            }
            if !pending.isEmpty { throw CipherError.incomplete }
            guard let code = Code(token: token) else { throw CipherError.unreadable(token) }
            codes.append(code)
        }
        if !pending.isEmpty { throw CipherError.incomplete }
        return codes
    }

    static func format(_ codes: [Code]) -> String {
        guard !codes.isEmpty else { return "" }
        var lines: [String] = []
        var line: [String] = []
        for code in codes {
            line.append(code.sheet)
            if line.count == 8 {
                lines.append(line.joined(separator: " "))
                line.removeAll()
            }
        }
        if !line.isEmpty {
            lines.append(line.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private static func readings(_ codes: [Code], on screen: Screen) -> [CodeReading] {
        codes.map { code in
            CodeReading(
                sheet: code.sheet,
                words: code.digits.map { screen.words[$0 - 1] }
            )
        }
    }
}
