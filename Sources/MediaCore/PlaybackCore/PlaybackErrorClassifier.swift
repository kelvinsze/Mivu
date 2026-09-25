import Foundation
import AVFoundation

public enum PlaybackFailureReason: Equatable, Sendable {
    /// 确认的容器、封装、音视频编解码器不支持或解复用/解析失败（唯一允许触发转码候选）
    case mediaFormatOrDecode(description: String, code: Int?)
    /// 网络异常：超时、断网、DNS失败、连接中断（禁止降级转码）
    case network(description: String, code: Int?)
    /// 认证与权限失败：401 Unauthorized、403 Forbidden、凭据失效（禁止降级转码）
    case authentication(description: String, statusCode: Int?)
    /// 服务端内部错误：500、502、503 等（禁止降级转码）
    case server(description: String, statusCode: Int?)
    /// 未分类或未知错误（保守策略：禁止降级转码）
    case unclassified(description: String)

    public var isEligibleForTranscodeFallback: Bool {
        if case .mediaFormatOrDecode = self { return true }
        return false
    }

    public var categoryName: String {
        switch self {
        case .mediaFormatOrDecode: return "mediaFormatOrDecode"
        case .network: return "network"
        case .authentication: return "authentication"
        case .server: return "server"
        case .unclassified: return "unclassified"
        }
    }

    public var userFacingMessage: String {
        switch self {
        case .mediaFormatOrDecode(let desc, _):
            return String.localizedStringWithFormat(String(localized: "当前格式无法解码，正在尝试备用流：%@"), desc)
        case .network(let desc, _):
            return String.localizedStringWithFormat(String(localized: "网络连接失败，请检查网络设置 (%@)"), desc)
        case .authentication(let desc, _):
            return String.localizedStringWithFormat(String(localized: "媒体服务器鉴权失败，请重新登录 (%@)"), desc)
        case .server(let desc, let code):
            return String.localizedStringWithFormat(String(localized: "媒体服务器响应异常 (HTTP %d): %@"), code ?? 500, desc)
        case .unclassified(let desc):
            return desc
        }
    }

    public static func mediaFormatOrDecode(_ description: String, code: Int? = nil) -> PlaybackFailureReason {
        .mediaFormatOrDecode(description: description, code: code)
    }

    public static func network(_ description: String, code: Int? = nil) -> PlaybackFailureReason {
        .network(description: description, code: code)
    }

    public static func authentication(_ description: String, statusCode: Int? = nil) -> PlaybackFailureReason {
        .authentication(description: description, statusCode: statusCode)
    }

    public static func server(_ description: String, statusCode: Int? = nil) -> PlaybackFailureReason {
        .server(description: description, statusCode: statusCode)
    }

    public static func unclassified(_ description: String) -> PlaybackFailureReason {
        .unclassified(description: description)
    }
}

public enum PlaybackErrorClassifier {
    public static func classifyAVPlayer(item: AVPlayerItem) -> PlaybackFailureReason {
        // 1. 优先检查 errorLog 中最后一次 HTTP 响应状态码
        if let lastEvent = item.errorLog()?.events.last {
            let status = lastEvent.errorStatusCode
            if status == 401 || status == 403 {
                return .authentication(description: lastEvent.errorComment ?? "HTTP \(status)", statusCode: status)
            }
            if (500...599).contains(status) {
                return .server(description: lastEvent.errorComment ?? "HTTP \(status)", statusCode: status)
            }
        }

        guard let error = item.error as NSError? else {
            return .unclassified("播放器状态异常")
        }

        return classifyNSError(error)
    }

