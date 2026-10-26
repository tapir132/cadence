import AVFoundation
import Testing
@testable import Cadence

@Suite struct MeetingAudioBufferTests {
    @Test func duplexHardwareInputCannotBecomePlayback() {
        var microphone: [Float] = [0.9, 0.9]
        var stereo: [Float] = [0.2, 0.6, 0.4, 0.8]
        let result = microphone.withUnsafeMutableBytes { mic in
            stereo.withUnsafeMutableBytes { playback in
                SystemAudioTap.monoPlayback(from: [
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(mic.count), mData: mic.baseAddress),
                    AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(playback.count), mData: playback.baseAddress)
                ], skipping: 1)
            }
        }
        #expect(abs((result?.first ?? 0) - 0.4) < 0.0001)
        #expect(abs((result?.last ?? 0) - 0.6) < 0.0001)
        #expect(result?.count == 2)
    }

    @Test func separateChannelBuffersAreAveragedUsingTheirOwnLayouts() {
        var left: [Float] = [0.2, 0.4]
        var right: [Float] = [0.6, 0.8]
        let result = left.withUnsafeMutableBytes { lhs in
            right.withUnsafeMutableBytes { rhs in
                SystemAudioTap.monoPlayback(from: [
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(lhs.count), mData: lhs.baseAddress),
                    AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(rhs.count), mData: rhs.baseAddress)
                ], skipping: 0)
            }
        }
        #expect(abs((result?.first ?? 0) - 0.4) < 0.0001)
        #expect(abs((result?.last ?? 0) - 0.6) < 0.0001)
    }

    @Test func missingPlaybackDoesNotFallBackToTheHardwareMicrophone() {
        #expect(SystemAudioTap.monoPlayback(from: [AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)], skipping: 1) == nil)
    }
}
