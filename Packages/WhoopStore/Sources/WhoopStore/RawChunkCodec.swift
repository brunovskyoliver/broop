import CZlib
import Foundation

/// A per-second raw stream whose closed hours are packed into `rawChunk` (the cold tier). The row table
/// stays the hot tier; readers see the union of the two. The raw value is the `rawChunk.stream` code and
/// is persisted, so a case is never renumbered.
public enum RawStream: Int, CaseIterable, Sendable {
    case hr = 1, rr = 2, gravity = 3, skinTemp = 4, steps = 5, sleepState = 6, v18Aux = 7

    /// The hot row table.
    public var table: String {
        switch self {
        case .hr: return "hrSample"
        case .rr: return "rrInterval"
        case .gravity: return "gravitySample"
        case .skinTemp: return "skinTempSample"
        case .steps: return "stepSample"
        case .sleepState: return "sleepStateSample"
        case .v18Aux: return "v18AuxSample"
        }
    }

    /// Every column of the hot table after `deviceId` and `ts`, in table order. A chunk stores exactly
    /// these, so a sealed row reads back with every column it had.
    public var columns: [(name: String, kind: RawColumnKind)] {
        switch self {
        case .hr: return [("bpm", .int), ("synced", .int)]
        case .rr: return [("rrMs", .int), ("seq", .int), ("synced", .int),
                          ("ord", .optionalInt), ("srcChannel", .optionalInt), ("tsSuspect", .optionalInt)]
        case .gravity: return [("x", .real), ("y", .real), ("z", .real), ("synced", .int), ("dynAccel", .optionalReal)]
        case .skinTemp: return [("raw", .int), ("synced", .int), ("aux1Raw", .optionalInt), ("aux2Raw", .optionalInt)]
        case .steps: return [("counter", .int), ("activityClass", .optionalInt)]
        case .sleepState: return [("state", .int), ("rawByte", .optionalInt)]
        case .v18Aux: return [("fields", .blob)]
        }
    }

    /// Indices into `columns` that complete the primary key after `(deviceId, ts)`.
    var extraKeyColumns: [Int] { self == .rr ? [0, 1] : [] }
}

public enum RawColumnKind: Sendable {
    case int, optionalInt, real, optionalReal, blob
    var isOptional: Bool { self == .optionalInt || self == .optionalReal }
    var isReal: Bool { self == .real || self == .optionalReal }
}

/// One column of a chunk. REAL values are held as their IEEE-754 bit patterns, so equality is bitwise and
/// nothing can round them. A null slot holds 0 in `values`. A BLOB column keeps its bytes in `blobs` and
/// leaves `values` empty.
public struct RawColumnValues: Equatable, Sendable {
    public var values: [Int64]
    /// nil for a NOT NULL column.
    public var isNull: [Bool]?
    public var blobs: [[UInt8]]?
    public init(values: [Int64], isNull: [Bool]? = nil) { self.values = values; self.isNull = isNull }
    public init(blobs: [[UInt8]]) { self.values = []; self.blobs = blobs }
}

/// The rows of one (device, stream, hour), sorted by primary key, column by column.
public struct RawChunkRows: Equatable, Sendable {
    public var ts: [Int64]
    public var columns: [RawColumnValues]
    public var count: Int { ts.count }
    public init(ts: [Int64], columns: [RawColumnValues]) { self.ts = ts; self.columns = columns }
}

public enum RawChunkCodecError: Error, Equatable {
    case truncated, badVersion(UInt8), badCompression(UInt8), malformed(String), zlib(Int32)
}

