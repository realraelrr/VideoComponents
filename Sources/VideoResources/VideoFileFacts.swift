import Darwin
import Foundation

/// Metadata captured at one instant. Matching metadata is not a content-integrity check.
public struct VideoFileFingerprint: Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let byteCount: Int64
  public let modifiedSeconds: Int64
  public let modifiedNanoseconds: Int64
  public let changedSeconds: Int64
  public let changedNanoseconds: Int64

  public init(
    device: UInt64,
    inode: UInt64,
    byteCount: Int64,
    modifiedSeconds: Int64,
    modifiedNanoseconds: Int64,
    changedSeconds: Int64,
    changedNanoseconds: Int64
  ) {
    self.device = device
    self.inode = inode
    self.byteCount = byteCount
    self.modifiedSeconds = modifiedSeconds
    self.modifiedNanoseconds = modifiedNanoseconds
    self.changedSeconds = changedSeconds
    self.changedNanoseconds = changedNanoseconds
  }

  public static func capture(at url: URL) throws -> Self {
    guard url.isFileURL else { throw VideoResourceFailure.fileUnavailable }
    var value = Darwin.stat()
    guard Darwin.fstatat(AT_FDCWD, url.path, &value, 0) == 0 else {
      throw VideoResourceFailure.fileUnavailable
    }
    return Self(
      device: UInt64(value.st_dev),
      inode: UInt64(value.st_ino),
      byteCount: Int64(value.st_size),
      modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
      changedSeconds: Int64(value.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)
    )
  }
}

/// The host supplies the fingerprint obtained during its successful integrity verification.
/// This value neither verifies a descriptor nor keeps a file from changing afterwards.
public struct VerifiedVideoFile: Sendable {
  public let url: URL
  public let fingerprint: VideoFileFingerprint

  public init(url: URL, fingerprint: VideoFileFingerprint) {
    self.url = url
    self.fingerprint = fingerprint
  }

  public var isCurrent: Bool {
    guard let current = try? VideoFileFingerprint.capture(at: url) else { return false }
    return current == fingerprint
  }
}
