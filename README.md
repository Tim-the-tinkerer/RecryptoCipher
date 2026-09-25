# Recrypto Cipher

A note sealed as code cards. Four secret words, numbered 1 to 4, are the screen. What you send is a sheet: a salt, a nonce, and codes such as `4.2.1`. The words stay off the sheet.

Each seal draws a new salt and a new nonce, and the note is padded out to a size bucket, so the same note sealed twice is a different sheet of the same length.

This is a puzzle cipher in the form of [Decrypto](../Decrypto), built beside [Decrypto Cipher](../DecryptoCipher). It is a separate sheet. Anyone who learns the four words can read it.

Unofficial. Decrypto was designed by Thomas Dagenais-Lespérance and published by Le Scorpion Masqué. This app is not affiliated with them.

## Seal a note

Type the four words. Both sides use the same words in the same order. Capitals and accents fold together: Oak and oak are one word.

Type the note and press Encrypt (⌘E). The sheet lands on the right, with `RECRYPTO/2`, the salt, and the nonce above the codes. Copy Sheet is what you hand over.

Decrypt (⌘D) reads the salt and the nonce from the sheet and the four words from the screen. A sheet opened with the wrong screen is refused.

Clear (⌘K) wipes the four words, the note, and the sheet.

Drop a text file on the note, or a sheet on the sheet. A file dropped on the rest of the window, or onto the app, is a sheet when it begins with `RECRYPTO/2` or every token is a code, a screen when it is a saved words file, and a note otherwise. Open Note is ⌘O. Open Sheet is ⌘⇧O.

Export (⌘⇧S) writes the sheet as a text file and asks where to put it. The salt and the nonce are part of that file. The file you dropped is left alone. The four words are not in the exported file.

Save Words (⌘⌥S) writes the four words that sealed the sheet. The file looks like this:

```
RECRYPTO SCREEN
1 oak
2 river
3 clock
4 stone
```

Keep it with you, and send the sheet on its own. Open Words is ⌘⌥O. A screen file dropped on the screen, or on the window, fills the four words. If a note named `Meeting.txt` was opened, the suggested names are `Meeting sheet.txt` and `Meeting words.txt`.

Under the sheet, each code is listed with the three words it names, in digit order. That list is for your eyes. To pass a short note the way a round is passed, give one clue for each of those words and keep the digits. The app leaves the clues to you.

## Command line

```bash
RecryptoCipher --encrypt \
    --1 oak --2 river --3 clock --4 stone \
    --message "Meet at noon"

RecryptoCipher --decrypt \
    --1 oak --2 river --3 clock --4 stone \
    --file sheet.txt
```

`--file` reads the note or the sheet. With neither `--message` nor `--sheet`, the text comes from stdin. `--salt` and `--nonce` take hex, 16 bytes and 12 bytes, when a seal should use those values. Omit them and the app draws fresh ones. Decrypt reads both from the sheet.

`--self-test` runs the cipher checks, including a fuzz pass. `--fuzz` runs a longer one: hundreds of random notes, then sheets with a character, a span, or the tail disturbed. A damaged sheet is refused, or it still opens to the same note.

With the screen oak, river, clock, stone, salt `00112233445566778899aabbccddeeff`, nonce `0102030405060708090a0b0c`, and pad bytes `0xA5`, the note “Meet at noon” seals as:

```
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
```

A code may be written `4.2.1`, `4-2-1`, `4·2·1`, `421`, or as three separate digits. Hex on the salt and nonce lines may be upper or lower case.

## Method

The deck is the 24 codes of three different digits from 1 to 4, generated in the same order as the table: `1.2.3` first, `4.3.2` last.

The screen is the four words after the table’s folding (case and accents dropped, punctuation turned into spaces), joined by the unit separator U+001F.

The salt is 16 bytes from `SecRandomCopyBytes`. The nonce is 12 bytes, drawn the same way. Both are written on the sheet:

```
RECRYPTO/2
salt 00112233445566778899aabbccddeeff
nonce 0102030405060708090a0b0c
```

Three seeds are FNV-1a 64, domain-separated. Start from the hash of the label, mix in `0x1F` and the screen string, then for each chunk mix in `0x1E` and the raw bytes. The prime is `1099511628211`. The label is what keeps the streams from being three readings of one key.

- Deck seed: label `DECK`, then the screen, then the salt.
- Mask seed: label `MASK`, then the screen, then the salt, then the nonce.
- XOR seed: label `XOR`, then the screen, then the salt, then the nonce.

Each seed starts its own SplitMix64 stream. The streams are not handed off to one another.

The deck stream runs one Fisher–Yates pass over the whole deck before every card and keeps going. It is not reseeded. The modulo used to draw an index is part of the cipher. The mask stream draws `int(below: 24)` and the digit that selects the card is `(digit + mask) mod 24`.

The XOR stream takes the low 8 bits of each SplitMix64 step, one byte for each byte of the finished frame:

```
cipherByte[i] = frameByte[i] XOR xorStream[i]
```

The same call puts the frame back, because XOR reverses itself. Decrypt undoes the cards, undoes the digit mask, undoes the XOR, then checks the marker, the length, and the CRC.

A non-empty note is its UTF-8 bytes, at most 8000 of them. It is padded with random bytes up to the smallest of these buckets that can hold it: 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192. Notes in one bucket leave the same number of codes.

The frame is marker `0x52`, the real length as four bytes, the note, the pad, and CRC-16/CCITT-FALSE (init `0xFFFF`, polynomial `0x1021`) of the length, the note, and the pad, high byte first. The check value of `123456789` is `0x29B1`. The XOR covers that whole frame, marker and CRC included.

Each whitened byte becomes two base-24 digits, high digit first (`byte / 24`, then `byte % 24`). Each digit is one card. The sheet prints eight codes on a line. An empty note is an empty sheet. A sheet that does not open with these words is refused.

The XOR step uses the same FNV-1a and SplitMix64 family as the deck and the mask. It is another layer of the puzzle. The four words are still what opens the sheet. A `RECRYPTO/1` sheet, sealed before this layer, asks to be sealed again.

## Build

Requires macOS 13 and Xcode’s Swift toolchain.

```bash
./build-app.sh
```

That builds a release binary, runs `--self-test`, signs `RecryptoCipher.app` ad hoc, and opens it. `--no-launch` skips opening the app.

```bash
swift run RecryptoCipher --self-test
swift run RecryptoCipher --fuzz
```
