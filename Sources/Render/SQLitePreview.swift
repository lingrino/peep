import Foundation
import SQLite3

/// SQLite databases as a Markdown document: one heading per table (so the outline lists
/// them), the row count, the schema (with its indexes and triggers) as highlighted SQL, and
/// the first rows as a table. Views and their SQL follow.
///
/// Opened read-only and `immutable`: no locks, no -wal/-shm files (the sandbox can't write
/// next to the file anyway). Changes still sitting in a -wal file aren't shown; the notice
/// says so when one exists. Time-bounded: counts are interrupted (SQLite's progress
/// handler) and fall back to an estimate; tables past the overall budget show their schema
/// only.
enum SQLitePreview {
    static let extensions: Set<String> = ["sqlite", "sqlite3", "db", "db3", "s3db", "sl3", "sqlitedb"]
    static let sampleRows = 20
    static let maxColumns = 16
    static let maxCellBytes = 60
    static let budget: UInt64 = 60_000_000
    static let countBudget: UInt64 = 8_000_000
    static let exactCount = 100_000

    /// The 16-byte header every SQLite 3 database starts with.
    static func isSQLite(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        n >= 16 && memcmp(p, "SQLite format 3\0", 16) == 0
    }

    static func isSQLite(path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return false }
        defer { close(fd) }
        var h = [UInt8](repeating: 0, count: 16)
        return h.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 16, 0) } == 16
            && h.withUnsafeBufferPointer { isSQLite($0.baseAddress!, 16) }
    }

    /// Markdown for the database, plus an optional notice.
    static func markdown(path: String, name: String) -> (String, String?) {
        let deadline = nanotime() + budget
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return ("# \(escape(name))\n\nCouldn't open this database.\n", nil)
        }
        defer { sqlite3_close(db) }
        // Interrupts long statements (counts) once `limit` passes.
        let limit = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { limit.deallocate() }
        limit.pointee = .max
        sqlite3_progress_handler(db, 2000, { ctx in nanotime() > ctx!.load(as: UInt64.self) ? 1 : 0 }, limit)

        struct Object { var type: String, name: String, table: String, sql: String }
        var objects: [Object] = []
        if let err = query(db, "SELECT type, name, tbl_name, coalesce(sql, '') FROM sqlite_master ORDER BY name", { s in
            objects.append(Object(type: text(s, 0), name: text(s, 1), table: text(s, 2), sql: text(s, 3)))
            return true
        }) {
            // Damaged, encrypted (SQLCipher) or not really SQLite past the header.
            return ("# \(escape(name))\n\nCouldn't read this database: \(escape(err)).\n", nil)
        }
        let tables = objects.filter { $0.type == "table" && !$0.name.hasPrefix("sqlite_") }
        let views = objects.filter { $0.type == "view" }
        var st = stat()
        let fileSize = stat(path, &st) == 0 ? UInt64(st.st_size) : 0

        var md = "# \(escape(name))\n\n"
        var summary = "SQLite \(String(cString: sqlite3_libversion()).split(separator: ".").first ?? "3") database · "
        summary += "\(tables.count) table\(tables.count == 1 ? "" : "s")"
        if !views.isEmpty { summary += " · \(views.count) view\(views.count == 1 ? "" : "s")" }
        summary += " · \(ArchiveListing.sizeString(fileSize))"
        md += escape(summary) + "\n\n"

        for t in tables {
            md += "## \(escape(t.name))\n\n"
            let quoted = "\"" + t.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            var facts: [String] = []
            if nanotime() < deadline {
                limit.pointee = min(deadline, nanotime() + countBudget)
                // Plain count(*) is one B-tree walk SQLite can't interrupt (seconds on a big
                // file): count at most `exactCount` rows in an interruptible scan instead.
                var counted = false
                query(db, "SELECT count(*) FROM (SELECT 1 FROM \(quoted) LIMIT \(exactCount + 1))") { s in
                    let n = Int(sqlite3_column_int64(s, 0))
                    if n <= exactCount { facts.append(ArchiveListing.counted(n, "row")); counted = true }
                    return false
                }
                if !counted {   // too many or interrupted: max(rowid) is exact for append-only tables
                    limit.pointee = .max
                    query(db, "SELECT max(rowid) FROM \(quoted)") { s in
                        if sqlite3_column_type(s, 0) != SQLITE_NULL { facts.append("about \(ArchiveListing.counted(Int(sqlite3_column_int64(s, 0)), "row"))") }
                        return false
                    }
                }
            }
            if !facts.isEmpty { md += facts.joined(separator: " · ") + "\n\n" }
            let ddl = ([t.sql] + objects.filter { ($0.type == "index" || $0.type == "trigger") && $0.table == t.name && !$0.sql.isEmpty }.map(\.sql))
                .map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n")
            md += fence("sql", ddl)
            if nanotime() < deadline {
                limit.pointee = deadline
                md += rows(db, "SELECT * FROM \(quoted) LIMIT \(sampleRows + 1)")
            } else {
                md += "_Rows not loaded (time budget)._\n\n"
            }
        }
        if !views.isEmpty {
            md += "## Views\n\n"
            for v in views { md += "### \(escape(v.name))\n\n" + fence("sql", v.sql) }
        }
        var notice: String?
        if stat(path + "-wal", &st) == 0 && st.st_size > 0 { notice = "Changes in the -wal file are not shown" }
        return (md, notice)
    }

    /// The first rows as a Markdown table (cells escaped and truncated).
    private static func rows(_ db: OpaquePointer, _ sql: String) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return "_Can't read rows: \(escape(String(cString: sqlite3_errmsg(db))))._\n\n"
        }
        defer { sqlite3_finalize(stmt) }
        let cols = Int(sqlite3_column_count(stmt))
        let shown = min(cols, maxColumns)
        var out = "|"
        for c in 0..<shown { out += " \(cell(String(cString: sqlite3_column_name(stmt, Int32(c))))) |" }
        out += "\n|" + String(repeating: "---|", count: shown) + "\n"
        var n = 0
        var more = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if n == sampleRows { more = true; break }
            out += "|"
            for c in 0..<shown { out += " \(value(stmt, Int32(c))) |" }
            out += "\n"
            n += 1
        }
        if n == 0 { return "_No rows._\n\n" }
        out += "\n"
        var notes: [String] = []
        if more { notes.append("first \(sampleRows) rows") }
        if cols > shown { notes.append("\(shown) of \(cols) columns") }
        if !notes.isEmpty { out += "_Showing \(notes.joined(separator: ", "))._\n\n" }
        return out
    }

    private static func value(_ s: OpaquePointer, _ c: Int32) -> String {
        switch sqlite3_column_type(s, c) {
        case SQLITE_NULL: return "∅"
        case SQLITE_BLOB: return cell("<blob \(ArchiveListing.sizeString(UInt64(sqlite3_column_bytes(s, c))))>")
        default:
            guard let p = sqlite3_column_text(s, c) else { return "" }
            let n = Int(sqlite3_column_bytes(s, c))
            var k = min(n, maxCellBytes)
            while k < n && k > 0 && p[k] & 0xC0 == 0x80 { k -= 1 }   // whole UTF-8 sequences
            let str = String(decoding: UnsafeBufferPointer(start: p, count: k), as: UTF8.self)
            return cell(k < n ? str + "…" : str)
        }
    }

    /// A table cell: one line, Markdown punctuation escaped.
    private static func cell(_ s: String) -> String {
        escape(s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " "))
    }

    /// Backslash-escapes ASCII punctuation (CommonMark allows it for every punctuation byte).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count + 8)
        for ch in s.unicodeScalars {
            if ch.isASCII, ch.value >= 0x21, ch.value <= 0x7E, !(ch.properties.isAlphabetic || ("0"..."9").contains(ch)) {
                out.unicodeScalars.append("\\")
            }
            out.unicodeScalars.append(ch)
        }
        return out
    }

    private static func fence(_ info: String, _ body: String) -> String {
        var longest = 0, run = 0
        for b in body.utf8 { if b == 0x60 { run += 1; longest = max(longest, run) } else { run = 0 } }
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return ticks + info + "\n" + body + "\n" + ticks + "\n\n"
    }

    /// Runs `sql`, calling `row` until it returns false. Returns SQLite's error, if any.
    @discardableResult
    private static func query(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> Bool) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return String(cString: sqlite3_errmsg(db)) }
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { if !row(stmt) { return nil } ; continue }
            return rc == SQLITE_DONE ? nil : String(cString: sqlite3_errmsg(db))
        }
    }

    private static func text(_ s: OpaquePointer, _ c: Int32) -> String {
        sqlite3_column_text(s, c).map { String(cString: $0) } ?? ""
    }
}
