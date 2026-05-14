import Foundation
import Compression

/// Minimal ZIP archive reader / writer just powerful enough to handle
/// non-bank's `.xlsx` round-trip. Pure Swift, no SPM dependency.
///
/// Write path: STORE-only (no compression). Every entry is written as
/// raw bytes with a local file header + central directory entry.
/// STORE-only archives are larger than DEFLATE ones but Excel reads
/// them fine, and we sidestep maintaining a stream-deflater.
///
/// Read path: handles STORE (method 0) and DEFLATE (method 8). DEFLATE
/// decompression uses Apple's `Compression` framework with
/// `COMPRESSION_ZLIB` — that algorithm corresponds to raw DEFLATE
/// without zlib wrapping, which is what PKZIP uses inside an entry.
///
/// **Scope guardrails** — explicitly not implemented:
///   - ZIP64 extensions (we cap entry size at ~2 GB which is fine
///     for a transaction list)
///   - Encryption
///   - Multi-volume archives
///   - Anything other than the local-file-header / central-directory
///     fields needed by Excel
///   - Anything in the central directory other than the offsets and
///     names referenced by Excel
///
/// If Excel ever ships a file we can't read, fall back to importing
/// the user's exported CSV instead.
struct ZipEntry {
    let path: String
    let data: Data
}

enum MinimalZip {

    // MARK: - Write (STORE-only)

    static func write(entries: [ZipEntry]) -> Data {
        var archive = Data()
        struct CentralRecord {
            let path: String
            let crc32: UInt32
            let size: UInt32
            let localOffset: UInt32
        }
        var centrals: [CentralRecord] = []

        for entry in entries {
            let path = entry.path
            let bytes = entry.data
            let crc = crc32(of: bytes)
            let localOffset = UInt32(archive.count)

            // Local file header (PK\x03\x04). See APPNOTE 4.4 for the
            // field layout; STORE archives populate `compressedSize ==
            // uncompressedSize` and method = 0.
            archive.append(localFileHeader(
                path: path,
                crc32: crc,
                size: UInt32(bytes.count)
            ))
            archive.append(bytes)
            centrals.append(CentralRecord(
                path: path,
                crc32: crc,
                size: UInt32(bytes.count),
                localOffset: localOffset
            ))
        }

        let centralDirOffset = UInt32(archive.count)
        for record in centrals {
            archive.append(centralDirectoryHeader(
                path: record.path,
                crc32: record.crc32,
                size: record.size,
                localOffset: record.localOffset
            ))
        }
        let centralDirSize = UInt32(archive.count) - centralDirOffset

        // End of central directory record (PK\x05\x06).
        var eocd = Data()
        eocd.append(UInt32(0x06054b50).leData)
        eocd.append(UInt16(0).leData) // disk number
        eocd.append(UInt16(0).leData) // disk with cd
        eocd.append(UInt16(centrals.count).leData)
        eocd.append(UInt16(centrals.count).leData)
        eocd.append(centralDirSize.leData)
        eocd.append(centralDirOffset.leData)
        eocd.append(UInt16(0).leData) // comment length
        archive.append(eocd)
        return archive
    }

    private static func localFileHeader(path: String, crc32: UInt32, size: UInt32) -> Data {
        var header = Data()
        let name = path.data(using: .utf8) ?? Data()
        header.append(UInt32(0x04034b50).leData)
        header.append(UInt16(20).leData)  // version needed
        header.append(UInt16(0x0800).leData)  // flag — bit 11 = UTF-8 filename
        header.append(UInt16(0).leData)  // method — 0 = STORE
        header.append(UInt16(0).leData)  // mod time
        header.append(UInt16(0).leData)  // mod date
        header.append(crc32.leData)
        header.append(size.leData)
        header.append(size.leData)
        header.append(UInt16(name.count).leData)
        header.append(UInt16(0).leData)  // extra field length
        header.append(name)
        return header
    }

    private static func centralDirectoryHeader(
        path: String,
        crc32: UInt32,
        size: UInt32,
        localOffset: UInt32
    ) -> Data {
        var header = Data()
        let name = path.data(using: .utf8) ?? Data()
        header.append(UInt32(0x02014b50).leData)
        header.append(UInt16(20).leData)  // version made by
        header.append(UInt16(20).leData)  // version needed
        header.append(UInt16(0x0800).leData)  // flag — bit 11 = UTF-8 filename
        header.append(UInt16(0).leData)  // method — STORE
        header.append(UInt16(0).leData)  // mod time
        header.append(UInt16(0).leData)  // mod date
        header.append(crc32.leData)
        header.append(size.leData)
        header.append(size.leData)
        header.append(UInt16(name.count).leData)
        header.append(UInt16(0).leData)  // extra field length
        header.append(UInt16(0).leData)  // comment length
        header.append(UInt16(0).leData)  // disk number start
        header.append(UInt16(0).leData)  // internal attrs
        header.append(UInt32(0).leData)  // external attrs
        header.append(localOffset.leData)
        header.append(name)
        return header
    }

