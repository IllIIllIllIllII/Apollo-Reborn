import Foundation

// These return through the production @_cdecl function, after the source
// Swift array's local lifetime ends. The Objective-C harness consumes +1 with
// CFBridgingRelease, matching the native media menu's exact calling convention.
@_cdecl("ApolloTestNilMediaURLs")
func ApolloTestNilMediaURLs() -> UnsafeMutableRawPointer? {
    var urls: [URL]? = nil
    return withUnsafePointer(to: &urls) { ApolloSaveAllMediaCopyURLs($0) }
}

@_cdecl("ApolloTestEmptyMediaURLs")
func ApolloTestEmptyMediaURLs() -> UnsafeMutableRawPointer? {
    var urls: [URL]? = []
    return withUnsafePointer(to: &urls) { ApolloSaveAllMediaCopyURLs($0) }
}

@_cdecl("ApolloTestOrderedMediaURLs")
func ApolloTestOrderedMediaURLs() -> UnsafeMutableRawPointer? {
    var urls: [URL]? = [
        URL(string: "https://i.redd.it/first.jpg")!,
        URL(string: "https://i.imgur.com/second.mp4")!,
        URL(string: "https://i.redd.it/first.jpg")!
    ]
    return withUnsafePointer(to: &urls) { ApolloSaveAllMediaCopyURLs($0) }
}

@_cdecl("ApolloTestOptionalURLArraySize")
func ApolloTestOptionalURLArraySize() -> Int {
    MemoryLayout<[URL]?>.size
}
