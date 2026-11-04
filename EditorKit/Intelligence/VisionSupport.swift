@preconcurrency import Vision
@preconcurrency import CoreML

enum VisionSupport {
    /// The iOS simulator has no Neural Engine; Vision's ML requests return empty
    /// results there unless they are pinned to the CPU. On device we leave Vision
    /// free to use the Neural Engine for maximum speed.
    static func configure(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        if let devices = try? request.supportedComputeStageDevices,
           let main = devices[.main],
           let cpu = main.first(where: { if case .cpu = $0 { return true } else { return false } }) {
            request.setComputeDevice(cpu, for: .main)
        }
        if let devices = try? request.supportedComputeStageDevices,
           let post = devices[.postProcessing],
           let cpu = post.first(where: { if case .cpu = $0 { return true } else { return false } }) {
            request.setComputeDevice(cpu, for: .postProcessing)
        }
        #endif
    }

    /// Last Vision error (diagnostics for tests).
    nonisolated(unsafe) static var lastError: String?
}
