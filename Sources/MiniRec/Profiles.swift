import Foundation
import AVFoundation
import VideoToolbox

public enum RecordingProfile: String, CaseIterable, Sendable {
    case compact = "compact"      // Default: HEVC, ~1.5 Mbps, 30fps (85-90% smaller than QuickTime)
    case ultra = "ultra"          // Ultra-small: HEVC, ~600 kbps, 24fps, optional 0.75x (95% smaller)
    case balanced = "balanced"    // Balanced: HEVC, ~3.5 Mbps, 30fps (Crisp & smooth)
    case pro = "pro"              // Pro Smooth: HEVC, ~7.0 Mbps, 60fps (High framerate)
    case web = "web"              // Web Compatibility: H.264, ~2.0 Mbps, 30fps (Plays on any device)
    
    public var displayName: String {
        switch self {
        case .compact:
            return "極小體積 (Compact HEVC - 推薦)"
        case .ultra:
            return "極限壓縮 (Ultra HEVC - 文件/Bug回報)"
        case .balanced:
            return "高畫質平衡 (Balanced HEVC)"
        case .pro:
            return "流暢專業 (Pro 60fps HEVC)"
        case .web:
            return "通用相容 (Web H.264 MP4)"
        }
    }
    
    public var codec: AVVideoCodecType {
        switch self {
        case .web:
            return .h264
        default:
            return .hevc
        }
    }
    
    public var fps: Int32 {
        switch self {
        case .ultra:
            return 24
        case .pro:
            return 60
        default:
            return 30
        }
    }
    
    public var targetBitrate: Int {
        switch self {
        case .ultra:
            return 600_000       // 600 kbps
        case .compact:
            return 1_500_000     // 1.5 Mbps
        case .balanced:
            return 3_500_000     // 3.5 Mbps
        case .pro:
            return 7_000_000     // 7.0 Mbps
        case .web:
            return 2_200_000     // 2.2 Mbps
        }
    }
    
    public var keyFrameInterval: Int {
        switch self {
        case .ultra:
            return 96            // 4 seconds GOP
        case .compact:
            return 90            // 3 seconds GOP
        case .balanced:
            return 90
        case .pro:
            return 120           // 2 seconds GOP at 60fps
        case .web:
            return 60
        }
    }
    
    public var scaleFactor: Double {
        switch self {
        case .ultra:
            return 0.75
        default:
            return 1.0
        }
    }
    
    public var description: String {
        switch self {
        case .compact:
            return "HEVC 30fps, ~1.5 Mbps (體積約比 QuickTime 小 85%~90%，畫面清晰)"
        case .ultra:
            return "HEVC 24fps, ~600 kbps (適合文件說明、聊天軟體傳送，體積小 95%)"
        case .balanced:
            return "HEVC 30fps, ~3.5 Mbps (高品質簡報與螢幕操作)"
        case .pro:
            return "HEVC 60fps, ~7.0 Mbps (高幀率動畫或遊戲示範)"
        case .web:
            return "H.264 30fps, ~2.2 Mbps (相容所有老舊瀏覽器與播放器)"
        }
    }
}
