# Lottie for award detail icons

Unmodified `Sources/` from [airbnb/lottie-ios 4.6.1](https://github.com/airbnb/lottie-ios/tree/4.6.1),
commit `f4db77d7feacba0c2360b84a40c38a6ce8ff399d`.
Only runtime sources and license notices are vendored; examples and tests are omitted.
This release supports iOS 13 and is compiled directly into ApolloReborn's existing
Swift module. No separate framework, package-manager download, or runtime script is needed.

`LICENSE` is Lottie's Apache 2.0 license. Its embedded ZIPFoundation 0.9.20,
EpoxyCore 0.11.0, and LRUCache 1.0.4 licenses are included alongside it;
the upstream embedded-library README files identify their origins.
Upstream source headers and `Sources/PrivacyInfo.xcprivacy` are preserved.

Apollo's integration only creates native Lottie views in the award details sheet.
It loads bounded public Reddit CDN JSON and uses its own embedded-image provider;
Lottie's remote-file, ZIP, external image, and font-loading helpers are not used.
`ApolloAwardAnimationData.swift` validates graph/size limits before decoding.
The existing static icon is retained when motion is disabled or any step fails.

To update, review the new upstream deployment target, replace `Sources/` and
licenses from an exact official tag, update this commit, then run the animation
data host tests and both device/simulator builds.