/// The cold-tier blob format. Pure and database-free; the Kotlin twin decodes what it encodes itself and
/// must agree with this layout byte for byte BEFORE deflate (compressed bytes may differ by zlib build).
///
/// Blob:
///   u8 version = 1
///   u8 compression: 0 = payload follows as is, 1 = uvarint payloadLength, then a zlib (RFC 1950) stream
///   payload:
///     uvarint n
///     ts column:      IntSeq over D[i] = ts[i] - ts[i-1], ts[-1] = 0
///     each column of `RawStream.columns`, in order:
///       optional kinds: IntSeq over presence (1 = value, 0 = NULL), n entries
///       real kinds:     u8 mode (0 = every value is exactly a float32, 1 = float64, 2 = scaled integer);
///                       mode 2 is followed by u8 k, the scale being 2^k
///       IntSeq over the m non-NULL values: the integer itself; for REAL in mode 0/1 the ordered key of
///       its bits, in mode 2 the integer v * 2^k
///       blob kind (NOT NULL): IntSeq over the n byte lengths, then for each byte position p from 0 to
///       (longest length - 1), IntSeq over byte p of every blob longer than p, in row order
///
/// IntSeq(v[0..<k]): prev = 0; for each value, d = v - prev (64-bit wrapping); write uvarint(zigzag(d));
/// if d == 0, write uvarint(r) where r is how many further values equal this one, and skip them.
/// zigzag(d) = (d << 1) ^ (d >> 63) (arithmetic shift), as unsigned. uvarint = LEB128, low 7 bits first,
/// at most 10 bytes.
/// Ordered key of REAL bits b (32 bits in mode 0, 64 in mode 1): sign clear -> b; sign set ->
/// -(b without its sign bit) - 1. Mode 0 is chosen when Double(Float(x)) has the same bits as x for
/// every value in the column, which makes the bits round-trip exactly either way. Mode 2 is chosen first,
/// with the smallest k in 0...24 for which every value v has v * 2^k integral, |v * 2^k| <= 2^53 and
/// Double(Int64(v * 2^k)) / 2^k bit-identical to v (so -0.0 and NaN never take it). It fits sensors that
/// report a fixed-point reading divided by a power of two, such as a WHOOP 4.0's i16 / 16384 gravity.
public enum RawChunkCodec {
    public static let version: UInt8 = 1

    public static func encode(_ rows: RawChunkRows, stream: RawStream, compress: Bool = true) -> [UInt8] {
        var p: [UInt8] = []
        p.reserveCapacity(rows.count * 4 + 16)
        putUVarint(&p, UInt64(rows.count))
        var prev: Int64 = 0
        putIntSeq(&p, rows.ts.map { t in defer { prev = t }; return t &- prev })
        for (column, (_, kind)) in zip(rows.columns, stream.columns) {
            var present = column.values
            if kind.isOptional {
                let nulls = column.isNull ?? Array(repeating: false, count: rows.count)
                putIntSeq(&p, nulls.map { $0 ? 0 : 1 })
                present = zip(column.values, nulls).compactMap { $1 ? nil : $0 }
            }
            if kind == .blob {
                let blobs = column.blobs ?? []
                putIntSeq(&p, blobs.map { Int64($0.count) })
                for pos in 0..<(blobs.map(\.count).max() ?? 0) {
                    putIntSeq(&p, blobs.compactMap { pos < $0.count ? Int64($0[pos]) : nil })
                }
                continue
            }
            if kind.isReal, let k = scaleExponent(present) {
                let scale = Double(UInt64(1) << k)
                p.append(2)
                p.append(UInt8(k))
                putIntSeq(&p, present.map { Int64(Double(bitPattern: UInt64(bitPattern: $0)) * scale) })
                continue
            }
            if kind.isReal {
                let f32 = present.allSatisfy { bits in
                    Double(Float(Double(bitPattern: UInt64(bitPattern: bits)))).bitPattern == UInt64(bitPattern: bits)
                }
                p.append(f32 ? 0 : 1)
                present = present.map { bits in
                    let d = Double(bitPattern: UInt64(bitPattern: bits))
                    return f32 ? orderedKey32(Float(d).bitPattern) : orderedKey64(d.bitPattern)
                }
            }
            putIntSeq(&p, present)
        }
        guard compress, let z = deflate(p), z.count + 11 < p.count else { return [version, 0] + p }
        var out: [UInt8] = [version, 1]
        putUVarint(&out, UInt64(p.count))
        return out + z
    }

    public static func decode(_ blob: UnsafeRawBufferPointer, stream: RawStream) throws -> RawChunkRows {
        guard blob.count >= 2 else { throw RawChunkCodecError.truncated }
        guard blob[0] == version else { throw RawChunkCodecError.badVersion(blob[0]) }
        switch blob[1] {
        case 0:
            return try decodePayload(UnsafeRawBufferPointer(rebasing: blob[2...]), stream: stream)
        case 1:
            var r = Reader(UnsafeRawBufferPointer(rebasing: blob[2...]))
            let length = try r.uvarint()
            guard length <= 1 << 30 else { throw RawChunkCodecError.malformed("payload length") }
            let payload = try inflate(UnsafeRawBufferPointer(rebasing: r.buf[r.pos...]), length: Int(length))
            return try payload.withUnsafeBytes { try decodePayload($0, stream: stream) }
        default:
            throw RawChunkCodecError.badCompression(blob[1])
        }
    }

