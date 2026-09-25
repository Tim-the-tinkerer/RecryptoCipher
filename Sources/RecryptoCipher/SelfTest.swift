import Foundation

enum SelfTest {
    static func run() -> String? {
        let checks: [() -> String?] = [
            deck, hash, checksum, digits, reshuffle, padding, roundTrip, knownSheet,
            keyRules, sheetForms, refuse, files, fuzz,
        ]
        var failures: [String] = []
        for check in checks {
            if let error = check() {
                failures.append(error)
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private static let screen = ["oak", "river", "clock", "stone"]
    private static let knownSalt = NoteCipher.unhex("00112233445566778899aabbccddeeff")!
    private static let knownNonce = NoteCipher.unhex("0102030405060708090a0b0c")!

    private static func seal(_ note: String, words: [String] = screen) throws -> SealedNote {
        let data = Array(note.utf8)
        let pad: [UInt8]
        if let bucket = NoteCipher.paddedLength(data.count) {
            pad = [UInt8](repeating: 0xA5, count: bucket - data.count)
        } else {
            pad = []
        }
        return try NoteCipher.encrypt(
            note: note, words: words, salt: knownSalt, nonce: knownNonce, pad: pad
        )
    }

    private static func deck() -> String? {
        if Code.all.count != 24 { return "deck \(Code.all.count)" }
        if Set(Code.all).count != 24 { return "deck has duplicates" }
        if Code.all.first?.sheet != "1.2.3" { return "first code \(Code.all.first?.sheet ?? "-")" }
        if Code.all.last?.sheet != "4.3.2" { return "last code \(Code.all.last?.sheet ?? "-")" }
        if Code(digits: [1, 1, 2]) != nil { return "112 accepted" }
        if Code(digits: [4, 2, 5]) != nil { return "425 accepted" }
        if Code(token: "4.2.1")?.sheet != "4.2.1" { return "dotted token" }
        if Code(token: "4-2-1")?.sheet != "4.2.1" { return "dashed token" }
        if Code(token: "421")?.sheet != "4.2.1" { return "bare token" }
        if Code(token: "4.4.1") != nil { return "441 accepted" }
        if Code(token: "4.2.10") != nil { return "4210 accepted" }
        return nil
    }

    private static func hash() -> String? {
        if FNV.hash64("") != 0xCBF29CE484222325 { return "fnv empty" }
        if FNV.hash64("a") != 0xAF63DC4C8601EC8C { return "fnv a \(String(FNV.hash64("a"), radix: 16))" }
        do {
            let made = try Screen.make(screen)
            let deck = made.shuffleSeed(salt: knownSalt)
            let mask = made.maskSeed(salt: knownSalt, nonce: knownNonce)
            let xor = made.xorSeed(salt: knownSalt, nonce: knownNonce)
            if Set([deck, mask, xor]).count != 3 { return "deck, mask, and xor share a seed" }
            var otherNonce = knownNonce
            otherNonce[0] ^= 0xFF
            if made.maskSeed(salt: knownSalt, nonce: otherNonce) == mask { return "mask ignored the nonce" }
            if made.xorSeed(salt: knownSalt, nonce: otherNonce) == xor { return "xor ignored the nonce" }
            var otherSalt = knownSalt
            otherSalt[0] ^= 0xFF
            if made.shuffleSeed(salt: otherSalt) == deck { return "deck ignored the salt" }
            let raw: [UInt8] = [0x52, 0x00, 0x00, 0x00, 0x01, 0x41, 0xA5, 0x29, 0xB1]
            let once = NoteCipher.whiten(raw, salt: knownSalt, nonce: knownNonce, on: made)
            if once == raw { return "xor left the frame unchanged" }
            if NoteCipher.whiten(once, salt: knownSalt, nonce: knownNonce, on: made) != raw {
                return "xor did not reverse"
            }
        } catch {
            return "seeds: \(error)"
        }
        return nil
    }

    private static func checksum() -> String? {
        let sample = Array("123456789".utf8)
        if NoteCipher.crc16(sample) != 0x29B1 { return String(format: "crc %04X", NoteCipher.crc16(sample)) }
        if NoteCipher.crc16([]) != 0xFFFF { return "crc empty" }
        return nil
    }

    private static func digits() -> String? {
        for value in 0...255 {
            let hi = value / 24
            let lo = value % 24
            if hi > 10 || hi * 24 + lo != value { return "digit \(value)" }
        }
        if NoteCipher.paddedLength(0) != nil { return "empty has a bucket" }
        if NoteCipher.paddedLength(1) != 32 { return "bucket 1" }
        if NoteCipher.paddedLength(32) != 32 { return "bucket 32" }
        if NoteCipher.paddedLength(33) != 64 { return "bucket 33" }
        if NoteCipher.paddedLength(8000) != 8192 { return "bucket 8000" }
        if NoteCipher.paddedLength(8001) != nil { return "bucket 8001" }
        return nil
    }

    private static func roundTrip() -> String? {
        let notes = [
            "",
            "A",
            "Hi",
            "Meet at noon",
            "line one\nline two",
            "café 🔐",
            String(repeating: "a", count: 32),
            String(repeating: "a", count: 2000),
            String(bytes: Array(0...127), encoding: .utf8)!,
            String(bytes: [0, 0, 0, 0], encoding: .utf8)!,
            String(repeating: "a", count: 8000),
        ]
        for note in notes {
            do {
                let sealed = try seal(note)
                let opened = try NoteCipher.decrypt(sheet: sealed.sheet, words: screen)
                if opened.note != note { return "round trip changed \(preview(note))" }
                if note.isEmpty {
                    if sealed.codes != 0 || !sealed.sheet.isEmpty { return "empty note wrote a sheet" }
                } else {
                    let bucket = NoteCipher.paddedLength(note.utf8.count)!
                    if sealed.paddedBytes != bucket { return "\(preview(note)) padded to \(sealed.paddedBytes)" }
                    if sealed.codes != (1 + 4 + bucket + 2) * 2 { return "\(preview(note)) wrote \(sealed.codes) codes" }
                    if sealed.bytes != note.utf8.count { return "byte count" }
                    if sealed.salt != knownSalt || sealed.nonce != knownNonce { return "salt or nonce dropped" }
                    if opened.salt != knownSalt || opened.nonce != knownNonce { return "opened salt" }
                    if sealed.readings.count != sealed.codes { return "readings" }
                    for reading in sealed.readings.prefix(8) {
                        guard let code = Code(token: reading.sheet) else { return "reading \(reading.sheet)" }
                        let named = code.digits.map { screen[$0 - 1] }
                        if reading.words != named { return "reading words \(reading.sheet)" }
                    }
                    let lines = sealed.sheet.split(separator: "\n", omittingEmptySubsequences: false)
                    if lines.count < 4 { return "header missing" }
                    if lines[0] != NoteCipher.formatMark { return "format mark" }
                    let codeLines = lines.dropFirst(3)
                    for line in codeLines.dropLast() where line.split(separator: " ").count != 8 {
                        return "line wrap"
                    }
                    if codeLines.last?.split(separator: " ").count ?? 0 > 8 { return "last line" }
                }
                let again = try seal(note)
                if again.sheet != sealed.sheet { return "same salt was not deterministic" }
            } catch {
                return "round trip \(preview(note)): \(error)"
            }
        }
        do {
            let one = try NoteCipher.encrypt(note: "Hi", words: screen)
            let two = try NoteCipher.encrypt(note: "Hi", words: screen)
            if one.sheet == two.sheet { return "two random sheets matched" }
            if one.salt == two.salt || one.nonce == two.nonce { return "salt or nonce was reused" }
            let opened = try NoteCipher.decrypt(sheet: one.sheet, words: ["Oak", "River", "Clock", "Stone"])
            if opened.note != "Hi" { return "random sheet did not open" }
        } catch {
            return "random seal: \(error)"
        }
        do {
            _ = try NoteCipher.encrypt(note: String(repeating: "a", count: 8001), words: screen)
            return "long note accepted"
        } catch CipherError.tooLong {
        } catch {
            return "long note: \(error)"
        }
        return nil
    }

    private static func padding() -> String? {
        do {
            let short = try seal("A")
            let full = try seal(String(repeating: "a", count: 32))
            if short.paddedBytes != 32 || full.paddedBytes != 32 { return "bucket sizes" }
            if short.codes != full.codes { return "same bucket wrote \(short.codes) and \(full.codes)" }
            let next = try seal(String(repeating: "b", count: 33))
            if next.paddedBytes != 64 || next.codes == short.codes { return "next bucket" }
            let padA = [UInt8](repeating: 0x11, count: 31)
            let padB = [UInt8](repeating: 0x22, count: 31)
            let left = try NoteCipher.encrypt(note: "A", words: screen, salt: knownSalt, nonce: knownNonce, pad: padA)
            let right = try NoteCipher.encrypt(note: "A", words: screen, salt: knownSalt, nonce: knownNonce, pad: padB)
            if left.sheet == right.sheet || left.codes != right.codes { return "pad bytes ignored" }
            if (try NoteCipher.decrypt(sheet: left.sheet, words: screen)).note != "A" { return "pad A" }
            if (try NoteCipher.decrypt(sheet: right.sheet, words: screen)).note != "A" { return "pad B" }
            var salt = knownSalt
            salt[0] ^= 0x7F
            var nonce = knownNonce
            nonce[0] ^= 0x7F
            let otherSalt = try NoteCipher.encrypt(note: "A", words: screen, salt: salt, nonce: knownNonce, pad: padA)
            let otherNonce = try NoteCipher.encrypt(note: "A", words: screen, salt: knownSalt, nonce: nonce, pad: padA)
            if otherSalt.sheet == left.sheet { return "salt did not change the sheet" }
            if otherNonce.sheet == left.sheet { return "nonce did not change the sheet" }
            do {
                _ = try NoteCipher.encrypt(note: "A", words: screen, salt: knownSalt, nonce: knownNonce, pad: [0x11])
                return "short pad accepted"
            } catch CipherError.badPad {
            } catch {
                return "short pad: \(error)"
            }
        } catch {
            return "padding: \(error)"
        }
        return nil
    }

    private static func reshuffle() -> String? {
        var rng = SplitMix64(seed: 1)
        let first = Screen.deal(from: &rng)
        let second = Screen.deal(from: &rng)
        if first.count != 24 || Set(first).count != 24 { return "deal is not a deck" }
        if first == second { return "the stream repeated a deck" }
        if first == Code.all { return "deal left the deck in table order" }
        return nil
    }

    private static func knownSheet() -> String? {
        let expect = """
        RECRYPTO/2
        salt 00112233445566778899aabbccddeeff
        nonce 0102030405060708090a0b0c
        2.4.1 4.2.1 1.2.3 3.1.2 1.2.3 3.1.2 2.1.3 1.2.4
        1.4.2 2.3.1 4.2.3 4.3.2 3.2.4 3.1.2 3.1.2 4.2.3
        2.3.1 1.2.4 2.1.4 2.3.4 1.2.3 4.3.1 3.1.4 2.4.3
        3.1.2 4.3.2 3.2.4 3.2.4 2.1.4 4.1.2 2.3.4 1.2.4
        3.1.4 3.4.2 2.3.1 2.4.3 4.2.1 2.3.1 4.2.3 2.4.3
        3.4.1 4.2.1 4.2.1 3.2.4 1.3.2 4.2.1 2.4.1 1.3.4
        1.2.4 2.3.1 2.1.4 4.3.2 2.3.1 2.1.4 3.4.1 1.2.3
        4.1.3 1.3.4 2.1.3 1.4.2 1.2.4 2.1.4 3.2.1 4.1.3
        1.3.2 4.3.1 2.3.4 3.4.1 1.4.2 4.2.1 1.2.4 2.1.3
        2.4.1 2.4.1 4.3.2 3.1.4 2.3.1 2.4.1
        """
        do {
            let sealed = try seal("Meet at noon")
            if sealed.sheet != expect { return "known sheet changed\n\(sealed.sheet)" }
            let opened = try NoteCipher.decrypt(sheet: expect, words: ["Oak", "River", "Clock", "Stone"])
            if opened.note != "Meet at noon" { return "known sheet did not open" }
        } catch {
            return "known sheet: \(error)"
        }
        return nil
    }

    private static func keyRules() -> String? {
        do {
            let lower = try seal("Hi").sheet
            let titled = try seal("Hi", words: ["Oak", "River", "Clock", "Stone"]).sheet
            let spaced = try seal("Hi", words: ["  oak  ", "river", "clock", "stone"]).sheet
            let accent = try seal("Hi", words: ["café", "river", "clock", "stone"]).sheet
            let plain = try seal("Hi", words: ["cafe", "river", "clock", "stone"]).sheet
            if lower != titled || lower != spaced { return "screen folding" }
            if accent != plain { return "accent folding" }
            let opened = try NoteCipher.decrypt(sheet: lower, words: ["Oak", "  RIVER ", "clock", "stone"])
            if opened.note != "Hi" { return "folded screen did not open" }

            let splitA = try seal("Hi", words: ["ab", "c", "d", "e"]).sheet
            let splitB = try seal("Hi", words: ["a", "bc", "d", "e"]).sheet
            if splitA == splitB { return "word boundary ignored" }

            let moved = try seal("Hi", words: ["river", "oak", "clock", "stone"]).sheet
            if moved == lower { return "word order ignored" }

            _ = try seal("Hi", words: ["black", "blackboard", "clock", "stone"])
        } catch {
            return "key rules: \(error)"
        }

        do {
            _ = try ScreenWords.validated(["Oak", "oak", "clock", "stone"])
            return "duplicate words accepted"
        } catch CipherError.duplicateWord {
        } catch {
            return "duplicate: \(error)"
        }
        do {
            _ = try ScreenWords.validated(["", "river", "clock", "stone"])
            return "empty word accepted"
        } catch CipherError.emptyWord(let index) where index == 1 {
        } catch {
            return "empty word: \(error)"
        }
        do {
            _ = try ScreenWords.validated(["oak", String(repeating: "n", count: 33), "clock", "stone"])
            return "long word accepted"
        } catch CipherError.longWord(let index) where index == 2 {
        } catch {
            return "long word: \(error)"
        }
        return nil
    }

    private static func sheetForms() -> String? {
        do {
            let note = "Meet at noon"
            let sealed = try seal(note)
            let lines = sealed.sheet.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let header = lines.prefix(3).joined(separator: "\n")
            let body = lines.dropFirst(3).joined(separator: "\n")
            let forms = [
                body.replacingOccurrences(of: ".", with: "-"),
                body.replacingOccurrences(of: ".", with: "·"),
                body.replacingOccurrences(of: ".", with: ""),
                body.replacingOccurrences(of: ".", with: " "),
                body.replacingOccurrences(of: " ", with: ", "),
            ]
            for form in forms {
                let opened = try NoteCipher.decrypt(sheet: header + "\n" + form, words: screen)
                if opened.note != note { return "form did not open" }
            }
            let upperNonce = NoteCipher.hex(knownNonce).uppercased()
            let upper = sealed.sheet.replacingOccurrences(
                of: "nonce \(NoteCipher.hex(knownNonce))",
                with: "nonce \(upperNonce)"
            )
            let opened = try NoteCipher.decrypt(sheet: upper, words: screen)
            if opened.note != note || opened.sheet != sealed.sheet { return "upper hex" }
        } catch {
            return "sheet forms: \(error)"
        }
        return nil
    }

    private static func refuse() -> String? {
        do {
            let sealed = try seal("Meet at noon")
            var parts = try NoteCipher.parseSheet(sealed.sheet)
            guard let other = Code.all.first(where: { $0 != parts.codes[0] }) else { return "no other code" }
            parts.codes[0] = other
            do {
                _ = try NoteCipher.decrypt(
                    sheet: NoteCipher.formatSheet(salt: parts.salt, nonce: parts.nonce, codes: parts.codes),
                    words: screen
                )
                return "tampered sheet opened"
            } catch CipherError.refuses {
            } catch {
                return "tamper: \(error)"
            }
            do {
                _ = try NoteCipher.decrypt(sheet: sealed.sheet, words: ["oak", "river", "clock", "pebble"])
                return "wrong screen opened"
            } catch CipherError.refuses {
            } catch {
                return "wrong screen: \(error)"
            }
            do {
                _ = try NoteCipher.decrypt(sheet: "4.2.1 3.1.4 3.1.2", words: screen)
                return "bare codes opened"
            } catch CipherError.notSheet {
            } catch {
                return "bare codes: \(error)"
            }
            do {
                _ = try NoteCipher.decrypt(sheet: "RECRYPTO/9\nsalt 00\nnonce 00", words: screen)
                return "newer sheet opened"
            } catch CipherError.newerSheet {
            } catch {
                return "newer sheet: \(error)"
            }
            do {
                _ = try NoteCipher.decrypt(sheet: """
                RECRYPTO/1
                salt 00112233445566778899aabbccddeeff
                nonce 0102030405060708090a0b0c
                3.4.1 2.4.1 2.3.1
                """, words: screen)
                return "older sheet opened"
            } catch CipherError.olderSheet {
            } catch {
                return "older sheet: \(error)"
            }
            do {
                _ = try NoteCipher.decrypt(sheet: "4.4.1", words: screen)
                return "repeated digits opened"
            } catch CipherError.notSheet {
            } catch {
                return "repeat: \(error)"
            }
            do {
                _ = try NoteCipher.decrypt(sheet: sealed.sheet.replacingOccurrences(of: "\n", with: " "), words: screen)
                return "joined header opened"
            } catch CipherError.notSheet {
            } catch {
                return "joined header: \(error)"
            }
        } catch {
            return "refuse setup: \(error)"
        }
        return nil
    }

    private static func files() -> String? {
        if DeskFile.role(of: "Meet at noon") != .note { return "prose classified as a sheet" }
        if DeskFile.role(of: "4.2.1 3.1.4") != .sheet { return "codes classified as a note" }
        if DeskFile.role(of: "hello 4.2.1") != .note { return "mixed text classified as a sheet" }
        if DeskFile.role(of: "4.4.1") != .note { return "illegal code classified as a sheet" }
        if DeskFile.role(of: "RECRYPTO/1\nsalt no\n") != .sheet { return "header classified as a note" }
        if DeskFile.role(of: "RECRYPTO/2\n") != .sheet { return "newer header classified as a note" }
        if DeskFile.exportName(forNoteFile: nil) != "sheet.txt" { return "default export name" }
        if DeskFile.exportName(forNoteFile: "Meeting.txt") != "Meeting sheet.txt" { return "export name" }
        if DeskFile.wordsName(forNoteFile: nil) != "words.txt" { return "default words name" }
        if DeskFile.wordsName(forNoteFile: "Meeting.txt") != "Meeting words.txt" { return "words name" }
        let saved = DeskFile.screenText(["oak", "north star", "clock", "stone"])
        if DeskFile.screen(from: saved) != ["oak", "north star", "clock", "stone"] { return "screen round trip" }
        if DeskFile.role(of: saved) != .screen { return "screen role" }
        let unordered = """
        RECRYPTO SCREEN
        4 stone
        1 oak
        2 river
        3 clock
        """
        if DeskFile.screen(from: unordered) != ["oak", "river", "clock", "stone"] { return "screen order" }
        if DeskFile.screen(from: "1 oak\n2 river\n3 clock\n4 stone\n") != nil { return "header not required" }
        let legacy = """
        DECRYPTO SCREEN
        1 oak
        2 river
        3 clock
        4 stone
        """
        if DeskFile.screen(from: legacy) != nil { return "decrypto screen accepted" }
        let punctuated = """
        RECRYPTO SCREEN
        1. oak
        2) river
        3: clock
        4 stone
        """
        if DeskFile.screen(from: punctuated) != ["oak", "river", "clock", "stone"] { return "screen punctuation" }
        let sampleURL = URL(fileURLWithPath: "/tmp/recrypto-cipher-sample.txt")
        if DeskFile.url(from: sampleURL)?.path != sampleURL.path { return "url object" }
        if DeskFile.url(from: Data(sampleURL.absoluteString.utf8))?.path != sampleURL.path { return "url string" }
        if DeskFile.screen(from: DeskFile.screenText(["oak", "oak", "clock", "stone"])) != nil { return "duplicate screen accepted" }

        let note = DeskFile.Incoming(name: "note.txt", text: "Meet at noon")
        let sheet = DeskFile.Incoming(name: "codes.txt", text: "RECRYPTO/1\nsalt 00\nnonce 11\n4.2.1\n")
        let forced = DeskFile.place([sheet, note], destination: .note)
        if forced.note?.text != sheet.text || forced.sheet != nil { return "forced drop ignored the side" }
        if forced.status != "Read codes.txt. Left the other files." { return "forced status \(forced.status)" }

        let both = DeskFile.place([note, sheet], destination: nil)
        if both.note?.name != "note.txt" || both.sheet?.name != "codes.txt" { return "classify missed a side" }
        if both.status != "Read note.txt and codes.txt." { return "classify status \(both.status)" }
        let screenFile = DeskFile.Incoming(name: "words.txt", text: DeskFile.screenText(["oak", "river", "clock", "stone"]))
        let mixed = DeskFile.place([note, sheet, screenFile], destination: nil)
        if mixed.screen != ["oak", "river", "clock", "stone"] || mixed.note?.name != "note.txt" || mixed.sheet?.name != "codes.txt" {
            return "classify missed the screen"
        }
        if mixed.status != "Read note.txt and codes.txt and words.txt." { return "screen status \(mixed.status)" }
        if DeskFile.place([note], destination: .screen).isError == false { return "note accepted as a screen" }
        let opened = DeskFile.place([screenFile], destination: .screen)
        if opened.screen != ["oak", "river", "clock", "stone"] || opened.isError { return "open words" }
        if DeskFile.place([], destination: nil).isError == false { return "empty drop accepted" }
        if DeskFile.place([DeskFile.Incoming(name: "empty.txt", text: " \n")], destination: .sheet).isError == false {
            return "empty file accepted"
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recrypto-cipher-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let hello = dir.appendingPathComponent("hello.txt")
            try Data("\u{FEFF}Meet at noon".utf8).write(to: hello)
            if try DeskFile.read(hello) != "Meet at noon" { return "bom was kept" }
            let wide = dir.appendingPathComponent("wide.txt")
            var marked = Data([0xFF, 0xFE])
            marked.append("Hi".data(using: .utf16LittleEndian)!)
            try marked.write(to: wide)
            if try DeskFile.read(wide) != "Hi" { return "utf16 \(try DeskFile.read(wide))" }
            let junk = dir.appendingPathComponent("junk.bin")
            try Data([0xFF, 0x00, 0xFE]).write(to: junk)
            do {
                _ = try DeskFile.read(junk)
                return "binary accepted"
            } catch DeskFileError.notText {
            } catch {
                return "binary: \(error)"
            }
            do {
                _ = try DeskFile.read(dir)
                return "folder accepted"
            } catch DeskFileError.folder {
            } catch {
                return "folder: \(error)"
            }
        } catch {
            return "file fixture: \(error)"
        }
        return nil
    }

    private static func fuzz() -> String? {
        Fuzz.run(rounds: 40, mutations: 60)
    }

    private static func preview(_ note: String) -> String {
        if note.isEmpty { return "empty" }
        let head = note.prefix(24)
        return "“\(head)”"
    }
}
