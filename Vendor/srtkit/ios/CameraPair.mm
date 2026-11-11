#import "SRTKit.h"
#include "srtkit/CameraPair.h"
#include <memory>
@implementation SRTKCameraPair {
    std::unique_ptr<srtkit::CameraPair> _session;
}
- (instancetype)initWithHandler:(SRTKPairHandler)handler {
    if ((self=[super init])) {
        _session=std::make_unique<srtkit::CameraPair>([handler](auto event,const auto& id,const auto& peer,const auto& value,int port) {
            @autoreleasepool {
                handler((SRTKPairEvent)event,@(id.c_str()),@(peer.c_str()),@(value.c_str()),port);
            }
        });
    }
    return self;
}
- (void)listenWithBond:(NSString*)bond { _session->listen(bond.UTF8String); }
- (void)connectHost:(NSString*)host port:(NSInteger)port name:(NSString*)name bond:(NSString*)bond {
    _session->connect(host.UTF8String,(int)port,name.UTF8String,bond.UTF8String);
}
- (void)decide:(NSString*)request allow:(BOOL)allow { _session->decide(request.UTF8String,allow); }
- (void)mediaReady:(NSString*)request port:(NSInteger)port { _session->mediaReady(request.UTF8String,(int)port); }
- (void)stop { _session->stop(); }
@end
