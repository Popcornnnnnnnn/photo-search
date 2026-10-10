import Foundation
import GRDB

/// Reuses read connections so SQLite's data_version can detect committed changes,
/// including WAL writes whose file size does not change.
enum PhotoSearchIndex {
    final class Reader: @unchecked Sendable {
        let database: DatabaseQueue
        let identity = UUID().uuidString

        init(path: String) throws {
            var configuration = Configuration()
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA query_only = ON")
            }
            database = try DatabaseQueue(path: path, configuration: configuration)
        }
    }

    private final class Readers: @unchecked Sendable {
        let lock = NSLock()
        let cache = NSCache<NSString, Reader>()
        init() { cache.countLimit = 4 }
    }
    private static let readers = Readers()

    static func reader(at path: String) throws -> Reader {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let inode = attributes[.systemFileNumber] as? NSNumber
        let key = "\(path)|\(inode?.stringValue ?? "unknown")" as NSString
        return try readers.lock.withLock {
            if let reader = readers.cache.object(forKey: key) { return reader }
            let reader = try Reader(path: path)
            readers.cache.setObject(reader, forKey: key)
            return reader
        }
    }
}

/// Detached work must receive its caller's cancellation explicitly.
func photoSearchBackground<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
