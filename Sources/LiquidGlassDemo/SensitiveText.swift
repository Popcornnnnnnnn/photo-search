import Foundation

/// Masks common high-risk strings produced by OCR/model annotations. The source
/// data stays untouched; this only controls its default presentation in the UI.
enum SensitiveText {
    private static let cardNumber = try! NSRegularExpression(
        pattern: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#
    )
    private static let phoneNumber = try! NSRegularExpression(
        pattern: #"(?<!\d)1[3-9]\d{9}(?!\d)"#
    )
    private static let email = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Z0-9._%+-])([A-Z0-9._%+-])[^@\s]*@([A-Z0-9.-]+\.[A-Z]{2,})(?![A-Z0-9._%+-])"#
    )

    static func redact(_ text: String) -> String {
        var result = replace(in: text, using: cardNumber) { match in
            let digits = match.filter(\.isNumber)
            guard digits.count >= 4 else { return "••••" }
            return "•••• •••• •••• \(digits.suffix(4))"
        }
        result = replace(in: result, using: phoneNumber) { match in
            let digits = match.filter(\.isNumber)
            return "1•• •••• \(digits.suffix(4))"
        }
        result = replace(in: result, using: email) { match in
            guard let at = match.firstIndex(of: "@") else { return "••••" }
            let first = match.first.map(String.init) ?? "•"
            return "\(first)•••\(match[at...])"
        }
        return result
    }

    static func containsSensitiveContent(_ text: String) -> Bool {
        redact(text) != text
    }

    private static func replace(in text: String,
                                using expression: NSRegularExpression,
                                transform: (String) -> String) -> String {
        var output = text
        let range = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: output) else { continue }
            output.replaceSubrange(swiftRange, with: transform(String(output[swiftRange])))
        }
        return output
    }
}
