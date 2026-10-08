import Foundation
import CoreGraphics
import ImageIO

@main
struct ApolloAwardAnimationDataTests {
    static var checks = 0
    static var failures = 0

    static func check(_ result: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !result() { failures += 1; print("FAIL: \(message)") }
    }

    static func validDocument() -> [String: Any] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return ["v": "4.8.0", "w": 1024, "h": 1024, "fr": 24, "ip": 0, "op": 48,
                "assets": [["id": "image0", "w": 1, "h": 1, "u": "", "p": "data:image/png;base64," + (png as Data).base64EncodedString()]],
                "layers": [["ind": 1, "ty": 2, "refId": "image0", "ip": 0, "op": 48]]]
    }

    static func parsed(_ document: [String: Any]) -> ApolloAwardAnimationDocument? {
        guard let data = try? JSONSerialization.data(withJSONObject: document) else { return nil }
        return try? ApolloAwardAnimationDocument(data: data)
    }

    static func main() throws {
        let base = validDocument()
        let good = parsed(base)
        check(good?.images.count == 1, "valid embedded PNG document")
        check(good?.images["image0"]?.width == 1, "decoded image dimensions")
        check((good?.cacheCost ?? 0) > 0, "decoded cache cost")
        // Exercise the fallback directly so the test remains meaningful even
        // on platforms where ImageIO already honors its thumbnail option.
        for (width, height, expectedWidth, expectedHeight) in [(1024, 1024, 144, 144), (640, 320, 144, 72), (320, 640, 72, 144), (2048, 1, 144, 1)] {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let bounded = try ApolloAwardAnimationDocument.boundedImage(context.makeImage()!)
            check(bounded.width == expectedWidth && bounded.height == expectedHeight, "explicit image bound preserves aspect ratio")
            let pixels = bounded.dataProvider!.data! as Data
            check(pixels[0] >= 126 && pixels[0] <= 129 && pixels[1] == 0 && pixels[2] == 0 && pixels[3] >= 126 && pixels[3] <= 129,
                  "explicit downscale preserves color and alpha")
        }
        let smallImage = good!.images["image0"]!
        let unchanged = try ApolloAwardAnimationDocument.boundedImage(smallImage)
        check(unchanged === smallImage, "small images avoid unnecessary resampling")
        for (key, value) in [("w", 0), ("h", 2049), ("fr", 0), ("fr", 61), ("op", 0), ("op", 241), ("ip", -1)] {
            var changed = base
            changed[key] = value
            check(parsed(changed) == nil, "bounds reject \(key)=\(value)")
        }
        for value: Any in [true, "1024", 1.5] {
            var changed = base
            changed["w"] = value
            check(parsed(changed) == nil, "integer dimension type")
        }
        for value in ["https://evil.example/image.png", "file:///private/image.png", "data:text/plain;base64,aA==", "data:image/png;base64,broken"] {
            var changed = base
            var assets = changed["assets"] as! [[String: Any]]
            assets[0]["p"] = value
            changed["assets"] = assets
            check(parsed(changed) == nil, "reject external/invalid embedded image")
        }
        for (key, value): (String, Any) in [("u", "/private/"), ("w", 2), ("h", 0), ("id", "")] {
            var changed = base
            var assets = changed["assets"] as! [[String: Any]]
            assets[0][key] = value
            changed["assets"] = assets
            check(parsed(changed) == nil, "reject invalid image metadata \(key)")
        }
        var changed = base
        let image = (base["assets"] as! [[String: Any]])[0]
        changed["assets"] = [image, image]
        check(parsed(changed) == nil, "duplicate asset ID")
        changed = base
        changed["layers"] = [["ind": 1, "ty": 2, "refId": "missing"]]
        check(parsed(changed) == nil, "missing image reference")
        changed["layers"] = [["ind": 1, "ty": 3, "parent": 2], ["ind": 2, "ty": 3, "parent": 1]]
        check(parsed(changed) == nil, "parent cycle")
        changed["layers"] = [["ind": 1, "ty": 3, "parent": 9]]
        check(parsed(changed) == nil, "missing parent")
        changed["layers"] = [["ind": 1, "ty": 3], ["ind": 1, "ty": 3]]
        check(parsed(changed) == nil, "duplicate layer ID")
        changed["layers"] = [["ind": 1, "ty": 5]]
        check(parsed(changed) == nil, "font/text layers outside award scope")
        changed["layers"] = [["ind": 1, "ty": 0, "refId": "comp"]]
        changed["assets"] = [["id": "comp", "layers": [["ind": 1, "ty": 0, "refId": "comp"]]]]
        check(parsed(changed) == nil, "precomposition cycle")
        changed["assets"] = [["id": "comp", "layers": [["ind": 1, "ty": 3]]]]
        check(parsed(changed) != nil, "valid precomposition")
        changed = base
        changed["layers"] = (1...129).map { ["ind": $0, "ty": 3] }
        check(parsed(changed) == nil, "layer count bound")
        var nested: Any = "leaf"
        for _ in 0..<35 { nested = ["child": nested] }
        changed = base
        changed["unknown"] = nested
        check(parsed(changed) == nil, "JSON nesting bound")
        changed["unknown"] = Array(repeating: 0, count: 40_001)
        check(parsed(changed) == nil, "JSON node count bound")
        check((try? ApolloAwardAnimationDocument(data: Data(repeating: 0, count: ApolloAwardAnimationDocument.maximumBytes + 1))) == nil, "response byte bound")
        check((try? ApolloAwardAnimationDocument(data: Data("not JSON".utf8))) == nil, "malformed document")
        check((try? ApolloAwardAnimationDocument(data: Data("[]".utf8))) == nil, "wrong root type")

        for url in ["https://i.redd.it/snoovatar/snoo_assets/marketing/example.json", "https://www.redditstatic.com/marketplace-assets/v1/core/awards/example.json"] {
            check(ApolloAwardAnimationDocument.accepts(url: URL(string: url)!), "scoped HTTPS CDN URL")
        }
        for url in ["http://i.redd.it/snoovatar/snoo_assets/marketing/a.json",
                    "https://evil.example/snoovatar/snoo_assets/marketing/a.json",
                    "https://user@i.redd.it/snoovatar/snoo_assets/marketing/a.json",
                    "https://i.redd.it:443/snoovatar/snoo_assets/marketing/a.json",
                    "https://i.redd.it/snoovatar/snoo_assets/marketing/a.json?q=x",
                    "https://i.redd.it/snoovatar/snoo_assets/marketing/a.json#x",
                    "https://i.redd.it/snoovatar/snoo_assets/marketing/%61.json",
                    "https://i.redd.it/snoovatar/snoo_assets/marketing/../a.json",
                    "https://i.redd.it/unscoped/a.json"] {
            check(!ApolloAwardAnimationDocument.accepts(url: URL(string: url)!), "reject unsafe URL")
        }
        // Optional local public assets permit a live-format check without
        // network access or redistributing third-party animation artwork.
        for path in CommandLine.arguments.dropFirst() {
            let document = try? ApolloAwardAnimationDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
            check(document != nil, "verified public asset \(URL(fileURLWithPath: path).lastPathComponent)")
            check(document?.images.values.allSatisfy { $0.width <= 144 && $0.height <= 144 } == true,
                  "public embedded images downsampled to icon size")
        }
        print("Award animation data: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
