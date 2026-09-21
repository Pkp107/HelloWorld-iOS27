#import "zsigner.h"
#include "openssl.h"

// Keep this adapter independent of the bundle header's Xcode file-system
// synchronization rules. The implementation is provided by bundle.cpp.
class ZBundle {
public:
    std::string signFailedFiles;
    bool SignFolder(ZSignAsset *asset,
                    const std::string &folder,
                    const std::string &bundleId,
                    const std::string &version,
                    const std::string &displayName,
                    const std::vector<std::string> &dylibs,
                    bool force,
                    bool weakInject,
                    bool enableCache,
                    bool excludeProvisioning);
};

@implementation ZSigner (WorkspaceHomeScreenSigning)

+ (NSProgress *)workspaceSignHomeScreenAppAtPath:(NSString *)appPath
                                         bundleId:(NSString *)bundleId
                                             cert:(NSData *)certificate
                                        provision:(NSData *)provisioningProfile
                                             pass:(NSString *)password
                                completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *temporaryDirectory = NSTemporaryDirectory();
        NSString *certificatePath = [temporaryDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSString *profilePath = [temporaryDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSError *writeError = nil;
        BOOL wroteCertificate = [certificate writeToFile:certificatePath options:NSDataWritingAtomic error:&writeError];
        BOOL wroteProfile = wroteCertificate && [provisioningProfile writeToFile:profilePath options:NSDataWritingAtomic error:&writeError];

        ZSignAsset signingAsset;
        BOOL initialized = wroteProfile && signingAsset.Init(
            "",
            string(certificatePath.UTF8String),
            string(profilePath.UTF8String),
            "",
            string(password.UTF8String),
            false,
            false,
            false
        );

        ZBundle bundle;
        BOOL signedApp = initialized && bundle.SignFolder(
            &signingAsset,
            string(appPath.UTF8String),
            string(bundleId.UTF8String),
            "",
            "",
            vector<string>(),
            true,
            false,
            false,
            true
        );

        [[NSFileManager defaultManager] removeItemAtPath:certificatePath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:profilePath error:nil];
        progress.completedUnitCount = 1;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (signedApp) {
                completionHandler(YES, nil);
                return;
            }

            NSString *message = writeError.localizedDescription;
            if (message.length == 0 && initialized) {
                message = [NSString stringWithUTF8String:bundle.signFailedFiles.c_str()];
            }
            if (message.length == 0) {
                message = @"The certificate does not match this provisioning profile or its password is incorrect.";
            }
            completionHandler(NO, [NSError errorWithDomain:@"WorkspaceSigner" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }]);
        });
    });

    return progress;
}

@end
