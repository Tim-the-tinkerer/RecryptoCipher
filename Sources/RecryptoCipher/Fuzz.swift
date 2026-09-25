import Foundation

/// Deterministic campaign. The same seed replays the same notes and the same damaged sheets.
enum Fuzz {
    static let seed: UInt64 = 0xF022_51A7_C1B0_4E11

    static func run(rounds: Int, mutations: Int) -> String? {
        if let error = directed() { return error }
        var rng = SplitMix64(seed: seed)
        let lexicon = [
            "oak", "river", "clock", "stone", "maple", "north", "glass", "ember",
            "quiet", "cedar", "harbor", "violet", "paper", "lantern", "silver", "brook",
        ]
        for round in 0..<rounds {
            let words = pickWords(&rng, from: lexicon)
            let note = randomNote(&rng)
            do {
                let sealed = try NoteCipher.encrypt(note: note, words: words)
                let opened = try NoteCipher.decrypt(sheet: sealed.sheet, words: words)
                if opened.note != note { return "fuzz round \(round) changed the note" }
                if note.isEmpty {
                    if sealed.codes != 0 || !sealed.sheet.isEmpty {
                        return "fuzz round \(round) wrote a sheet for an empty note"
                    }
                } else {
                    if opened.salt != sealed.salt || opened.nonce != sealed.nonce {
                        return "fuzz round \(round) dropped the salt or the nonce"
                    }
                    guard let bucket = NoteCipher.paddedLength(note.utf8.count) else {
                        return "fuzz round \(round) has no bucket"
                    }
                    if sealed.paddedBytes != bucket { return "fuzz round \(round) padded to \(sealed.paddedBytes)" }
                    let frame = 1 + 4 + bucket + 2
                    if sealed.codes != frame * 2 { return "fuzz round \(round) wrote \(sealed.codes) codes" }
                    let again = try NoteCipher.encrypt(note: note, words: words)
                    if again.sheet == sealed.sheet { return "fuzz round \(round) repeated a sheet" }
                    if again.salt == sealed.salt || again.nonce == sealed.nonce {
                        return "fuzz round \(round) repeated a salt or a nonce"
                    }
                }
            } catch {
                return "fuzz round \(round): \(error)"
            }
        }

        let words = ["oak", "river", "clock", "stone"]
        let note = "Meet at noon"
        let salt = NoteCipher.unhex("00112233445566778899aabbccddeeff")!
        let nonce = NoteCipher.unhex("0102030405060708090a0b0c")!
        let pad = [UInt8](repeating: 0x3C, count: 20)
        let sealed: SealedNote
        do {
            sealed = try NoteCipher.encrypt(note: note, words: words, salt: salt, nonce: nonce, pad: pad)
        } catch {
            return "fuzz base: \(error)"
        }
        var damage = SplitMix64(seed: seed &+ 99)
        for index in 0..<mutations {
            let mutated = mutate(sealed.sheet, &damage)
            do {
                let opened = try NoteCipher.decrypt(sheet: mutated, words: words)
                if opened.note != note { return "fuzz mutation \(index) opened a different note" }
            } catch is CipherError {
            } catch {
                return "fuzz mutation \(index): \(error)"
            }
        }
        return nil
    }

