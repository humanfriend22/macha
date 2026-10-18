import Foundation

/// Reads a secret from the terminal, echoing one `*` per character typed.
/// Unlike `getpass`, it has no length limit and copes with pasted text and backspace.
enum SecretInput {
    static func read(prompt: String) -> String? {
        print(prompt, terminator: "")
        fflush(stdout)

        // Piped input (no terminal): nothing to mask, read a plain line.
        guard isatty(STDIN_FILENO) == 1 else { return readLine() }

        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        raw.c_cc.16 = 1  // VMIN: wait for at least one byte
        raw.c_cc.17 = 0  // VTIME: no timeout
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }

        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        var sawInput = false

        func erase(_ count: Int) {
            guard count > 0 else { return }
            print(String(repeating: "\u{8} \u{8}", count: count), terminator: "")
            fflush(stdout)
        }
        // UTF-8 continuation bytes (10xxxxxx) belong to the previous character.
        func isLead(_ b: UInt8) -> Bool { b & 0xC0 != 0x80 }
        func characterCount() -> Int { bytes.filter(isLead).count }

        loop: while Darwin.read(STDIN_FILENO, &byte, 1) == 1 {
            sawInput = true
            switch byte {
            case 10, 13:
                break loop
            case 3:  // Ctrl-C: restore the terminal, then quit
                tcsetattr(STDIN_FILENO, TCSANOW, &original)
                print("")
                Darwin.exit(130)
            case 4:  // Ctrl-D
                if bytes.isEmpty { return nil }
                break loop
            case 8, 127:  // backspace
                var removed = false
                while let last = bytes.popLast() {
                    removed = true
                    if isLead(last) { break }
                }
                if removed { erase(1) }
            case 21:  // Ctrl-U: clear everything typed
                erase(characterCount())
                bytes.removeAll()
            case 27:  // escape sequence (arrow keys, bracketed paste markers): skip it
                var next: UInt8 = 0
                if Darwin.read(STDIN_FILENO, &next, 1) == 1, next == UInt8(ascii: "[") {
                    while Darwin.read(STDIN_FILENO, &next, 1) == 1, !(0x40...0x7E).contains(next) {}
                }
            case 0..<32:
                continue
            default:
                bytes.append(byte)
                if isLead(byte) {
                    print("*", terminator: "")
                    fflush(stdout)
                }
            }
        }
        print("")
        if !sawInput { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