    public static func decode(_ blob: [UInt8], stream: RawStream) throws -> RawChunkRows {
        try blob.withUnsafeBytes { try decode($0, stream: stream) }
    }

    private static func decodePayload(_ buf: UnsafeRawBufferPointer, stream: RawStream) throws -> RawChunkRows {
        var r = Reader(buf)
        let n64 = try r.uvarint()
        guard n64 <= 1 << 24 else { throw RawChunkCodecError.malformed("row count") }
        let n = Int(n64)
        var prev: Int64 = 0
        let ts = try r.intSeq(n).map { d -> Int64 in prev = prev &+ d; return prev }
        var columns: [RawColumnValues] = []
        for (_, kind) in stream.columns {
            if kind == .blob {
                let lengths = try r.intSeq(n)
                guard lengths.allSatisfy({ $0 >= 0 && $0 <= 1 << 20 }) else { throw RawChunkCodecError.malformed("blob length") }
                var blobs = lengths.map { [UInt8](repeating: 0, count: Int($0)) }
                for pos in 0..<Int(lengths.max() ?? 0) {
                    let owners = blobs.indices.filter { pos < blobs[$0].count }
                    for (i, b) in zip(owners, try r.intSeq(owners.count)) {
                        guard b >= 0, b <= 255 else { throw RawChunkCodecError.malformed("blob byte") }
                        blobs[i][pos] = UInt8(b)
                    }
                }
                columns.append(RawColumnValues(blobs: blobs))
                continue
            }
            var nulls: [Bool]?
            var m = n
            if kind.isOptional {
                let flags = try r.intSeq(n)
                guard flags.allSatisfy({ $0 == 0 || $0 == 1 }) else { throw RawChunkCodecError.malformed("presence") }
                nulls = flags.map { $0 == 0 }
                m = flags.reduce(0) { $0 + Int($1) }
            }
            var mode: UInt8 = 0
            var scale = 1.0
            if kind.isReal {
                mode = try r.byte()
                guard mode <= 2 else { throw RawChunkCodecError.malformed("real mode") }
                if mode == 2 {
                    let k = try r.byte()
                    guard k <= 24 else { throw RawChunkCodecError.malformed("scale") }
                    scale = Double(UInt64(1) << k)
                }
            }
            var present = try r.intSeq(m)
            if kind.isReal {
                present = present.map { k in
                    switch mode {
                    case 0: return Int64(bitPattern: Double(Float(bitPattern: fromOrderedKey32(k))).bitPattern)
                    case 1: return Int64(bitPattern: fromOrderedKey64(k))
                    default: return Int64(bitPattern: (Double(k) / scale).bitPattern)
                    }
                }
            }
            if let nulls {
                var it = present.makeIterator()
                columns.append(RawColumnValues(values: nulls.map { $0 ? 0 : it.next()! }, isNull: nulls))
            } else {
                columns.append(RawColumnValues(values: present))
            }
        }
        guard r.pos == buf.count else { throw RawChunkCodecError.malformed("trailing bytes") }
        return RawChunkRows(ts: ts, columns: columns)
    }

    /// The smallest k in 0...24 that makes every value (REAL bits) a lossless scaled integer, or nil.
    static func scaleExponent(_ bits: [Int64]) -> Int? {
        var k = 0
        for b in bits {
            let v = Double(bitPattern: UInt64(bitPattern: b))
            while !exactlyScaled(v, k) {
                k += 1
                if k > 24 { return nil }
            }
        }
        // A value checked at a smaller k also holds at a larger one, unless the larger scale overflows.
        return bits.allSatisfy { exactlyScaled(Double(bitPattern: UInt64(bitPattern: $0)), k) } ? k : nil
    }

    private static func exactlyScaled(_ v: Double, _ k: Int) -> Bool {
        let scale = Double(UInt64(1) << k)
        let s = v * scale
        guard s.isFinite, s.rounded() == s, abs(s) <= 9_007_199_254_740_992 else { return false }
        return (Double(Int64(s)) / scale).bitPattern == v.bitPattern
    }

