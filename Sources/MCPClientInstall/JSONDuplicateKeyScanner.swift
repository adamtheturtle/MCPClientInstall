import Foundation

extension MCPClientInstall {
    static func rejectDuplicateJSONKeys(in data: Data) throws {
        var scanner = JSONDuplicateKeyScanner(bytes: Array(data))
        do {
            try scanner.scan()
        } catch let error as JSONConfigError {
            throw error
        } catch JSONScanFailure.malformed {
            throw CocoaError(.propertyListReadCorrupt)
        } catch {
            // JSONSerialization remains the source of truth for general syntax
            // errors outside the scanner's bounded nesting depth. This pass also
            // retains duplicate-key information that Foundation would discard.
        }
    }
}

private enum JSONScanFailure: Error {
    case malformed
    case tooDeep
}

private struct JSONDuplicateKeyScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func scan() throws {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw JSONScanFailure.malformed }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= 128, index < bytes.count else {
            throw depth > 128 ? JSONScanFailure.tooDeep : JSONScanFailure.malformed
        }
        skipWhitespace()
        guard index < bytes.count else { throw JSONScanFailure.malformed }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            try parseObject(depth: depth)
        case UInt8(ascii: "["):
            try parseArray(depth: depth)
        case UInt8(ascii: "\""):
            _ = try parseString()
        default:
            try parsePrimitive()
        }
    }

    private mutating func parseObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw JSONScanFailure.malformed
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw MCPClientInstall.JSONConfigError.duplicateKey(key)
            }
            skipWhitespace()
            guard consume(UInt8(ascii: ":")) else { throw JSONScanFailure.malformed }
            skipWhitespace()
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return }
            guard consume(UInt8(ascii: ",")) else { throw JSONScanFailure.malformed }
            skipWhitespace()
            guard index < bytes.count, bytes[index] != UInt8(ascii: "}") else {
                throw JSONScanFailure.malformed
            }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return }
        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return }
            guard consume(UInt8(ascii: ",")) else { throw JSONScanFailure.malformed }
            skipWhitespace()
            guard index < bytes.count, bytes[index] != UInt8(ascii: "]") else {
                throw JSONScanFailure.malformed
            }
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                index += 1
                let token = Data(bytes[start ..< index])
                guard let value = try JSONSerialization.jsonObject(
                    with: token, options: [.fragmentsAllowed]
                ) as? String else { throw JSONScanFailure.malformed }
                return value
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw JSONScanFailure.malformed }
                if bytes[index] == UInt8(ascii: "u") {
                    guard index + 4 < bytes.count else { throw JSONScanFailure.malformed }
                    index += 5
                } else {
                    index += 1
                }
            case 0 ..< 0x20:
                throw JSONScanFailure.malformed
            default:
                index += 1
            }
        }
        throw JSONScanFailure.malformed
    }

    private mutating func parsePrimitive() throws {
        let start = index
        while index < bytes.count,
              !bytes[index].isJSONWhitespace,
              ![UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}")].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw JSONScanFailure.malformed }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, bytes[index].isJSONWhitespace { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}

private extension UInt8 {
    var isJSONWhitespace: Bool {
        self == UInt8(ascii: " ") || self == UInt8(ascii: "\t")
            || self == UInt8(ascii: "\n") || self == UInt8(ascii: "\r")
    }
}
