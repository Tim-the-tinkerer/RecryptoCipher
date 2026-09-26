# RECRYPTO/2

Wire format for a Recrypto sheet. This document is the source of truth.

A sheet is UTF-8 text. The four words are the secret and stay off the sheet. The salt and the nonce travel with the codes. This is a puzzle cipher: the keystream is SplitMix64, seeded by FNV-1a of the screen.

An empty note is an empty file. Every other note is the layout below.

## Sheet

```
RECRYPTO/2
salt <32 hex digits, 16 bytes>
nonce <24 hex digits, 12 bytes>
<codes, eight a line>
```

Writers use line feed, lowercase hex, and codes written `4.2.1`. A final line feed is allowed. Readers skip blank lines. Hex may be upper or lower case. The labels `salt` and `nonce` are matched without case.

The first word of the first line is the version.

| First word | Meaning |
|------------|---------|
| `RECRYPTO/2` | This format. The rest of that line is empty. |
| `RECRYPTO/1` | A sheet sealed before the XOR layer. It is refused. Seal the note again. |
| `RECRYPTO/` and anything else | A version this document does not describe. Refused. |
| anything else | Not a Recrypto sheet. |

`salt` is the second non-empty line and is exactly 16 bytes. `nonce` is the third and is exactly 12 bytes. The remaining text is the codes.

## Codes

A code is three different digits from 1 to 4. There are 24, generated with `x`, then `y`, then `z`, each running from 1 to 4, skipping a digit already used in that code. Index 0 is `1.2.3`. Index 23 is `4.3.2`.

```
1.2.3  1.2.4  1.3.2  1.3.4  1.4.2  1.4.3
2.1.3  2.1.4  2.3.1  2.3.4  2.4.1  2.4.3
3.1.2  3.1.4  3.2.1  3.2.4  3.4.1  3.4.2
4.1.2  4.1.3  4.2.1  4.2.3  4.3.1  4.3.2
```

Readers accept `4.2.1`, `4-2-1`, `4·2·1`, `4•2•1`, `4/2/1`, and `421`. A lone digit from 1 to 4 joins the next lone digits until three have arrived. A group left short of three is refused. Tokens separate on whitespace, comma, semicolon, or `|`.

A sheet longer than 20000 codes is refused before the codes are walked. The longest note in this format produces 16398 codes.

## Screen

The screen is four words. Writers of a words file use this shape, and the words stay in a file of their own:

```
RECRYPTO SCREEN
1 oak
2 river
3 clock
4 stone
```

Five non-empty lines. The number may be written `1`, `1.`, `1)`, or `1:`. The four numbers each appear once and may arrive out of order. A word is at most 32 characters after its whitespace is collapsed. Two words that fold to the same key are refused. `black` and `blackboard` are different words.

Folding, applied before the seed and again when a sheet is opened: fold case and accents with the `en_US` locale, lowercase, turn every scalar that is not a letter, a digit, or a space into a space, then collapse whitespace. The seed material is those four keys joined by U+001F.

## Pipeline

```
UTF-8 note
  → frame (marker, length, note, pad, CRC-16)
  → XOR keystream over the whole frame
  → two base-24 digits per whitened byte
  → modulo-24 mask on each digit
  → one fresh shuffle of the 24-card deck per digit
  → RECRYPTO/2 sheet
```

Recovery walks that list from the bottom. The XOR step reverses itself. The marker, the length, and the CRC are checked after the XOR is removed.

## Size buckets

A note is 1 to 8000 bytes. It is stored in the smallest bucket that can hold it:

```
32, 64, 128, 256, 512, 1024, 2048, 4096, 8192
```

The bytes after the note and before the CRC are the pad. Writers fill that slack with random bytes. A note whose length already equals its bucket has an empty pad. Notes in one bucket produce the same number of codes:

```
codes = 2 × (bucket + 7)
```

That is two digits for each frame byte. The frame is `1 + 4 + bucket + 2` bytes.

## Frame

The frame is built before the XOR. Multi-byte integers are big-endian.

| Offset | Bytes | Contents |
|--------|------:|----------|
| 0 | 1 | Marker `0x52` |
| 1 | 4 | Note length, 1 … 8000 |
| 5 | length | Note, UTF-8 |
| 5 + length | bucket − length | Pad |
| 5 + bucket | 2 | CRC-16 of everything from the length through the pad |

The CRC is CRC-16/CCITT-FALSE: init `0xFFFF`, polynomial `0x1021`, high byte first. For each data byte, XOR it into the high half of the register, then eight times shift left and, when the bit that shifts out is set, XOR with `0x1021`. The check value of the ASCII bytes `123456789` is `0x29B1`. The empty input is `0xFFFF`.

The CRC does not cover the marker. The XOR that follows covers the marker, the length, the note, the pad, and the CRC.

A recovered frame is refused unless the marker is `0x52`, the length fits a bucket, the byte count is exactly `bucket + 7`, and the CRC matches. The note is the `length` bytes after the length field. Those bytes must be UTF-8.

## Three streams

Each stream is its own SplitMix64. The seed is FNV-1a 64, domain-separated by a label. The offset basis is `14695981039346656037`. The prime is `1099511628211`. Arithmetic is on unsigned 64-bit words, wrapping.

`FNV(text)` starts at the offset basis. For each UTF-8 byte: XOR the byte in, then multiply by the prime.

`fold(label, material, chunks)` is:

1. Start from `FNV(label)`.
2. XOR in `0x1F`, multiply by the prime, then fold each UTF-8 byte of `material` the same way.
3. For each chunk, XOR in `0x1E`, multiply by the prime, then fold each raw byte of the chunk.

| Stream | Label | Chunks | What one step draws |
|--------|-------|--------|---------------------|
| Deck | `DECK` | salt | `int(below: n) = next() mod n`, 23 draws per shuffle |
| Mask | `MASK` | salt, then nonce | `int(below: 24)`, one draw per digit |
| XOR | `XOR` | salt, then nonce | the low 8 bits of `next()`, one byte per frame byte |

The nonce is not an input to the deck seed. The mask and the XOR see the same chunks under different labels, and each starts a new generator. Neither continues the state of another stream.

SplitMix64, with wrapping addition and multiplication:

```
state = seed + 0x9E3779B97F4A7C15

next:
    state = state + 0x9E3779B97F4A7C15
    z = state
    z = (z xor (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z xor (z >> 27)) * 0x94D049BB133111EB
    return z xor (z >> 31)
```

The modulo in `int(below:)` is part of the deck and the mask. The XOR byte is `next() & 0xFF`, which for this generator is the same value as `next() mod 256`, taken from the XOR stream alone.

One Fisher–Yates pass copies the deck in table order and lets `index` run from 23 down to 1. At each index it draws `swap = int(below: index + 1)` and exchanges those two cards when they differ. That is 23 draws. The pass always runs to the end, so encrypt and decrypt stay on the same stream.

For digit `d` in `0 … 23`, the card is the shuffled deck at `(d + mask) mod 24`. The shuffle for that digit is drawn before its mask. A byte `b` is the pair of digits `b / 24`, then `b mod 24`. On the way back, a high digit of 11 or more is refused, because a byte stops at 255.

## Pinned sheet

Screen `oak`, `river`, `clock`, `stone`. Salt `00112233445566778899aabbccddeeff`. Nonce `0102030405060708090a0b0c`. Every pad byte is `0xA5`. The note is `Meet at noon` (12 bytes, bucket 32, 78 codes):

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

The same screen with capitals or extra spaces opens that sheet. A different word, a flipped salt byte, a flipped nonce byte, or one swapped card does not.
