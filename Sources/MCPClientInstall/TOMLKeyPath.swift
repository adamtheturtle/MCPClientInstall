import Foundation

func splitTOMLKeyPath(_ value: String) -> [String]? {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var quotedComponent = false
    var closedQuote = false
    var index = value.startIndex

    while index < value.endIndex {
        let character = value[index]
        if let activeQuote = quote {
            if activeQuote == "\"", character == "\\" {
                guard let escape = tomlEscape(in: value, after: index) else { return nil }
                current += escape.value
                index = escape.nextIndex
                continue
            } else if character == activeQuote {
                quote = nil
                closedQuote = true
            } else {
                current.append(character)
            }
        } else if character == "\"" || character == "'" {
            guard current.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            current = ""
            quote = character
            quotedComponent = true
        } else if character == "." {
            let key = quotedComponent ? current : current.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            result.append(key)
            current = ""
            quotedComponent = false
            closedQuote = false
        } else if closedQuote {
            guard character.isWhitespace else { return nil }
        } else {
            current.append(character)
        }
        index = value.index(after: index)
    }

    guard quote == nil else { return nil }
    let key = quotedComponent ? current : current.trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    result.append(key)
    return result
}

private func tomlEscape(
    in text: String,
    after backslash: String.Index
) -> (value: String, nextIndex: String.Index)? {
    let escapeIndex = text.index(after: backslash)
    guard escapeIndex < text.endIndex else { return nil }

    switch text[escapeIndex] {
    case "b": return ("\u{08}", text.index(after: escapeIndex))
    case "t": return ("\t", text.index(after: escapeIndex))
    case "n": return ("\n", text.index(after: escapeIndex))
    case "f": return ("\u{0C}", text.index(after: escapeIndex))
    case "r": return ("\r", text.index(after: escapeIndex))
    case "e": return ("\u{1B}", text.index(after: escapeIndex))
    case "\"": return ("\"", text.index(after: escapeIndex))
    case "\\": return ("\\", text.index(after: escapeIndex))
    case "x": return tomlUnicodeEscape(in: text, after: escapeIndex, width: 2)
    case "u": return tomlUnicodeEscape(in: text, after: escapeIndex, width: 4)
    case "U": return tomlUnicodeEscape(in: text, after: escapeIndex, width: 8)
    default: return nil
    }
}

private func tomlUnicodeEscape(
    in text: String,
    after marker: String.Index,
    width: Int
) -> (value: String, nextIndex: String.Index)? {
    let digitsStart = text.index(after: marker)
    guard let digitsEnd = text.index(
        digitsStart,
        offsetBy: width,
        limitedBy: text.endIndex
    ) else { return nil }

    let digits = text[digitsStart ..< digitsEnd]
    guard digits.utf8.allSatisfy(\.isASCIIHexDigit),
          let scalarValue = UInt32(digits, radix: 16),
          let scalar = Unicode.Scalar(scalarValue)
    else { return nil }

    return (String(scalar), digitsEnd)
}

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(self)
            || (UInt8(ascii: "A") ... UInt8(ascii: "F")).contains(self)
            || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(self)
    }
}
