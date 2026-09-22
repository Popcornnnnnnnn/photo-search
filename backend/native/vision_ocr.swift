import Foundation
import ImageIO
import Vision

struct OCRLine: Codable {
    let text: String
    let confidence: Float
    let boundingBox: [Double]

    enum CodingKeys: String, CodingKey {
        case text
        case confidence
        case boundingBox = "bounding_box"
    }
}

struct OCRResult: Codable {
    let text: String
    let lines: [OCRLine]
    let languages: [String]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: vision-ocr IMAGE")
}

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fail("unable to read image: \(path)")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"]
let supported = (try? request.supportedRecognitionLanguages()) ?? []
request.recognitionLanguages = preferredLanguages.filter { supported.contains($0) }

do {
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    let observations = request.results ?? []
    let lines: [OCRLine] = observations.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return OCRLine(
            text: candidate.string,
            confidence: candidate.confidence,
            boundingBox: [box.origin.x, box.origin.y, box.size.width, box.size.height]
        )
    }
    let result = OCRResult(
        text: lines.map(\.text).joined(separator: "\n"),
        lines: lines,
        languages: request.recognitionLanguages
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(result)
    FileHandle.standardOutput.write(encoded)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("vision OCR failed: \(error)")
}
