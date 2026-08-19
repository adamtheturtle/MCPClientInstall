import Foundation

/// Tracks whether a line of TOML continues an unclosed multiline string or
/// array, so that a scanner never reads a value's contents as structure.
struct TOMLLineState {
    private enum StringState { case none, multilineBasic, multilineLiteral }
    private var stringState = StringState.none
    private var bracketDepth = 0

    var isInsideMultilineConstruct: Bool {
        stringState != .none || bracketDepth > 0
    }

    mutating func consume(_ line: String) {
        var index = line.startIndex
        while index < line.endIndex {
            switch stringState {
            case .multilineBasic:
                if line[index] == "\\" {
                    index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                } else if line[index...].hasPrefix("\"\"\"") {
                    stringState = .none
                    index = line.index(index, offsetBy: 3)
                } else {
                    index = line.index(after: index)
                }
            case .multilineLiteral:
                if line[index...].hasPrefix("'''") {
                    stringState = .none
                    index = line.index(index, offsetBy: 3)
                } else {
                    index = line.index(after: index)
                }
            case .none:
                switch line[index] {
                case "#": return
                case "\"" where line[index...].hasPrefix("\"\"\""):
                    stringState = .multilineBasic
                    index = line.index(index, offsetBy: 3)
                case "'" where line[index...].hasPrefix("'''"):
                    stringState = .multilineLiteral
                    index = line.index(index, offsetBy: 3)
                case "\"":
                    index = endOfString(in: line, from: line.index(after: index), quote: "\"", escaped: true)
                case "'":
                    index = endOfString(in: line, from: line.index(after: index), quote: "'", escaped: false)
                case "[": bracketDepth += 1; index = line.index(after: index)
                case "]": bracketDepth = max(0, bracketDepth - 1); index = line.index(after: index)
                default: index = line.index(after: index)
                }
            }
        }
    }

    private func endOfString(
        in line: String,
        from start: String.Index,
        quote: Character,
        escaped: Bool
    ) -> String.Index {
        var index = start
        while index < line.endIndex {
            if escaped, line[index] == "\\" {
                index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
            } else if line[index] == quote {
                return line.index(after: index)
            } else {
                index = line.index(after: index)
            }
        }
        return index
    }
}

private extension Array where Element == String {
    func starts(with prefix: [String]) -> Bool {
        count >= prefix.count && Array(self.prefix(prefix.count)) == prefix
    }
}
