import Foundation
import CoreFoundation
import CoreGraphics
import ImageIO

// Network-free preflight shared by the native renderer and the host harness.
// Lottie handles rendering; this only bounds work and disallows external assets.
enum ApolloAwardAnimationDataError: Error { case invalid }

struct ApolloAwardAnimationDocument {
    static let maximumBytes = 512 * 1024
    let data: Data
    let images: [String: CGImage]
    let cacheCost: Int

    static func accepts(url: URL) -> Bool {
        guard url.absoluteString.count <= 2048,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil, c.path == c.percentEncodedPath,
              c.path.hasSuffix(".json"),
              !c.path.components(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return (c.host == "i.redd.it" && c.path.hasPrefix("/snoovatar/snoo_assets/marketing/")) ||
            (c.host == "www.redditstatic.com" && c.path.hasPrefix("/marketplace-assets/v1/core/awards/"))
    }

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ApolloAwardAnimationDataError.invalid }
        var remainingNodes = 40_000
        try Self.checkTree(root, depth: 0, remaining: &remainingNodes)
        let width = try Self.integer(root["w"], range: 1...2048)
        let height = try Self.integer(root["h"], range: 1...2048)
        let rate = try Self.number(root["fr"])
        let first = try Self.number(root["ip"])
        let last = try Self.number(root["op"])
        guard width * height <= 2048 * 2048, rate >= 1, rate <= 60,
              first >= 0, last > first, (last - first) / rate <= 10,
              let layers = root["layers"] as? [[String: Any]], !layers.isEmpty,
              let assets = root["assets"] as? [[String: Any]], assets.count <= 64 else { throw ApolloAwardAnimationDataError.invalid }

        var assetIDs = Set<String>()
        var compositions: [String: [[String: Any]]] = ["": layers]
        var imageAssets: [String: [String: Any]] = [:]
        for asset in assets {
            guard let id = asset["id"] as? String, !id.isEmpty, id.count <= 128,
                  assetIDs.insert(id).inserted else { throw ApolloAwardAnimationDataError.invalid }
            if let children = asset["layers"] as? [[String: Any]] {
                guard asset["p"] == nil else { throw ApolloAwardAnimationDataError.invalid }
                compositions[id] = children
            } else {
                guard asset["p"] is String, imageAssets.count < 32 else { throw ApolloAwardAnimationDataError.invalid }
                imageAssets[id] = asset
            }
        }
        var totalLayers = 0
        for children in compositions.values {
            totalLayers += children.count
            guard totalLayers <= 128 else { throw ApolloAwardAnimationDataError.invalid }
            var parents: [Int: Int] = [:]
            var layerIDs = Set<Int>()
            for layer in children {
                let id = try Self.integer(layer["ind"], range: 0...1_000_000)
                let type = try Self.integer(layer["ty"], range: 0...4)
                guard layerIDs.insert(id).inserted else { throw ApolloAwardAnimationDataError.invalid }
                if let parent = layer["parent"] { parents[id] = try Self.integer(parent, range: 0...1_000_000) }
                if type == 0 || type == 2 {
                    guard let ref = layer["refId"] as? String else { throw ApolloAwardAnimationDataError.invalid }
                    if type == 0 {
                        guard compositions[ref] != nil, !ref.isEmpty else { throw ApolloAwardAnimationDataError.invalid }
                    } else if imageAssets[ref] == nil { throw ApolloAwardAnimationDataError.invalid }
                }
            }
            for id in layerIDs {
                var visited = Set<Int>()
                var current = id
                while let parent = parents[current] {
                    guard layerIDs.contains(parent), visited.insert(current).inserted else { throw ApolloAwardAnimationDataError.invalid }
                    current = parent
                }
            }
        }
        // Cyclic precompositions would recurse in the renderer. Bound expanded
        // layer count as well: a small graph can still fan out exponentially.
        func expandedCount(_ id: String, visiting: Set<String>) throws -> Int {
            guard !visiting.contains(id), visiting.count < 16 else { throw ApolloAwardAnimationDataError.invalid }
            var path = visiting
            path.insert(id)
            var count = compositions[id]?.count ?? 0
            for layer in compositions[id] ?? [] where (layer["ty"] as? NSNumber)?.intValue == 0 {
                guard let ref = layer["refId"] as? String else { throw ApolloAwardAnimationDataError.invalid }
                count += try expandedCount(ref, visiting: path)
                guard count <= 256 else { throw ApolloAwardAnimationDataError.invalid }
            }
            return count
        }
        for id in compositions.keys { _ = try expandedCount(id, visiting: []) }

