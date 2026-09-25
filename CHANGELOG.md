# Changelog

## 1.1.0

- The sealed frame is XORed with its own keystream before the bytes become cards. Deck, digit mask, and XOR each have a label of their own: `DECK`, `MASK`, and `XOR`.
- Sheets are `RECRYPTO/2`. A `RECRYPTO/1` sheet asks to be sealed again.

## 1.0.0

- Seals a note as code cards. Four words numbered 1 to 4 are the screen. Each sheet draws a 16-byte salt and a 12-byte nonce, and the note is padded to a size bucket.
- The salt chooses the shuffle. The nonce shifts every digit. Two cards carry each sealed byte. The salt and the nonce are written on the sheet. The four words stay off it.
- Encrypt ⌘E, Decrypt ⌘D, Clear ⌘K. Command-line `--encrypt`, `--decrypt`, and `--fuzz`.
