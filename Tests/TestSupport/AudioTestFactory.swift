import CoreMedia
import Foundation
import MeetingRecorderCore
import XCTest

extension PCMChunk {
    static func fixture(
        source: CapturedAudioSource,
        startFrame: Int64,
        monoValues: [Float]
    ) -> PCMChunk {
        PCMChunk(
            source: source,
            startFrame: startFrame,
            frameCount: monoValues.count,
            samples: monoValues.flatMap { [$0, $0] }
        )
    }
}

extension MixedAudioChunk {
    var leftChannel: [Float] {
        stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }

    static func sine(
        startFrame: Int64,
        frameCount: Int,
        frequency: Double = 440,
        amplitude: Float = 0.25,
        sampleRate: Double = 48_000
    ) -> MixedAudioChunk {
        let samples = (0..<frameCount).flatMap { offset -> [Float] in
            let frame = startFrame + Int64(offset)
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            return [value, value]
        }
        return MixedAudioChunk(
            startFrame: startFrame,
            frameCount: frameCount,
            samples: samples
        )
    }
}

func XCTAssertFloatArraysEqual(
    _ actual: [Float],
    _ expected: [Float],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (left, right) in zip(actual, expected) {
        XCTAssertEqual(left, right, accuracy: 0.0001, file: file, line: line)
    }
}

enum AudioTestFactory {
    static func int16MonoSampleBuffer(
        sampleRate: Double,
        values: [Int16],
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Int16>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(formatStatus))
        }

        let byteCount = values.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(blockStatus))
        }
        let copyStatus = values.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(copyStatus))
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: values.count,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(sampleStatus))
        }
        return sampleBuffer
    }
}