        var decoded: [String: CGImage] = [:]
        var sourcePixels = 0
        var cost = data.count + totalLayers * 1024
        for (id, asset) in imageAssets {
            guard let encoded = asset["p"] as? String,
                  let directory = asset["u"] as? String, directory.isEmpty,
                  let comma = encoded.firstIndex(of: ","),
                  ["data:image/webp;base64", "data:image/png;base64", "data:image/jpeg;base64"].contains(String(encoded[..<comma])),
                  let bytes = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw ApolloAwardAnimationDataError.invalid }
            let imageWidth = try Self.integer(properties[kCGImagePropertyPixelWidth], range: 1...2048)
            let imageHeight = try Self.integer(properties[kCGImagePropertyPixelHeight], range: 1...2048)
            guard imageWidth == Self.integerValue(asset["w"]), imageHeight == Self.integerValue(asset["h"]) else { throw ApolloAwardAnimationDataError.invalid }
            sourcePixels += imageWidth * imageHeight
            guard sourcePixels <= 8 * 1024 * 1024 else { throw ApolloAwardAnimationDataError.invalid }
            // Award rows are 48 points; 144 pixels covers @3x without retaining
            // full 1024px images for every layer of a small icon.
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 144,
                                          kCGImageSourceShouldCacheImmediately: true]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ApolloAwardAnimationDataError.invalid }
            let image = try Self.boundedImage(thumbnail)
            decoded[id] = image
            cost += image.bytesPerRow * image.height
        }
        self.data = data
        images = decoded
        cacheCost = cost
    }

    static func boundedImage(_ image: CGImage) throws -> CGImage {
        // Some ImageIO codecs return the full source despite the thumbnail
        // option. Enforce the pixel bound ourselves before retaining it in
        // either the shared cache or a visible player's image provider.
        let longestEdge = max(image.width, image.height)
        guard longestEdge > 144 else { return image }
        let scale = 144.0 / Double(longestEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(image.height) * scale).rounded(.down)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ApolloAwardAnimationDataError.invalid
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage(), result.width <= 144, result.height <= 144 else {
            throw ApolloAwardAnimationDataError.invalid
        }
        return result
    }

    private static func integerValue(_ value: Any?) -> Int? { try? integer(value, range: 1...2048) }
    private static func number(_ value: Any?) throws -> Double {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, abs(n.doubleValue) <= 10_000_000 else { throw ApolloAwardAnimationDataError.invalid }
        return n.doubleValue
    }
    private static func integer(_ value: Any?, range: ClosedRange<Int>) throws -> Int {
        let n = try number(value)
        guard n.rounded() == n, range.contains(Int(n)) else { throw ApolloAwardAnimationDataError.invalid }
        return Int(n)
    }
    private static func checkTree(_ value: Any, depth: Int, remaining: inout Int) throws {
        remaining -= 1
        guard remaining >= 0, depth <= 32 else { throw ApolloAwardAnimationDataError.invalid }
        if let dict = value as? [String: Any] {
            for child in dict.values { try checkTree(child, depth: depth + 1, remaining: &remaining) }
        } else if let array = value as? [Any] {
            for child in array { try checkTree(child, depth: depth + 1, remaining: &remaining) }
        } else if let number = value as? NSNumber {
            guard number.doubleValue.isFinite, abs(number.doubleValue) <= 10_000_000 else { throw ApolloAwardAnimationDataError.invalid }
        }
    }
}
