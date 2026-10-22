import Foundation
import Accelerate
import GRDB

/// Native port of the backend's hybrid retrieval (`backend/photo_search/search.py`).
///
/// Scoring order, thresholds, and fallback behaviour are kept deliberately in step
/// with the Python implementation so the app ranks identically without a loopback
/// service. Queries without a vector fall back to text matches and say so in the notice.
enum PhotoSearchEngine {
    static let minTextCoverage = 0.50
    static let defaultLimit = 100

    // Thresholds, fusion order, and the embedding contract are kept in step with
    // backend/photo_search/search.py and backend/photo_search/embeddings.py.
    private static let minVisualSimilarity = 0.40
    private static let minUncorroboratedVisualSimilarity = 0.45
    private static let minVisualTextCoverage = 0.25
    // Text-encoded video summaries have a higher unrelated-query baseline than
    // image vectors. Keep their recall gate separate so they cannot crowd out
    // relevant photos merely by clearing the image threshold.
    private static let minVideoSimilarity = 0.55
    private static let lexicalConfidenceRatio = 1.5
    private static let fusionCandidates = 100
    private static let embeddingNamespace = "image-retrieval-v1"
    private static let embeddingModel = "Qwen/Qwen3-VL-Embedding-2B"
    private static let embeddingRevision = "9f2f7e710d6d81056aa5c0a4f04764fec6bb7bda"
    private static let embeddingPrompt = "official-wrapper-393e2978:document-default-v1"
    private static let videoEmbeddingNamespace = "video-retrieval-v1"
    private static let videoEmbeddingPrompt = "official-wrapper-393e2978:video-summary-v1"
    private static let embeddingDimensions = 2048

    static func search(
        query: String,
        section: PhotoSection,
        limit: Int = defaultLimit,
        databasePath: String = PhotoSearchDatabase.path,
        queryVector: [Float]? = nil,
        interval: DateInterval? = nil
    ) throws -> PhotoSearchDatabase.Output {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try PhotoSearchDatabase.fetch(section: section, databasePath: databasePath, interval: interval)
        }

        let queryLower = trimmed.lowercased()
        let terms = fallbackTerms(trimmed).filter { $0.count >= 2 }
        let identifiers = identifierPattern.flatMap { matches($0, in: queryLower) } ?? []

        return try PhotoSearchDatabase.readVersioned(at: databasePath) { db, revision in
            try Task.checkCancellation()
            let snapshot = try cachedSnapshot(db, path: databasePath, revision: revision,
                                              needsVectors: queryVector != nil)
            let documents = snapshot.documents.filter { document in
                guard section.assetType == nil || document.assetType == section.assetType else { return false }
                guard let interval else { return true }
                guard let value = document.capturedAt, let date = PhotoWorkerStatus.parseTimestamp(value) else { return false }
                return date >= interval.start && date < interval.end
            }
            let stats = snapshot.stats

            let lexical = try lexicalMatches(
                documents: documents, query: trimmed, queryLower: queryLower,
                terms: terms, identifiers: identifiers
            )
            let strongTextIDs = Set(
                lexical.filter { $0.textCoverage >= minTextCoverage }.map(\.document.assetID)
            )
            let supportedTextIDs = Set(
                lexical.filter { $0.textCoverage >= minVisualTextCoverage }.map(\.document.assetID)
            )

            var ranked: [VisualMatch] = []
            var visualSearchRan = false
            if let queryVector, !queryVector.isEmpty {
                let texts = Dictionary(documents.map { ($0.assetID, $0.searchTextLower) },
                                       uniquingKeysWith: { first, _ in first })
                let vectors = (snapshot.embeddings ?? []).filter { candidate in
                    guard let text = texts[candidate.assetID] else { return false }
                    return identifiers.allSatisfy { text.contains($0) }
                }
                visualSearchRan = !vectors.isEmpty
                if visualSearchRan {
                    let vector = normalizedVector(queryVector.map(Double.init))
                    var workspace = [Double](repeating: 0, count: vector.count)
                    ranked = try vectors.enumerated().compactMap { index, candidate in
                        if index.isMultiple(of: 64) { try Task.checkCancellation() }
                        // Partial text evidence can support an image synonym match.
                        // Without it, require a stronger signal than the base gate.
                        let minimumSimilarity = supportedTextIDs.contains(candidate.assetID)
                            ? candidate.minimumSimilarity
                            : max(candidate.minimumSimilarity, minUncorroboratedVisualSimilarity)
                        guard let similarity = cosine(vector, candidate, workspace: &workspace),
                              similarity >= minimumSimilarity else { return nil }
                        return VisualMatch(assetID: candidate.assetID, similarity: similarity)
                    }
                    ranked.sort { lhs, rhs in
                        lhs.similarity == rhs.similarity
                            ? lhs.assetID < rhs.assetID
                            : lhs.similarity > rhs.similarity
                    }
                }
            }

            let ordered: [Ranked]
            if visualSearchRan {
                let eligible = strongTextIDs.union(ranked.map(\.assetID))
                ordered = mergeRankings(lexical: lexical, visual: ranked, limit: fusionCandidates)
                    .filter { eligible.contains($0.assetID) }
            } else {
                ordered = lexical
                    .filter { strongTextIDs.contains($0.document.assetID) }
                    .map {
                        Ranked(assetID: $0.document.assetID, textCoverage: $0.textCoverage,
                               visualSimilarity: nil)
                    }
            }

            let limited = Array(ordered.prefix(limit))
            let documentsByID = Dictionary(
                documents.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first }
            )
            let photos = limited.compactMap { result -> IndexedPhoto? in
                guard var photo = documentsByID[result.assetID]?.photo else { return nil }
                photo.matchEvidence = PhotoMatchEvidence(textMatched: result.textCoverage > 0,
                                                          visualMatched: result.visualSimilarity != nil,
                                                          isVideo: photo.isVideo)
                return photo
            }
            let status: MatchStatus = limited.isEmpty
                ? .none
                : (limited[0].textCoverage >= 0.8 || (limited[0].visualSimilarity ?? 0) >= 0.5)
                    ? .matches : .possible

