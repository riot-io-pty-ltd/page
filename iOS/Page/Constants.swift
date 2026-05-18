import Foundation

/// Build-time constants. The Worker URL here is a fallback only — once
/// the iOS app is paired with a Mac, it uses the URL carried in the
/// pairing payload, not this constant. If you fork this repo, deploy
/// your own Cloudflare Worker (see Cloudflare/README.md) and change
/// the URL below to its address, or rely entirely on the pairing flow.
enum AppConstants {
    static let workerBaseURL = URL(string: "https://your-page-relay.workers.dev")!
}
