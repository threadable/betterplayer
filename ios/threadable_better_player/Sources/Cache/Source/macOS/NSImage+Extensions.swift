#if os(macOS)
import AppKit

extension NSImage {
  func cache_toData() -> Data? {
    tiffRepresentation
  }
}
#endif