    // MARK: - Primitives (the parts the Kotlin twin must match)

    static func zigzag(_ v: Int64) -> UInt64 { UInt64(bitPattern: (v << 1) ^ (v >> 63)) }
    static func unzigzag(_ z: UInt64) -> Int64 { Int64(bitPattern: (z >> 1) ^ (0 &- (z & 1))) }

    static func orderedKey32(_ b: UInt32) -> Int64 {
        b >> 31 == 0 ? Int64(b) : -Int64(b & 0x7FFF_FFFF) - 1
    }
    static func fromOrderedKey32(_ k: Int64) -> UInt32 {
        k >= 0 ? UInt32(truncatingIfNeeded: k) : 0x8000_0000 | UInt32(truncatingIfNeeded: -(k + 1))
    }
    static func orderedKey64(_ b: UInt64) -> Int64 {
        b >> 63 == 0 ? Int64(bitPattern: b) : -Int64(bitPattern: b & 0x7FFF_FFFF_FFFF_FFFF) - 1
    }
    static func fromOrderedKey64(_ k: Int64) -> UInt64 {
        k >= 0 ? UInt64(bitPattern: k) : 0x8000_0000_0000_0000 | UInt64(bitPattern: -(k + 1))
    }

    static func putUVarint(_ out: inout [UInt8], _ value: UInt64) {
        var v = value
        while v >= 0x80 { out.append(UInt8(truncatingIfNeeded: v) | 0x80); v >>= 7 }
        out.append(UInt8(v))
    }

    static func putIntSeq(_ out: inout [UInt8], _ values: [Int64]) {
        var prev: Int64 = 0
        var i = 0
        while i < values.count {
            let d = values[i] &- prev
            prev = values[i]
            putUVarint(&out, zigzag(d))
            i += 1
            if d == 0 {
                var run: UInt64 = 0
                while i < values.count, values[i] == prev { run += 1; i += 1 }
                putUVarint(&out, run)
            }
        }
    }

    struct Reader {
        let buf: UnsafeRawBufferPointer
        var pos = 0
        init(_ buf: UnsafeRawBufferPointer) { self.buf = buf }

        mutating func byte() throws -> UInt8 {
            guard pos < buf.count else { throw RawChunkCodecError.truncated }
            defer { pos += 1 }
            return buf[pos]
        }

        mutating func uvarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let b = try byte()
                guard shift < 64, shift < 63 || b <= 1 else { throw RawChunkCodecError.malformed("varint") }
                result |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return result }
                shift += 7
            }
        }

        mutating func intSeq(_ count: Int) throws -> [Int64] {
            var out: [Int64] = []
            out.reserveCapacity(count)
            var prev: Int64 = 0
            while out.count < count {
                let d = unzigzag(try uvarint())
                prev = prev &+ d
                out.append(prev)
                if d == 0 {
                    let run = try uvarint()
                    guard run <= UInt64(count - out.count) else { throw RawChunkCodecError.malformed("run length") }
                    out.append(contentsOf: repeatElement(prev, count: Int(run)))
                }
            }
            return out
        }
    }

    // MARK: - zlib

    static func deflate(_ input: [UInt8]) -> [UInt8]? {
        var size = compressBound(uLong(input.count))
        var out = [UInt8](repeating: 0, count: Int(size))
        let rc = out.withUnsafeMutableBufferPointer { o in
            input.withUnsafeBufferPointer { i in compress2(o.baseAddress, &size, i.baseAddress, uLong(i.count), 6) }
        }
        guard rc == Z_OK else { return nil }
        out.removeSubrange(Int(size)...)
        return out
    }

    static func inflate(_ input: UnsafeRawBufferPointer, length: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        var size = uLongf(length)
        var consumed = uLong(input.count)
        let rc = out.withUnsafeMutableBufferPointer { o in
            uncompress2(o.baseAddress, &size, input.baseAddress?.assumingMemoryBound(to: Bytef.self), &consumed)
        }
        guard rc == Z_OK else { throw RawChunkCodecError.zlib(rc) }
        guard Int(size) == length else { throw RawChunkCodecError.malformed("payload length") }
        // The zlib stream must end the blob, as every other encoding does.
        guard Int(consumed) == input.count else { throw RawChunkCodecError.malformed("trailing bytes") }
        return out
    }
}