            return PhotoSearchDatabase.Output(
                photos: photos,
                matchedCount: photos.count,
                stats: stats,
                notice: notice(for: status, visualSearchRan: visualSearchRan),
                noticeTitle: noticeTitle(for: status, visualSearchRan: visualSearchRan),
                indexRevision: revision
            )
        }
    }

    enum MatchStatus {
        case none
        case matches
        case possible
    }

    struct Match {
        let document: Document
        let score: Double
        let matchedTerms: [String]
        let textCoverage: Double
    }

    struct Document {
        let assetID: String
        let assetType: String
        let shortCaption: String
        let searchText: String
        let thumbnailPath: String
        let filePath: String
        let filename: String
        let capturedAt: String?
        let width: Int?
        let height: Int?
        let annotationModel: String?
        let annotationJSON: String?
        var durationSeconds: Double? = nil
        var searchTextLower: String = ""
        var searchBytes = Data()

        var photo: IndexedPhoto {
            IndexedPhoto(
                id: assetID,
                thumbnailPath: thumbnailPath,
                filePath: filePath,
                filename: filename,
                capturedAt: capturedAt,
                width: width,
                height: height,
                assetType: assetType,
                shortCaption: shortCaption,
                model: annotationModel,
                annotation: PhotoAnnotation.decode(annotationJSON),
                durationSeconds: durationSeconds
            )
        }
    }

    // MARK: - Copy

    /// Shown when a query ran without a query vector, so appearance-only matches
    /// could not be considered at all.
    private static let visualSearchUnavailableNotice =
        "Visual search is unavailable · showing text matches. Images that match only by appearance may be missing."

    static func noticeTitle(for status: MatchStatus, visualSearchRan: Bool = false) -> String {
        switch status {
        case .none: "No sufficiently relevant matches"
        case .possible: "Possible matches"
        case .matches: visualSearchRan ? "Matches" : "Visual search unavailable"
        }
    }

    static func notice(for status: MatchStatus, visualSearchRan: Bool = false) -> String? {
        if visualSearchRan {
            return status == .none
                ? "No sufficiently relevant matches were found in indexed photos."
                : nil
        }
        switch status {
        case .none:
            return "No sufficiently relevant matches were found in indexed photos. " + visualSearchUnavailableNotice
        case .possible, .matches:
            return visualSearchUnavailableNotice
        }
    }

    // MARK: - Visual recall

    private static func lexicalMatches(
        documents: [Document],
        query: String,
        queryLower: String,
        terms: [String],
        identifiers: [String]
    ) throws -> [Match] {
        var matches: [Match] = []
        let coverage = Coverage(query: query)
        let queryBytes = Data(queryLower.utf8)
        let termBytes = terms.map { Data($0.utf8) }
        let identifierBytes = identifiers.map { Data($0.utf8) }
        for (index, document) in documents.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let text = document.searchTextLower
            let bytes = document.searchBytes
            guard identifierBytes.allSatisfy({ bytes.range(of: $0) != nil }) else { continue }
            var score = 0.0
            var matched: [String] = []
            if bytes.range(of: queryBytes) != nil {
                score += 12.0
                matched.append(query)
            }
            for (index, term) in terms.enumerated() where bytes.range(of: termBytes[index]) != nil {
                score += max(1.0, 5.0 - Double(index) * 0.15)
                matched.append(term)
            }
            guard score > 0 else { continue }
            matches.append(
                Match(
                    document: document,
                    // Python rounds to three decimals before sorting, so terms that
                    // sum to the same value stay tied and fall back to capture date.
                    score: (score * 1000).rounded(.toNearestOrEven) / 1000,
                    matchedTerms: deduped(matched),
                    textCoverage: coverage.value(in: text, bytes: bytes)
                )
            )
        }
        // Score first, then newest capture, then asset id: the composite order
        // Python gets from two stable sorts.
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let left = lhs.document.capturedAt ?? ""
            let right = rhs.document.capturedAt ?? ""
            if left != right { return left > right }
            return lhs.document.assetID > rhs.document.assetID
        }
        return matches
    }

    struct VisualMatch {
        let assetID: String
        let similarity: Double
    }

    struct Ranked {
        let assetID: String
        let textCoverage: Double
        let visualSimilarity: Double?
    }

    private struct Embedding {
        let assetID: String
        let vector: [Float]
        let length: Double
        let minimumSimilarity: Double
    }

    private struct Fused {
        let assetID: String
        var score: Double = 0
        var textCoverage: Double = 0
        var visualSimilarity: Double?
    }

    private final class Snapshot: NSObject {
        let revision: String
        let documents: [Document]
        let stats: PhotoLibraryStats
        let embeddings: [Embedding]?
        init(revision: String, documents: [Document], stats: PhotoLibraryStats, embeddings: [Embedding]?) {
            self.revision = revision
            self.documents = documents
            self.stats = stats
            self.embeddings = embeddings
        }
        var cost: Int {
            let documentCost = documents.reduce(0) { total, document in
                let textCost = document.searchText.utf8.count * 3
                let annotationCost = document.annotationJSON?.utf8.count ?? 0
                return total + textCost + annotationCost + 512
            }
            let embeddingCost = embeddings?.reduce(0) { total, embedding in
                total + embedding.vector.count * 4 + 128
            } ?? 0
            return documentCost + embeddingCost
        }
    }
    private final class Cache: @unchecked Sendable {
        let storage = NSCache<NSString, Snapshot>()
        init() {
            storage.countLimit = 1
            storage.totalCostLimit = 256 * 1024 * 1024
        }
    }
    private static let cache = Cache()

    static func clearCache() { cache.storage.removeAllObjects() }

    /// A cached snapshot is reused only while the same read connection reports
    /// the same committed data_version. Categories and dates filter that snapshot
    /// before either ranking path runs.
    private static func cachedSnapshot(_ db: Database, path: String, revision: String,
                                       needsVectors: Bool) throws -> Snapshot {
        let existing = cache.storage.object(forKey: path as NSString)
        let current = existing?.revision == revision ? existing : nil
        if let current, !needsVectors || current.embeddings != nil { return current }
        let documents = try current?.documents ?? loadDocuments(db, section: .all)
        let stats = try current?.stats ?? loadStats(db)
        let embeddings = try needsVectors ? loadEmbeddings(db) : nil
        let snapshot = Snapshot(revision: revision, documents: documents, stats: stats, embeddings: embeddings)
        cache.storage.setObject(snapshot, forKey: path as NSString, cost: snapshot.cost)
        return snapshot
    }

    private static func loadEmbeddings(_ db: Database) throws -> [Embedding] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.asset_id, e.vector, e.model, e.model_revision, e.prompt_version, e.dimensions, e.namespace
            FROM embeddings e JOIN assets a ON a.id = e.asset_id
            WHERE e.namespace IN (?, ?) AND e.is_active = 1
              AND e.input_sha256 = a.sha256 AND a.is_available = 1
            """, arguments: [embeddingNamespace, videoEmbeddingNamespace])
        return try rows.enumerated().compactMap { index, row in
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let model: String = row["model"]
            let revision: String = row["model_revision"]
            let prompt: String = row["prompt_version"]
            let dimensions: Int = row["dimensions"]
            let namespace: String = row["namespace"]
            let blob: Data = row["vector"]
            guard model == embeddingModel, revision == embeddingRevision,
                  ((namespace == embeddingNamespace && prompt == embeddingPrompt)
                    || (namespace == videoEmbeddingNamespace && prompt == videoEmbeddingPrompt)),
                  dimensions == embeddingDimensions, let vector = decodeVector(blob) else { return nil }
            let length = vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            guard length > 0, length.isFinite else { return nil }
            return Embedding(assetID: row["asset_id"], vector: vector, length: length,
                             minimumSimilarity: namespace == videoEmbeddingNamespace
                                ? minVideoSimilarity : minVisualSimilarity)
        }
    }

    private static func decodeVector(_ data: Data) -> [Float]? {
        guard data.count == embeddingDimensions * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<embeddingDimensions).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }

    private static func normalizedVector(_ vector: [Double]) -> [Double] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity against an already-normalized query vector.
    private static func cosine(_ query: [Double], _ candidate: Embedding, workspace: inout [Double]) -> Double? {
        guard query.count == candidate.vector.count, !query.isEmpty else { return nil }
        var dot = 0.0
        // Keep cached vectors compact, but score in double precision using a
        // reusable workspace and the system's vector operations.
        query.withUnsafeBufferPointer { queryBuffer in
            candidate.vector.withUnsafeBufferPointer { candidateBuffer in
                workspace.withUnsafeMutableBufferPointer { converted in
                    vDSP_vspdp(candidateBuffer.baseAddress!, 1, converted.baseAddress!, 1, vDSP_Length(query.count))
                    vDSP_dotprD(queryBuffer.baseAddress!, 1, converted.baseAddress!, 1, &dot, vDSP_Length(query.count))
                }
            }
        }
        let similarity = dot / candidate.length
        return similarity.isFinite ? similarity : nil
    }

    /// Fuses ranks rather than adding incompatible lexical and cosine scores.
    private static func mergeRankings(
        lexical: [Match],
        visual: [VisualMatch],
        limit: Int
    ) -> [Ranked] {
        var combined: [String: Fused] = [:]
        for (rank, item) in lexical.prefix(limit).enumerated() {
            let id = item.document.assetID
            var entry = combined[id] ?? Fused(assetID: id)
            entry.score += 1.0 / Double(60 + rank + 1)
            entry.textCoverage = item.textCoverage
            combined[id] = entry
        }
        for (rank, item) in visual.prefix(limit).enumerated() {
            var entry = combined[item.assetID] ?? Fused(assetID: item.assetID)
            entry.score += 1.0 / Double(60 + rank + 1)
            entry.visualSimilarity = item.similarity
            combined[item.assetID] = entry
        }
        var results = Array(combined.values)
        results.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.assetID < rhs.assetID : lhs.score > rhs.score
        }
        // Preserve the benchmark's strongly leading lexical match ahead of lookalikes.
        if let top = lexical.first,
           lexical.count == 1 || top.score >= lexicalConfidenceRatio * lexical[1].score,
           let index = results.firstIndex(where: { $0.assetID == top.document.assetID }) {
            results.insert(results.remove(at: index), at: 0)
        }
        return results.map {
            Ranked(assetID: $0.assetID, textCoverage: $0.textCoverage,
                   visualSimilarity: $0.visualSimilarity)
        }
    }

    // MARK: - Query terms

    static func fallbackTerms(_ query: String) -> [String] {
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let chunks = chunkPattern.flatMap { matches($0, in: normalized) } ?? []
        var ngrams: [String] = []
        for chunk in chunks {
            let scalars = Array(chunk.unicodeScalars)
            guard !scalars.isEmpty, scalars.allSatisfy(isCJK) else { continue }
            for size in [3, 2] where scalars.count > size {
                for index in 0...(scalars.count - size) {
                    ngrams.append(String(String.UnicodeScalarView(scalars[index..<index + size])))
                }
            }
        }
        return deduped([normalized] + chunks + ngrams)
    }

    /// Fraction of the query's significant characters that the document covers.
    static func textCoverage(query: String, text: String) -> Double {
        Coverage(query: query).value(in: text)
    }

    /// Prepare query terms once, then reuse them across the whole library.
    private struct Coverage {
        let query: String
        let scalars: [Unicode.Scalar]
        let positions: Set<Int>
        let queryBytes: Data
        let terms: [(String, [Unicode.Scalar], Data)]

        init(query: String) {
            self.query = query.lowercased()
            queryBytes = Data(query.lowercased().utf8)
            let significant = strippedFillers(self.query)
            let values = Array(significant.unicodeScalars)
            scalars = values
            positions = Set(values.indices.filter { isAlphanumeric(values[$0]) })
            terms = fallbackTerms(significant).compactMap { term in
                let termValues = Array(term.unicodeScalars)
                return termValues.count >= 2 && termValues.count <= values.count ? (term, termValues, Data(term.utf8)) : nil
            }
        }

        func value(in text: String, bytes: Data? = nil) -> Double {
            guard !positions.isEmpty else {
                return (bytes.map { $0.range(of: queryBytes) != nil } ?? text.contains(query)) ? 1 : 0
            }
            var covered: Set<Int> = []
            for (term, values, needle) in terms {
                guard bytes.map({ $0.range(of: needle) != nil }) ?? text.contains(term) else { continue }
                var index = 0
                while index <= scalars.count - values.count {
                    if scalars[index..<index + values.count].elementsEqual(values) {
                        covered.formUnion(index..<index + values.count)
                        index += values.count
                    } else {
                        index += 1
                    }
                }
            }
            return Double(covered.intersection(positions).count) / Double(positions.count)
        }
    }

    /// Sentence padding dropped before coverage is measured.
    private static let fillers = ["帮我找", "找一下", "之前", "那张", "一张", "照片", "截图", "图片", "画面", "视频", "那个", "里面", "的", "了"]

    static func strippedFillers(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var kept: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            var consumed = 0
            for filler in fillers {
                let fillerScalars = Array(filler.unicodeScalars)
                guard index + fillerScalars.count <= scalars.count,
                      Array(scalars[index..<index + fillerScalars.count]) == fillerScalars else { continue }
                consumed = fillerScalars.count
                break
            }
            if consumed > 0 {
                index += consumed
            } else {
                kept.append(scalars[index])
                index += 1
            }
        }
        return String(String.UnicodeScalarView(kept))
    }

    private static func deduped(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
    }

    private static let cjkRange = "\u{3400}-\u{9FFF}"

    private static let chunkPattern = try? NSRegularExpression(
        pattern: "[A-Za-z0-9_./:+-]{2,}|[\(cjkRange)]{2,}"
    )

    /// Identifiers such as `ECONNREFUSED` or `ZXQ_UNSEEN` must appear verbatim; a
    /// lookalike image may not stand in for them.
    private static let identifierPattern = try? NSRegularExpression(
        pattern: "[a-z][a-z0-9]*(?:_[a-z0-9]+)+|\\b[a-z]{1,5}\\d{2,}[a-z0-9]*\\b"
    )

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Database

    private static func loadDocuments(_ db: Database, section: PhotoSection) throws -> [Document] {
        var sql = """
            SELECT
                a.id AS asset_id,
                COALESCE(d.asset_type, CASE WHEN json_extract(a.metadata_json, '$.media_type')='video' THEN 'video' ELSE 'other' END) AS asset_type,
                COALESCE(d.short_caption, '') AS short_caption,
                COALESCE(d.search_text, '') AS search_text,
                a.thumbnail_path,
                a.file_path,
                a.filename,
                a.captured_at,
                a.width,
                a.height,
                a.metadata_json,
                j.model AS annotation_model,
                j.data_json AS annotation_json
            FROM assets AS a
            LEFT JOIN search_docs AS d ON d.asset_id = a.id
            LEFT JOIN artifacts AS j
                ON j.asset_id = a.id
                AND j.kind = 'annotation'
                AND j.is_active = 1
                AND j.input_sha256 = a.sha256
            WHERE a.is_available = 1
            """
        var arguments: [DatabaseValueConvertible?] = []
        if let assetType = section.assetType {
            sql += " AND COALESCE(d.asset_type, CASE WHEN json_extract(a.metadata_json, '$.media_type')='video' THEN 'video' ELSE 'other' END) = ?"
            arguments.append(assetType)
        }
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
            Document(
                assetID: row["asset_id"],
                assetType: row["asset_type"],
                shortCaption: row["short_caption"],
                searchText: row["search_text"],
                thumbnailPath: row["thumbnail_path"],
                filePath: row["file_path"],
                filename: row["filename"],
                capturedAt: row["captured_at"],
                width: row["width"],
                height: row["height"],
                annotationModel: row["annotation_model"],
                annotationJSON: row["annotation_json"],
                durationSeconds: IndexedPhoto.videoDuration(from: row["metadata_json"]),
                searchTextLower: (row["search_text"] as String).lowercased(),
                searchBytes: Data((row["search_text"] as String).lowercased().utf8)
            )
        }
    }

    static func loadStats(_ db: Database) throws -> PhotoLibraryStats {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE is_available = 1") ?? 0
        let indexed = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM search_docs AS d
                JOIN assets AS a ON a.id = d.asset_id
                WHERE a.is_available = 1
                """
        ) ?? 0
        let failed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processing_skips") ?? 0
        return PhotoLibraryStats(total: total, indexed: indexed, failed: failed)
    }
}
