import Foundation
import Testing
@testable import Cadence

@Suite struct ResampledAudioClockTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func converterPrimingAndFractionalCountsDoNotCreateGaps(rate: Double) {
        let clock = ResampledAudioClock()
        let epoch = 40_000.0
        var previousEnd: TimeInterval?
        var outputFrames = 0
        for index in 0..<400 {
            // The converter retains 155 samples of right context initially.
            let total = max(0, Int(Double((index + 1) * 512) * 16_000 / rate) - 155)
            let count = total - outputFrames
            let start = clock.startTime(
                inputTime: epoch + Double(index * 512) / rate,
                inputCount: 512, inputRate: rate, outputCount: count
            )
            if let previousEnd { #expect(abs(start - previousEnd) < 0.000_001) }
            previousEnd = start + Double(count) / 16_000
            outputFrames = total
        }
    }

    @Test func hardwareGapStartsANewTimeline() {
        let clock = ResampledAudioClock()
        _ = clock.startTime(inputTime: 10, inputCount: 512, inputRate: 48_000, outputCount: 16)
        #expect(clock.startTime(inputTime: 12, inputCount: 512, inputRate: 48_000, outputCount: 16) == 12)
    }
}
