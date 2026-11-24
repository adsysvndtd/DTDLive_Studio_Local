#!/usr/bin/env python3
"""Check the real ObjC timestamp attachment and Swift reader without camera hardware."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
s = (root / 'App/Sources/Ingest/IngestSource.swift').read_text()
a = s.index('enum DecodedFrameTiming {')
b = s.index('/// Plays decoded frames', a)
reader = s[a:b]
objc = r'''
#import "DecodedFrameTiming.h"
#include <cassert>
int main() {
 @autoreleasepool {
  CVPixelBufferRef pb = nullptr;
  assert(CVPixelBufferCreate(nullptr, 16, 16, kCVPixelFormatType_32BGRA, nullptr, &pb) == kCVReturnSuccess);
  CFStringRef key = CFSTR("SRTKit.DecodedPresentationTimeSeconds");
  SRTKAttachPresentationTime(pb, CMTimeMake(12345, 1000));
  CVAttachmentMode mode;
  NSNumber *value = CFBridgingRelease(CVBufferCopyAttachment(pb, key, &mode));
  assert(value && fabs(value.doubleValue - 12.345) < 0.000001);
  assert(mode == kCVAttachmentMode_ShouldNotPropagate);
  SRTKAttachPresentationTime(pb, kCMTimeInvalid);
  assert(CVBufferCopyAttachment(pb, key, nullptr) == nullptr);
  SRTKAttachPresentationTime(pb, kCMTimeZero);
  value = CFBridgingRelease(CVBufferCopyAttachment(pb, key, nullptr));
  assert(value && value.doubleValue == 0);
  CVPixelBufferRelease(pb);
 }
}
'''
swift = '''import Foundation
import CoreVideo
''' + reader + '''
var buffer: CVPixelBuffer?
precondition(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
let pb = buffer!
let key = "SRTKit.DecodedPresentationTimeSeconds" as CFString
precondition(DecodedFrameTiming.presentationTime(pb) == nil)
CVBufferSetAttachment(pb, key, NSNumber(value: 12.345), .shouldNotPropagate)
precondition(DecodedFrameTiming.presentationTime(pb) == 12.345)
CVBufferSetAttachment(pb, key, NSNumber(value: Double.nan), .shouldNotPropagate)
precondition(DecodedFrameTiming.presentationTime(pb) == nil)
CVBufferSetAttachment(pb, key, "invalid" as CFString, .shouldNotPropagate)
precondition(DecodedFrameTiming.presentationTime(pb) == nil)
CVBufferRemoveAttachment(pb, key)
precondition(DecodedFrameTiming.presentationTime(pb) == nil)
print("PASS: decoder PTS metadata, non-propagation, recycled-buffer cleanup and Swift reader")
'''
with tempfile.TemporaryDirectory(prefix='dtd-timing-') as temp:
    tmp = Path(temp)
    (tmp / 'check.mm').write_text(objc)
    (tmp / 'main.swift').write_text(swift)
    subprocess.run(['xcrun', 'clang++', '-fobjc-arc', '-I', str(root / 'Vendor/srtkit/ios'),
                    str(tmp / 'check.mm'), '-framework', 'Foundation', '-framework', 'CoreVideo',
                    '-framework', 'CoreMedia', '-o', str(tmp / 'objc-check')], check=True)
    subprocess.run([str(tmp / 'objc-check')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(tmp / 'cache'),
                    str(tmp / 'main.swift'), '-o', str(tmp / 'swift-check')], check=True)
    subprocess.run([str(tmp / 'swift-check')], check=True)
