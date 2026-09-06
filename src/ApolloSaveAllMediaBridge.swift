import Foundation

// MediaPageViewController.foundURLs is [URL]?, not an Objective-C NSArray.
// Read through Swift so bridging and ownership stay with the runtime. The
// caller validates the ivar's type/size and consumes this retained NSArray.
@_cdecl("ApolloSaveAllMediaCopyURLs")
public func ApolloSaveAllMediaCopyURLs(_ storage: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let storage,
          let urls = storage.assumingMemoryBound(to: Optional<[URL]>.self).pointee else { return nil }
    return Unmanaged.passRetained(urls as NSArray).toOpaque()
}
