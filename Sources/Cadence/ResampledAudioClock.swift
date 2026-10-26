import Foundation

/// Maps converter output to the hardware clock. A converter can retain input
/// for its next call, and fractional rate conversion alternates output counts.
/// Stamping that output with each new input buffer's time creates false gaps.
/// Instances belong to one serial capture callback (or are used under its lock).
final class ResampledAudioClock: @unchecked Sendable {
    private var inputFrames: Int64 = 0
    private var outputFrames: Int64 = 0
    private var expectedInputTime: TimeInterval?

    func startTime(
        inputTime: TimeInterval, inputCount: Int, inputRate: Double, outputCount: Int
    ) -> TimeInterval {
        if let expectedInputTime, abs(inputTime - expectedInputTime) > 0.04 {
            inputFrames = 0
            outputFrames = 0
        }
        let start = inputTime + Double(outputFrames) / 16_000 - Double(inputFrames) / inputRate
        inputFrames += Int64(inputCount)
        outputFrames += Int64(outputCount)
        expectedInputTime = inputTime + Double(inputCount) / inputRate
        return start
    }
}