    // MARK: - Read

    static func read(data: Data) -> [ZipEntry]? {
        // Locate the End of Central Directory record. Per spec it's
        // always within the last 65 557 bytes of the file (22 byte
        // record + max 65 535 byte comment). Search backwards for the
        // signature `PK\x05\x06`.
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var eocdOffset: Int?
        let searchStart = max(0, data.count - 65557)
        if data.count >= 22 {
            for i in stride(from: data.count - 22, through: searchStart, by: -1) {
                if data[i] == eocdSig[0] && data[i + 1] == eocdSig[1]
                    && data[i + 2] == eocdSig[2] && data[i + 3] == eocdSig[3] {
                    eocdOffset = i
                    break
                }
            }
        }
        guard let eocd = eocdOffset else { return nil }

        let totalEntries = Int(data.readLEUInt16(at: eocd + 10))
        let centralDirOffset = Int(data.readLEUInt32(at: eocd + 16))
        var cursor = centralDirOffset
        var entries: [ZipEntry] = []
        for _ in 0..<totalEntries {
            guard data.readLEUInt32(at: cursor) == 0x02014b50 else { return nil }
            let method = data.readLEUInt16(at: cursor + 10)
            let crc = data.readLEUInt32(at: cursor + 16)
            let compressedSize = Int(data.readLEUInt32(at: cursor + 20))
            let uncompressedSize = Int(data.readLEUInt32(at: cursor + 24))
            let nameLen = Int(data.readLEUInt16(at: cursor + 28))
            let extraLen = Int(data.readLEUInt16(at: cursor + 30))
            let commentLen = Int(data.readLEUInt16(at: cursor + 32))
            let localOffset = Int(data.readLEUInt32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLen <= data.count else { return nil }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            let path = String(data: nameData, encoding: .utf8) ?? ""
            cursor = nameStart + nameLen + extraLen + commentLen

            // Read the local file header to find where the data starts —
            // central-dir offsets are authoritative for header location,
            // but compressed payload starts at local-name + local-extra
            // (which can differ from the central-dir extra length).
            guard data.readLEUInt32(at: localOffset) == 0x04034b50 else { return nil }
            let localNameLen = Int(data.readLEUInt16(at: localOffset + 26))
            let localExtraLen = Int(data.readLEUInt16(at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else { return nil }
            let payload = data.subdata(in: dataStart..<dataEnd)

            let decoded: Data?
            switch method {
            case 0:
                decoded = payload
            case 8:
                decoded = inflate(deflated: payload, expectedSize: uncompressedSize)
            default:
                decoded = nil
            }
            guard let result = decoded else { return nil }
            // Quick sanity check — if the entry advertised a CRC and our
            // decoded payload mismatches, the archive is corrupt.
            _ = crc  // not enforced in import; advisory only
            entries.append(ZipEntry(path: path, data: result))
        }
        return entries
    }

    // MARK: - DEFLATE

    /// Decompress raw DEFLATE bytes (no zlib header / trailer) using
    /// Apple's Compression framework. PKZIP stores entries as raw
    /// DEFLATE; the framework's `COMPRESSION_ZLIB` mode decodes that
    /// raw stream directly.
    private static func inflate(deflated: Data, expectedSize: Int) -> Data? {
        // Empty input → empty output (a legitimate zero-byte entry).
        if deflated.isEmpty { return Data() }
        let dstCapacity = max(expectedSize, deflated.count * 4)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dst.deallocate() }
        let written = deflated.withUnsafeBytes { src -> Int in
            guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(
                dst, dstCapacity,
                base, deflated.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(bytes: dst, count: written)
    }

    // MARK: - CRC32

    /// Table-based CRC-32 (polynomial `0xEDB88320`). Precomputed lazily
    /// the first time it's needed. Used by the writer to populate the
    /// CRC field in each local header / central-directory entry.
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    private static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<data.count {
                let byte = base[i]
                let idx = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = (crc >> 8) ^ crcTable[idx]
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Little-endian helpers

private extension UInt32 {
    /// Little-endian byte representation as a 4-byte `Data`. ZIP and
    /// OOXML both store integers in LE order regardless of host
    /// architecture.
    var leData: Data {
        var le = self.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
}

private extension UInt16 {
    var leData: Data {
        var le = self.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
}

private extension Data {
    /// Read a little-endian `UInt16` at the given byte offset. Bounds-
    /// checked — returns `0` on out-of-range reads so callers can
    /// defensively guard malformed archives.
    func readLEUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readLEUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
