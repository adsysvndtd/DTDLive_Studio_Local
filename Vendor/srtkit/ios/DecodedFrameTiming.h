#pragma once

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

// Preserve decoder PTS across the existing pixel-buffer callback ABI. Studio uses
// it to schedule video; it must not propagate into composited/encoded output.
static inline void SRTKAttachPresentationTime(CVPixelBufferRef image, CMTime pts) {
    CFStringRef key = CFSTR("SRTKit.DecodedPresentationTimeSeconds");
    if (CMTIME_IS_NUMERIC(pts)) {
        NSNumber *seconds = @(CMTimeGetSeconds(pts));
        CVBufferSetAttachment(image, key, (__bridge CFTypeRef)seconds, kCVAttachmentMode_ShouldNotPropagate);
    } else {
        // Decoder pools recycle buffers: never leave a timestamp from a prior frame.
        CVBufferRemoveAttachment(image, key);
    }
}
