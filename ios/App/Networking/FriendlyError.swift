import Foundation

/// What went wrong, in words: iOS's own text for a network or file failure reads like "The
/// operation couldn't be completed. (NSURLErrorDomain error -1001.)", and it was shown as it was in
/// about 150 places. The app's own errors (APIError, the services' messages) already say what
/// happened and stay as they are.
enum FriendlyError {
    static func message(_ error: Error) -> String {
        if let url = error as? URLError { return message(url.code) }
        if error is DecodingError { return "The answer couldn’t be read. Try again in a moment." }
        if let file = error as? CocoaError {
            switch file.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return "That file isn’t there any more."
            case .fileWriteOutOfSpace: return "Your iPhone is out of space."
            case .fileReadNoPermission, .fileWriteNoPermission: return "That file can’t be opened."
            case .fileReadCorruptFile: return "That file couldn’t be read."
            default: break
            }
        }
        if error is CancellationError { return "Stopped before it finished." }
        return error.localizedDescription
    }

    static func message(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: "You’re offline."
        case .timedOut: "It took too long to answer. Try again."
        case .cannotFindHost, .dnsLookupFailed: "The server couldn’t be found. Check its address."
        case .cannotConnectToHost: "The server didn’t answer. Check that it’s on."
        case .networkConnectionLost: "The connection dropped. Try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            "A secure connection couldn’t be made."
        case .userAuthenticationRequired, .userCancelledAuthentication: "Sign in again."
        case .badServerResponse, .cannotParseResponse, .zeroByteResource, .cannotDecodeContentData, .cannotDecodeRawData:
            "The server sent something unexpected. Try again."
        case .cancelled: "Stopped before it finished."
        case .badURL, .unsupportedURL: "That address isn’t right."
        case .resourceUnavailable, .fileDoesNotExist: "That isn’t available right now."
        default: "Couldn’t connect. Try again."
        }
    }
}