    /// Sheets that are damaged on purpose. Each one has to be refused.
    private static func directed() -> String? {
        let words = ["oak", "river", "clock", "stone"]
        let note = "Meet at noon"
        let salt = NoteCipher.unhex("00112233445566778899aabbccddeeff")!
        let nonce = NoteCipher.unhex("0102030405060708090a0b0c")!
        let pad = [UInt8](repeating: 0x3C, count: 20)
        let sealed: SealedNote
        do {
            sealed = try NoteCipher.encrypt(note: note, words: words, salt: salt, nonce: nonce, pad: pad)
        } catch {
            return "fuzz directed: \(error)"
        }
        let parts: SheetParts
        do {
            parts = try NoteCipher.parseSheet(sealed.sheet)
        } catch {
            return "fuzz parse: \(error)"
        }

        var flippedSalt = salt
        flippedSalt[0] ^= 0x01
        var flippedNonce = nonce
        flippedNonce[0] ^= 0x01
        var swapped = parts.codes
        let partner = swapped.firstIndex(where: { $0 != swapped[0] }) ?? 0
        if partner != 0 { swapped.swapAt(0, partner) }
        var dropped = parts.codes
        dropped.removeLast()
        var extra = parts.codes
        extra.append(Code.all[0])

        let attacks: [(String, String, CipherError)] = [
            ("missing header", parts.codes.map(\.sheet).joined(separator: " "), .notSheet),
            ("newer version", sealed.sheet.replacingOccurrences(of: NoteCipher.formatMark, with: "RECRYPTO/3"), .newerSheet),
            ("older version", sealed.sheet.replacingOccurrences(of: NoteCipher.formatMark, with: NoteCipher.olderMark), .olderSheet),
            ("short salt", sealed.sheet.replacingOccurrences(of: "salt \(NoteCipher.hex(salt))", with: "salt 00ff"), .badSalt),
            ("short nonce", sealed.sheet.replacingOccurrences(of: "nonce \(NoteCipher.hex(nonce))", with: "nonce 00ff"), .badNonce),
            ("flipped salt", NoteCipher.formatSheet(salt: flippedSalt, nonce: nonce, codes: parts.codes), .refuses),
            ("flipped nonce", NoteCipher.formatSheet(salt: salt, nonce: flippedNonce, codes: parts.codes), .refuses),
            ("swapped cards", NoteCipher.formatSheet(salt: salt, nonce: nonce, codes: swapped), .refuses),
            ("dropped card", NoteCipher.formatSheet(salt: salt, nonce: nonce, codes: dropped), .refuses),
            ("extra card", NoteCipher.formatSheet(salt: salt, nonce: nonce, codes: extra), .refuses),
            ("garbage", "hello there", .notSheet),
            ("header only", NoteCipher.formatMark, .notSheet),
            ("wrong screen setup", sealed.sheet, .refuses),
        ]
        for attack in attacks {
            let screen = attack.0 == "wrong screen setup"
                ? ["oak", "river", "clock", "pebble"]
                : words
            do {
                _ = try NoteCipher.decrypt(sheet: attack.1, words: screen)
                return "fuzz \(attack.0) opened"
            } catch let error as CipherError {
                if error != attack.2 { return "fuzz \(attack.0) threw \(error)" }
            } catch {
                return "fuzz \(attack.0): \(error)"
            }
        }

        let huge = ([NoteCipher.formatMark, "salt \(NoteCipher.hex(salt))", "nonce \(NoteCipher.hex(nonce))"]
            + Array(repeating: "1.2.3", count: NoteCipher.maxSheetCodes + 1)).joined(separator: "\n")
        do {
            _ = try NoteCipher.decrypt(sheet: huge, words: words)
            return "fuzz huge sheet opened"
        } catch CipherError.longSheet {
        } catch {
            return "fuzz huge sheet: \(error)"
        }
        return nil
    }

    private static func pickWords(_ rng: inout SplitMix64, from lexicon: [String]) -> [String] {
        var pool = lexicon
        var words: [String] = []
        while words.count < 4 {
            let index = rng.int(below: pool.count)
            words.append(pool.remove(at: index))
        }
        return words
    }

    private static func randomNote(_ rng: inout SplitMix64) -> String {
        let kind = rng.int(below: 8)
        if kind == 0 { return "" }
        if kind == 1 { return "café 🔐" }
        if kind == 2 { return "line one\nline two" }
        let length = 1 + rng.int(below: kind == 3 ? 48 : 17)
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(length)
        for _ in 0..<length {
            let value = 32 + rng.int(below: 95)
            scalars.append(UnicodeScalar(value)!)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// One local edit. A whitespace-only edit may still open; the caller allows that when the note matches.
    private static func mutate(_ sheet: String, _ rng: inout SplitMix64) -> String {
        var chars = Array(sheet)
        guard !chars.isEmpty else { return "x" }
        switch rng.int(below: 4) {
        case 0:
            let index = rng.int(below: chars.count)
            let value = 32 + rng.int(below: 95)
            chars[index] = Character(UnicodeScalar(value)!)
        case 1:
            let index = rng.int(below: chars.count)
            let span = min(chars.count - index, 1 + rng.int(below: 6))
            chars.removeSubrange(index..<(index + span))
        case 2:
            let index = rng.int(below: chars.count + 1)
            chars.insert(contentsOf: " 4.4.1 ", at: index)
        default:
            let index = rng.int(below: chars.count)
            chars = Array(chars.prefix(index))
        }
        return String(chars)
    }
}