    public static func classifyNSError(_ error: NSError) -> PlaybackFailureReason {
        // 检查根错误与 underlyingError 树
        var queue: [NSError] = [error]
        var visited = Set<Int>()

        while !queue.isEmpty {
            let err = queue.removeFirst()
            let key = err.domain.hashValue ^ err.code.hashValue
            if visited.contains(key) { continue }
            visited.insert(key)

            if let underlying = err.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }

            // 认证与权限
            if err.domain == NSURLErrorDomain && err.code == NSURLErrorUserCancelledAuthentication {
                return .authentication(description: err.localizedDescription, statusCode: 401)
            }

            // 网络相关错误
            if err.domain == NSURLErrorDomain {
                switch err.code {
                case NSURLErrorNotConnectedToInternet,
                     NSURLErrorNetworkConnectionLost,
                     NSURLErrorTimedOut,
                     NSURLErrorCannotFindHost,
                     NSURLErrorCannotConnectToHost,
                     NSURLErrorDNSLookupFailed,
                     NSURLErrorResourceUnavailable,
                     NSURLErrorInternationalRoamingOff,
                     NSURLErrorCallIsActive,
                     NSURLErrorDataNotAllowed,
                     NSURLErrorCannotLoadFromNetwork,
                     NSURLErrorSecureConnectionFailed,
                     NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasUnknownRoot,
                     NSURLErrorServerCertificateNotYetValid,
                     NSURLErrorClientCertificateRejected,
                     NSURLErrorClientCertificateRequired:
                    return .network(description: err.localizedDescription, code: err.code)
                case NSURLErrorBadServerResponse,
                     NSURLErrorCannotParseResponse:
                    return .server(description: err.localizedDescription, statusCode: nil)
                default:
                    break
                }
            }

            // 格式与解码相关错误 (AVFoundation / CoreMedia / AudioToolbox)
            if err.domain == AVFoundationErrorDomain {
                switch err.code {
                case -11828, // AVErrorFileFormatUnrecognized
                     -11829, // AVErrorFailedToParse
                     -11833, // AVErrorDecoderNotFound
                     -11834, // AVErrorDecoderTemporarilyUnavailable
                     -11835, // AVErrorClientIsNotAuthorizedToUseDecoder
                     -11848, // AVErrorDecodeFailed
                     -11870: // AVErrorFormatUnsupported
                    return .mediaFormatOrDecode(description: err.localizedDescription, code: err.code)
                default:
                    break
                }
            }

            if err.domain == "CoreMediaErrorDomain" {
                switch err.code {
                case (-12849)...(-12840), // kFigMediaFormatReaderError_...
                     -12780,              // kFigPlayerError_DecodeFailed
                     -12785:              // kFigPlayerError_VideoRenderPipelineFailed
                    return .mediaFormatOrDecode(description: err.localizedDescription, code: err.code)
                default:
                    break
                }
            }

            if err.domain == NSOSStatusErrorDomain && (err.code == 1718449257 /* 'fmt?' */ || err.code == 1954115685 /* '!dat' */) {
                return .mediaFormatOrDecode(description: err.localizedDescription, code: err.code)
            }
        }

        return .unclassified(error.localizedDescription)
    }

    public static func classifyMPV(error: Int32, message: String) -> PlaybackFailureReason {
        let lower = message.lowercased()
        if error == -14 || lower.contains("demuxer failed") || lower.contains("unsupported format") || lower.contains("no video or audio") || lower.contains("codec not found") || lower.contains("failed to find decoder") || lower.contains("unable to decode") {
            return .mediaFormatOrDecode(description: message, code: Int(error))
        }
        if lower.contains("connection refused") || lower.contains("timed out") || lower.contains("could not resolve") || lower.contains("network is unreachable") || lower.contains("host is down") {
            return .network(description: message, code: Int(error))
        }
        if lower.contains("401") || lower.contains("403") || lower.contains("unauthorized") || lower.contains("forbidden") {
            return .authentication(description: message, statusCode: 401)
        }
        if lower.contains("500") || lower.contains("502") || lower.contains("503") || lower.contains("server error") {
            return .server(description: message, statusCode: 500)
        }
        return .unclassified(message)
    }
}
