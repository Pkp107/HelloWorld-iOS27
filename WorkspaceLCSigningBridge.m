#import "LCUtils.h"

@interface ZSigner : NSObject
+ (NSProgress *)workspaceSignHomeScreenAppAtPath:(NSString *)appPath
                                         bundleId:(NSString *)bundleId
                                             cert:(NSData *)certificate
                                        provision:(NSData *)provisioningProfile
                                             pass:(NSString *)password
                                completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
@end

@interface LCUtils (WorkspacePrivate)
+ (void)loadStoreFrameworksWithError2:(NSError **)error;
@end

@implementation LCUtils (WorkspaceHomeScreenSigning)

+ (void)workspaceSignHomeScreenAppAtPath:(NSString *)appPath
                         bundleIdentifier:(NSString *)bundleIdentifier
                              certificate:(NSData *)certificate
                      provisioningProfile:(NSData *)provisioningProfile
                                  password:(NSString *)password
                         completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *loadError = nil;
    [self loadStoreFrameworksWithError2:&loadError];
    if (loadError) {
        completionHandler(NO, loadError);
        return;
    }

    Class signer = NSClassFromString(@"ZSigner");
    if (!signer) {
        completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:nil]);
        return;
    }

    NSProgress *progress = [(id)signer workspaceSignHomeScreenAppAtPath:appPath
                                                                bundleId:bundleIdentifier
                                                                    cert:certificate
                                                               provision:provisioningProfile
                                                                    pass:password
                                                       completionHandler:completionHandler];
    if (!progress) {
        completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:3 userInfo:nil]);
    }
}

@end
