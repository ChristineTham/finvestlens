//
//  Gzip.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Compression

/// Minimal gzip (RFC 1952) reader used to open compressed GnuCash files.
///
/// Apple's `Compression` framework decodes raw DEFLATE (`COMPRESSION_ZLIB`) but
/// not the gzip *container*, so we strip the gzip header/trailer ourselves and
/// inflate the payload. (Writing gzip on export will use a zlib wrapper package;
/// Architecture ADR-2/§5.3.)
public enum Gzip {

    public enum GzipError: Error, Equatable {
        case notGzip
        case truncated
        case inflateFailed
    }

    /// `true` if `data` begins with the gzip magic bytes `1f 8b`.
    public static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Returns `data` unchanged if it is not gzipped, otherwise the inflated
    /// contents.
    public static func decompressIfNeeded(_ data: Data) throws -> Data {
        isGzipped(data) ? try decompress(data) : data
    }

    /// Inflates gzip-compressed `data`.
    public static func decompress(_ data: Data) throws -> Data {
        guard isGzipped(data) else { throw GzipError.notGzip }
        let bytes = [UInt8](data)
        guard bytes.count > 18 else { throw GzipError.truncated }

        // gzip header: magic(2) method(1) flags(1) mtime(4) xfl(1) os(1) = 10 bytes
        let flags = bytes[3]
        let fhcrc = 0x02, fextra = 0x04, fname = 0x08, fcomment = 0x10
        var offset = 10

        if flags & UInt8(fextra) != 0 {
            guard offset + 2 <= bytes.count else { throw GzipError.truncated }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & UInt8(fname) != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & UInt8(fcomment) != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & UInt8(fhcrc) != 0 {
            offset += 2
        }

        let deflateEnd = bytes.count - 8 // strip CRC32(4) + ISIZE(4)
        guard deflateEnd > offset else { throw GzipError.truncated }

        // ISIZE (uncompressed size mod 2^32) is a sizing hint.
        let isize = Int(bytes[bytes.count - 4])
            | (Int(bytes[bytes.count - 3]) << 8)
            | (Int(bytes[bytes.count - 2]) << 16)
            | (Int(bytes[bytes.count - 1]) << 24)

        let payload = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + deflateEnd))
        return try inflate(payload, sizeHint: isize)
    }

    /// Compresses `data` into the gzip (RFC 1952) container: a 10-byte header,
    /// raw DEFLATE payload, then CRC32 + ISIZE trailer.
    public static func compress(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff]) // header (mtime=0, xfl=0, os=unknown)
        out.append(deflate(data))
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    private static func deflate(_ source: Data) -> Data {
        if source.isEmpty {
            // Empty DEFLATE stream (final stored block, length 0).
            return Data([0x03, 0x00])
        }
        let capacity = source.count + (source.count / 2) + 64
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = source.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, source.count, nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: destination, count: written)
    }

    // Standard CRC-32 (IEEE 802.3), computed on demand.
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func inflate(_ source: Data, sizeHint: Int) throws -> Data {
        var capacity = max(sizeHint, 64 * 1024)
        let ceiling = 1 << 30 // 1 GiB guard

        while true {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }

            let written = source.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destination, capacity,
                    base, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }

            if written == 0 { throw GzipError.inflateFailed }
            if written < capacity { return Data(bytes: destination, count: written) }

            // Output filled the buffer exactly — it may be truncated; grow.
            guard capacity < ceiling else { throw GzipError.inflateFailed }
            capacity = min(capacity * 2, ceiling)
        }
    }
}
