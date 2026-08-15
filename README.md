# lever-swift

The Swift client for [lever](https://github.com/ForceTower/lever), a self-hosted
remote config service. Zero dependencies, one product, five platforms.

> **Config values are public.** Never put a secret in a config value — every
> resolved value is readable by every end user of your app.
>
> **`pk_…` client keys are identifiers, not credentials.** They name an
> environment; they do not protect it. Shipping one in your app binary is the
> intended use.

## Install

```swift
.package(url: "https://github.com/ForceTower/lever-swift.git", from: "0.1.0")
```

Requires Swift 6, iOS 18 / macOS 15 / watchOS 11 / tvOS 18 / visionOS 2.

## Configure

Once, at launch, before the first read:

```swift
import Lever

Lever.configure(
    baseURL: URL(string: "https://config.example.com")!,
    clientKey: "pk_live_…",
    context: LeverContext(
        appVersion: Bundle.main.appVersion,
        attributes: ["tier": user.tier]
    )
)
```

`Lever.shared` is sugar. Construct `LeverClient(configuration:)` directly for a
second environment, for tests, or for an extension. Reading `Lever.shared`
before `configure`, or configuring twice, traps: a half-configured singleton
silently serving defaults is exactly the failure this SDK refuses to have.

## Declare keys once

Keys live in one extension on `LeverKeys`, the `EnvironmentValues` pattern, so
every default is declared exactly once:

```swift
nonisolated struct PaywallConfig: Codable, Sendable {
    var headline: String
    static let standard = PaywallConfig(headline: "Go Pro")
}

extension LeverKeys {
    var enableEnrollment: LeverKey<Bool> { LeverKey("enable_enrollment", default: false) }
    var maxRetries: LeverKey<Int> { LeverKey("max_retries", default: 3) }
    var paywall: LeverKey<PaywallConfig> { LeverKey(json: "paywall", default: .standard) }
}

if lever.enableEnrollment { … }          // dynamic member lookup
lever.value(for: LeverKeys().maxRetries) // the same read, spelled out
```

Reads are **synchronous and non-optional**. No `await` in `body`, no optionals
to unwrap, no throw: a key that is missing or does not fit its declared type
serves the code default and logs.

Two notes on `json` keys:

- Use **value types**. "Stable between activations" is a promise about the SDK's
  storage, not about aliasing a decoded reference.
- Mark the model `nonisolated` if your target compiles with `MainActor` default
  isolation. Otherwise its synthesized `Decodable` conformance is
  main-actor-isolated and cannot satisfy `LeverKey(json:default:)`. Decoding
  runs off the main actor, so `nonisolated` is the honest annotation.

### Layering lever over another source

`lookup` is the same read, reporting absence instead of absorbing it:

```swift
lever.lookup(LeverKeys().enableEnrollment)   // Bool? — nil when lever is silent
```

`nil` means this environment has nothing the key can serve: not published, or
present but unreadable as the declared type. It exists for exactly one caller —
a composite that puts lever in front of another config source. `value(for:)`
commits to the code default the moment lever is silent, which would shadow every
layer beneath it; `lookup` lets the caller fall through and keep the code default
as the floor under *all* of them. Everywhere else, read the non-optional way.

## Observing changes

`LeverClient` is `Observable`, so a SwiftUI view that reads a key re-evaluates
when an activation changes the serving values:

```swift
struct EnrollmentButton: View {
    let lever: LeverClient
    var body: some View {
        if lever.enableEnrollment { Button("Enroll") { … } }
    }
}
```

For non-SwiftUI consumers, `updates` is an `AsyncStream` and each access returns
a fresh stream, so any number of consumers can listen independently:

```swift
for await update in lever.updates {
    print("version \(update.version) changed \(update.changedKeys)")
}
```

Both fire only when the **serving values** changed. Republishing an environment
without changing what resolves for this client advances the version and the
cache silently — no spurious view invalidation.

## Fetch and activate

```swift
try await lever.fetch()             // stages; reads are unchanged
lever.activate()                    // swaps; true if the values changed
try await lever.fetchAndActivate()  // both
```

You rarely need any of it. The SDK fetches at launch and on foreground, honors
`minimumFetchInterval` (default 12 h), keeps an in-session timer as its polling
floor, and reacts to server push nudges — activating them automatically unless
you set `autoActivateOnNudge = false`.

An explicit `fetch()` **always** hits the network. The interval throttles the
SDK, not you: a debug menu or a retry button should do what it says.

### The DEBUG recipe

There is no bypass flag, because configuration is the honest lever:

```swift
#if DEBUG
configuration.minimumFetchInterval = .zero
#endif
```

## The three-layer floor

Every read resolves in this order, and the SDK guarantees it:

1. **Live values** from the last activation.
2. **Disk-cached last-activated values**, loaded synchronously during `init` —
   before any `await`, so the first read after `configure` already serves them.
3. **Your code defaults.**

An unreachable server means stale config, never a broken app. A 401 from a
rotated key does not clear the cache. A corrupt cache file falls back to
defaults and rewrites itself on the next activation. This is covered by tests,
not intent — see `Tests/LeverTests/FloorTests.swift`, which drives every one of
these cases end to end through the public API with the transport failing.

## App Groups and extensions

Point `cacheDirectory` at an App Group container to share the floor with
same-device extensions (an iOS app with its iOS widgets; a watchOS app with its
watchOS complications — never across devices):

```swift
configuration.cacheDirectory = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.app")
configuration.cacheNamespace = "prod"
configuration.automaticUpdates = false   // in the extension
```

`automaticUpdates = false` makes the client a **cache-only reader**: reads and
explicit fetches still work, but no automatic fetch, timer, lifecycle observer,
or stream ever starts. The supported topology is a single authoritative writer
(the app) with extensions as readers.

## Set `cacheNamespace`

Without it, the snapshot file's identity derives from your client key, so
rotating the key orphans the warm cache and costs one cold start. Setting it to
a name you control (`"prod"`, `"staging"`) pins the identity across rotations.
The installation `clientId` is stable either way.

## Logging

Everything goes through `LeverLogSink`. The default `OSLogSink` writes to
`os.Logger` under your bundle identifier, category `lever`. Implement the
protocol to route SDK logs into your own pipeline:

```swift
struct MyLogSink: LeverLogSink {
    func log(_ level: LeverLogLevel, _ message: String) { … }
}
configuration.logSink = MyLogSink()
```

## License

MIT.
