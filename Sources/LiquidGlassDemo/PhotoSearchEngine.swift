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
        let ftsQuery = ftsCandidateQuery(queryLower: queryLower, terms: terms, identifiers: identifiers)

        return try PhotoSearchDatabase.readVersioned(at: databasePath) { db, revision in
            try Task.checkCancellation()
            if queryVector == nil,
               let ftsQuery,
               cache.storage.object(forKey: databasePath as NSString)?.revision != revision,
               try databaseHasFTS(db) {
                do {
                    let documents = try loadDocumentsFTS(
                        db, ftsQuery: ftsQuery, section: section, interval: interval
                    )
                    let stats = try loadStats(db)
                    let lexical = try lexicalMatches(
                        documents: documents, query: trimmed, queryLower: queryLower,
                        terms: terms, identifiers: identifiers
                    )
                    let documentsByID = Dictionary(
                        documents.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first }
                    )
                    return finalizeOutput(
                        lexical: lexical,
                        ranked: [],
                        visualSearchRan: false,
                        documentsByID: documentsByID,
                        stats: stats,
                        limit: limit,
                        revision: revision
                    )
                } catch is DatabaseError {
                    // Fall back cleanly to snapshot scan if FTS5 rejects a query.
                }
            }

            let snapshot = try cachedSnapshot(db, path: databasePath, revision: revision,
                                              needsVectors: queryVector != nil)
            let stats = snapshot.stats
            let needsFilter = section.assetType != nil || interval != nil
            let documents: [Document] = needsFilter
                ? snapshot.documents.filter { matchesFilter($0, section: section, interval: interval) }
                : snapshot.documents

            let lexicalDocuments: [Document]
            if let ftsQuery, snapshot.hasFTS,
               let ftsIDs = try? String.fetchAll(
                   db,
                   sql: "SELECT DISTINCT asset_id FROM search_fts WHERE search_fts MATCH ?",
                   arguments: [ftsQuery]
               ) {
                var seenIDs = Set<String>()
                seenIDs.reserveCapacity(ftsIDs.count)
                lexicalDocuments = ftsIDs.compactMap { id in
                    guard seenIDs.insert(id).inserted,
                          let doc = snapshot.documentsByID[id],
                          !needsFilter || matchesFilter(doc, section: section, interval: interval) else { return nil }
                    return doc
                }
            } else {
                lexicalDocuments = documents
            }

            let lexical = try lexicalMatches(
                documents: lexicalDocuments, query: trimmed, queryLower: queryLower,
                terms: terms, identifiers: identifiers
            )
            let supportedTextIDs = Set(
                lexical.filter { $0.textCoverage >= minVisualTextCoverage }.map(\.document.assetID)
            )

            var ranked: [VisualMatch] = []
            var visualSearchRan = false
            if let queryVector, !queryVector.isEmpty {
                let vectors: [Embedding]
                if !needsFilter && identifiers.isEmpty {
                    vectors = snapshot.embeddings ?? []
                } else {
                    let documentsByID = needsFilter
                        ? Dictionary(documents.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
                        : snapshot.documentsByID
                    vectors = (snapshot.embeddings ?? []).filter { candidate in
                        guard let doc = documentsByID[candidate.assetID] else { return false }
                        return identifiers.allSatisfy { doc.searchTextLower.contains($0) }
                    }
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

            return finalizeOutput(
                lexical: lexical,
                ranked: ranked,
                visualSearchRan: visualSearchRan,
                documentsByID: snapshot.documentsByID,
                stats: stats,
                limit: limit,
                revision: revision
            )
        }
    }

    private static func matchesFilter(_ document: Document, section: PhotoSection, interval: DateInterval?) -> Bool {
        guard section.assetType == nil || document.assetType == section.assetType else { return false }
        guard let interval else { return true }
        guard let value = document.capturedAt, let date = PhotoWorkerStatus.parseTimestamp(value) else { return false }
        return date >= interval.start && date < interval.end
    }

    private static func finalizeOutput(
        lexical: [Match],
        ranked: [VisualMatch],
        visualSearchRan: Bool,
        documentsByID: [String: Document],
        stats: PhotoLibraryStats,
        limit: Int,
        revision: String
    ) -> PhotoSearchDatabase.Output {
        let strongTextIDs = Set(
            lexical.filter { $0.textCoverage >= minTextCoverage }.map(\.document.assetID)
        )
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
            visualSearchRan: visualSearchRan,
            notice: notice(for: status, visualSearchRan: visualSearchRan),
            noticeTitle: noticeTitle(for: status, visualSearchRan: visualSearchRan),
            indexRevision: revision
        )
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

    private struct ByteAhoCorasick {
        let stateCount: Int
        let trans: [Int32]
        let outStart: [Int32]
        let outEnd: [Int32]
        let outList: [Int32]

        init?(patterns: [[UInt8]], maxStates: Int = 512) {
            guard !patterns.isEmpty else { return nil }
            var children: [[Int32]] = [Array(repeating: -1, count: 256)]
            var outputs: [[Int32]] = [[]]

            for (pid, bytes) in patterns.enumerated() where !bytes.isEmpty {
                var state = 0
                for byte in bytes {
                    let b = Int(byte)
                    if children[state][b] < 0 {
                        if children.count >= maxStates { return nil }
                        let next = children.count
                        children.append(Array(repeating: -1, count: 256))
                        outputs.append([])
                        children[state][b] = Int32(next)
                    }
                    state = Int(children[state][b])
                }
                outputs[state].append(Int32(pid))
            }

            let count = children.count
            var fail = [Int32](repeating: 0, count: count)
            var dfa = [Int32](repeating: 0, count: count * 256)
            var queue: [Int] = []
            queue.reserveCapacity(count)

            for b in 0..<256 {
                let child = children[0][b]
                if child >= 0 {
                    let c = Int(child)
                    fail[c] = 0
                    dfa[b] = child
                    queue.append(c)
                }
            }

            var head = 0
            while head < queue.count {
                let state = queue[head]
                head += 1
                let f = Int(fail[state])
                let rowOffset = state * 256
                let failOffset = f * 256
                for b in 0..<256 {
                    let child = children[state][b]
                    if child >= 0 {
                        let c = Int(child)
                        let cf = Int(dfa[failOffset + b])
                        fail[c] = Int32(cf)
                        dfa[rowOffset + b] = child
                        if !outputs[cf].isEmpty {
                            outputs[c].append(contentsOf: outputs[cf])
                        }
                        queue.append(c)
                    } else {
                        dfa[rowOffset + b] = dfa[failOffset + b]
                    }
                }
            }

            var starts = [Int32](repeating: 0, count: count)
            var ends = [Int32](repeating: 0, count: count)
            var flat: [Int32] = []
            flat.reserveCapacity(patterns.count * 2)
            for s in 0..<count {
                starts[s] = Int32(flat.count)
                if !outputs[s].isEmpty {
                    flat.append(contentsOf: outputs[s])
                }
                ends[s] = Int32(flat.count)
            }

            self.stateCount = count
            self.trans = dfa
            self.outStart = starts
            self.outEnd = ends
            self.outList = flat
        }
    }

    private static func lexicalMatches(
        documents: [Document],
        query: String,
        queryLower: String,
        terms: [String],
        identifiers: [String]
    ) throws -> [Match] {
        var matches: [Match] = []
        let coverage = Coverage(query: query)
        let queryBytes = Array(queryLower.utf8)
        let termByteArrays = terms.map { Array($0.utf8) }
        let identifierByteArrays = identifiers.map { Array($0.utf8) }

        var uniquePatterns: [[UInt8]] = []
        var patIndexByBytes: [[UInt8]: Int] = [:]
        var isIdentFlag: [Bool] = []

        func intern(_ bytes: [UInt8], isIdent: Bool) -> Int {
            if let existing = patIndexByBytes[bytes] {
                if isIdent { isIdentFlag[existing] = true }
                return existing
            }
            let pid = uniquePatterns.count
            uniquePatterns.append(bytes)
            patIndexByBytes[bytes] = pid
            isIdentFlag.append(isIdent)
            return pid
        }

        var uniqueIdentCount = 0
        for ident in identifierByteArrays where !ident.isEmpty {
            let prevCount = uniquePatterns.count
            _ = intern(ident, isIdent: true)
            if uniquePatterns.count > prevCount {
                uniqueIdentCount += 1
            }
        }
        let queryPID: Int? = queryBytes.isEmpty ? nil : intern(queryBytes, isIdent: false)
        let termPIDs: [Int?] = termByteArrays.map { $0.isEmpty ? nil : intern($0, isIdent: false) }

        if documents.count > 16, let ac = ByteAhoCorasick(patterns: uniquePatterns) {
            let patCount = uniquePatterns.count
            var seen = [UInt32](repeating: 0, count: patCount)
            var epoch: UInt32 = 0

            try ac.trans.withUnsafeBufferPointer { transBuf in
                try ac.outStart.withUnsafeBufferPointer { outStartBuf in
                    try ac.outEnd.withUnsafeBufferPointer { outEndBuf in
                        try ac.outList.withUnsafeBufferPointer { outListBuf in
                            try isIdentFlag.withUnsafeBufferPointer { identBuf in
                                try seen.withUnsafeMutableBufferPointer { seenBuf in
                                    let transBase = transBuf.baseAddress!
                                    let outStartBase = outStartBuf.baseAddress!
                                    let outEndBase = outEndBuf.baseAddress!
                                    let outListBase = outListBuf.baseAddress
                                    let identBase = identBuf.baseAddress!
                                    let seenBase = seenBuf.baseAddress!

                                    for (docIndex, document) in documents.enumerated() {
                                        if docIndex.isMultiple(of: 64) { try Task.checkCancellation() }
                                        epoch &+= 1
                                        if epoch == 0 {
                                            seenBuf.initialize(repeating: 0)
                                            epoch = 1
                                        }
                                        let curEpoch = epoch
                                        var hitCount = 0
                                        var identHits = 0

                                        document.searchBytes.withUnsafeBytes { rawBuf in
                                            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
                                            let count = rawBuf.count
                                            var state = 0
                                            for offset in 0..<count {
                                                state = Int(transBase[state &* 256 &+ Int(base[offset])])
                                                let s = Int(outStartBase[state])
                                                let e = Int(outEndBase[state])
                                                if s < e, let listPtr = outListBase {
                                                    for outIdx in s..<e {
                                                        let pid = Int(listPtr[outIdx])
                                                        if seenBase[pid] != curEpoch {
                                                            seenBase[pid] = curEpoch
                                                            hitCount += 1
                                                            if identBase[pid] {
                                                                identHits += 1
                                                            }
                                                            if hitCount == patCount {
                                                                return
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        guard identHits == uniqueIdentCount else { continue }
                                        var score = 0.0
                                        var matched: [String] = []
                                        if let qid = queryPID, seenBase[qid] == curEpoch {
                                            score += 12.0
                                            matched.append(query)
                                        }
                                        for (tIdx, term) in terms.enumerated() {
                                            let hit = termPIDs[tIdx].map { seenBase[$0] == curEpoch } ?? true
                                            if hit {
                                                score += max(1.0, 5.0 - Double(tIdx) * 0.15)
                                                matched.append(term)
                                            }
                                        }
                                        guard score > 0 else { continue }
                                        matches.append(
                                            Match(
                                                document: document,
                                                // Python rounds to three decimals before sorting, so terms that
                                                // sum to the same value stay tied and fall back to capture date.
                                                score: (score * 1000).rounded(.toNearestOrEven) / 1000,
                                                matchedTerms: deduped(matched),
                                                textCoverage: coverage.value(in: document.searchTextLower, bytes: document.searchBytes)
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            let queryData = Data(queryBytes)
            let termData = termByteArrays.map { Data($0) }
            let identifierData = identifierByteArrays.map { Data($0) }
            for (index, document) in documents.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                let text = document.searchTextLower
                let bytes = document.searchBytes
                guard identifierData.allSatisfy({ $0.isEmpty || bytes.range(of: $0) != nil }) else { continue }
                var score = 0.0
                var matched: [String] = []
                if !queryData.isEmpty && bytes.range(of: queryData) != nil {
                    score += 12.0
                    matched.append(query)
                }
                for (tIdx, term) in terms.enumerated() where termData[tIdx].isEmpty || bytes.range(of: termData[tIdx]) != nil {
                    score += max(1.0, 5.0 - Double(tIdx) * 0.15)
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
        let documentsByID: [String: Document]
        let hasFTS: Bool
        let stats: PhotoLibraryStats
        let embeddings: [Embedding]?
        init(
            revision: String,
            documents: [Document],
            documentsByID: [String: Document],
            hasFTS: Bool,
            stats: PhotoLibraryStats,
            embeddings: [Embedding]?
        ) {
            self.revision = revision
            self.documents = documents
            self.documentsByID = documentsByID
            self.hasFTS = hasFTS
            self.stats = stats
            self.embeddings = embeddings
        }
        var cost: Int {
            let docsCost = documents.reduce(0) { (total: Int, doc: Document) -> Int in
                let annotationBytes = doc.annotationJSON?.utf8.count ?? 0
                return total + (doc.searchText.utf8.count * 3) + annotationBytes + 512
            }
            let embeddingsCost = embeddings?.reduce(0) { (total: Int, item: Embedding) -> Int in
                total + (item.vector.count * 4) + 128
            } ?? 0
            return docsCost + embeddingsCost
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
        let documentsByID = current?.documentsByID ?? Dictionary(
            documents.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let hasFTS = try current?.hasFTS ?? databaseHasFTS(db)
        let stats = try current?.stats ?? loadStats(db)
        let embeddings = try needsVectors ? loadEmbeddings(db) : nil
        let snapshot = Snapshot(
            revision: revision,
            documents: documents,
            documentsByID: documentsByID,
            hasFTS: hasFTS,
            stats: stats,
            embeddings: embeddings
        )
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

    private static func ftsQuote(_ term: String) -> String {
        "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func ftsCandidateQuery(queryLower: String, terms: [String], identifiers: [String]) -> String? {
        if !identifiers.isEmpty {
            guard identifiers.allSatisfy({ $0.count >= 3 && $0.unicodeScalars.count >= 3 && !$0.contains("\0") }) else {
                return nil
            }
            return deduped(identifiers).map(ftsQuote).joined(separator: " AND ")
        }
        let candidates = deduped((queryLower.isEmpty ? [] : [queryLower]) + terms)
        guard !candidates.isEmpty,
              candidates.allSatisfy({ $0.count >= 3 && $0.unicodeScalars.count >= 3 && !$0.contains("\0") }) else {
            return nil
        }
        return candidates.map(ftsQuote).joined(separator: " OR ")
    }

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

    /// Prepare query terms and covered-position bitmasks once, then reuse across the library.
    private struct Coverage {
        let query: String
        let queryBytes: Data
        let posCount: Int
        let posMask: UInt64
        let smallTerms: [(String, Data, UInt64)]
        let largeTerms: [(String, Data, [Int])]

        init(query: String) {
            let lowered = query.lowercased()
            self.query = lowered
            queryBytes = Data(lowered.utf8)
            let significant = strippedFillers(lowered)
            let values = Array(significant.unicodeScalars)
            let positionIndices = values.indices.filter { isAlphanumeric(values[$0]) }
            posCount = positionIndices.count
            let fallback = fallbackTerms(significant)

            if values.count <= 64 {
                var mask: UInt64 = 0
                for pos in positionIndices {
                    mask |= (UInt64(1) << pos)
                }
                posMask = mask
                var compiled: [(String, Data, UInt64)] = []
                compiled.reserveCapacity(fallback.count)
                for term in fallback {
                    let termValues = Array(term.unicodeScalars)
                    guard termValues.count >= 2 && termValues.count <= values.count else { continue }
                    var spanMask: UInt64 = 0
                    var index = 0
                    while index <= values.count - termValues.count {
                        if values[index..<index + termValues.count].elementsEqual(termValues) {
                            for pos in index..<(index + termValues.count) {
                                spanMask |= (UInt64(1) << pos)
                            }
                            index += termValues.count
                        } else {
                            index += 1
                        }
                    }
                    spanMask &= mask
                    if spanMask != 0 {
                        compiled.append((term, Data(term.utf8), spanMask))
                    }
                }
                smallTerms = compiled
                largeTerms = []
            } else {
                posMask = 0
                smallTerms = []
                let positionSet = Set(positionIndices)
                var compiled: [(String, Data, [Int])] = []
                compiled.reserveCapacity(fallback.count)
                for term in fallback {
                    let termValues = Array(term.unicodeScalars)
                    guard termValues.count >= 2 && termValues.count <= values.count else { continue }
                    var coveredPositions: Set<Int> = []
                    var index = 0
                    while index <= values.count - termValues.count {
                        if values[index..<index + termValues.count].elementsEqual(termValues) {
                            for pos in index..<(index + termValues.count) where positionSet.contains(pos) {
                                coveredPositions.insert(pos)
                            }
                            index += termValues.count
                        } else {
                            index += 1
                        }
                    }
                    if !coveredPositions.isEmpty {
                        compiled.append((term, Data(term.utf8), Array(coveredPositions)))
                    }
                }
                largeTerms = compiled
            }
        }

        func value(in text: String, bytes: Data? = nil) -> Double {
            guard posCount > 0 else {
                return (bytes.map { $0.range(of: queryBytes) != nil } ?? text.contains(query)) ? 1 : 0
            }
            if !smallTerms.isEmpty || posMask != 0 {
                var hitMask: UInt64 = 0
                for (term, needle, spanMask) in smallTerms {
                    guard bytes.map({ $0.range(of: needle) != nil }) ?? text.contains(term) else { continue }
                    hitMask |= spanMask
                    if hitMask == posMask {
                        return 1.0
                    }
                }
                return Double(hitMask.nonzeroBitCount) / Double(posCount)
            }
            var covered: Set<Int> = []
            for (term, needle, positions) in largeTerms {
                guard bytes.map({ $0.range(of: needle) != nil }) ?? text.contains(term) else { continue }
                covered.formUnion(positions)
                if covered.count == posCount {
                    return 1.0
                }
            }
            return Double(covered.count) / Double(posCount)
        }
    }

    /// Sentence padding dropped before coverage is measured.
    private static let fillers = ["帮我找", "找一下", "之前", "那张", "一张", "照片", "截图", "图片", "画面", "视频", "那个", "里面", "的", "了"]
    private static let fillerScalarSequences: [[Unicode.Scalar]] = fillers.map { Array($0.unicodeScalars) }

    static func strippedFillers(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var kept: [Unicode.Scalar] = []
        kept.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            var consumed = 0
            for fillerScalars in fillerScalarSequences {
                let count = fillerScalars.count
                guard index + count <= scalars.count,
                      scalars[index..<index + count].elementsEqual(fillerScalars) else { continue }
                consumed = count
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

    /// Returns true if `text` might change under `.lowercased()` (skips lowercase ASCII and U+3000...U+9FFF).
    private static func needsLowercasing(_ text: String) -> Bool {
        var raw = text
        return raw.withUTF8 { buffer in
            var index = 0
            let count = buffer.count
            while index < count {
                let byte = buffer[index]
                if byte < 0x80 {
                    if byte >= 0x41 && byte <= 0x5A { return true }
                    index += 1
                } else if byte >= 0xE3 && byte <= 0xE9 {
                    index += 3
                } else {
                    return true
                }
            }
            return false
        }
    }

    private static func makeDocument(from row: Row) -> Document {
        let rawSearchText: String = row["search_text"]
        let lower = needsLowercasing(rawSearchText) ? rawSearchText.lowercased() : rawSearchText
        return Document(
            assetID: row["asset_id"],
            assetType: row["asset_type"],
            shortCaption: row["short_caption"],
            searchText: rawSearchText,
            thumbnailPath: row["thumbnail_path"],
            filePath: row["file_path"],
            filename: row["filename"],
            capturedAt: row["captured_at"],
            width: row["width"],
            height: row["height"],
            annotationModel: row["annotation_model"],
            annotationJSON: row["annotation_json"],
            durationSeconds: IndexedPhoto.videoDuration(from: row["metadata_json"]),
            searchTextLower: lower,
            searchBytes: Data(lower.utf8)
        )
    }

    private static func databaseHasFTS(_ db: Database) throws -> Bool {
        guard try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'search_fts'"
        ) != nil else { return false }
        let docsExist = try Int.fetchOne(db, sql: "SELECT 1 FROM search_docs LIMIT 1") != nil
        if !docsExist { return true }
        return try Int.fetchOne(db, sql: "SELECT 1 FROM search_fts LIMIT 1") != nil
    }

    private static func loadDocumentsFTS(
        _ db: Database,
        ftsQuery: String,
        section: PhotoSection,
        interval: DateInterval?
    ) throws -> [Document] {
        var sql = """
            SELECT
                a.id AS asset_id,
                d.asset_type AS asset_type,
                d.short_caption AS short_caption,
                d.search_text AS search_text,
                a.thumbnail_path,
                a.file_path,
                a.filename,
                a.captured_at,
                a.width,
                a.height,
                a.metadata_json,
                j.model AS annotation_model,
                j.data_json AS annotation_json
            FROM (SELECT DISTINCT asset_id FROM search_fts WHERE search_fts MATCH ?) AS f
            JOIN assets AS a ON a.id = f.asset_id
            JOIN search_docs AS d ON d.asset_id = f.asset_id
            LEFT JOIN artifacts AS j
                ON j.asset_id = a.id
                AND j.kind = 'annotation'
                AND j.is_active = 1
                AND j.input_sha256 = a.sha256
            WHERE a.is_available = 1
            """
        var arguments: [DatabaseValueConvertible?] = [ftsQuery]
        if let assetType = section.assetType {
            sql += " AND d.asset_type = ?"
            arguments.append(assetType)
        }
        let docs = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(makeDocument(from:))
        guard interval != nil else { return docs }
        return docs.filter { matchesFilter($0, section: section, interval: interval) }
    }

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
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(makeDocument(from:))
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
