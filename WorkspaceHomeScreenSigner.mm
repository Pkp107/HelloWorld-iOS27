#import "zsigner.h"
#include "common/common.h"
#include "macho.h"
#include "openssl.h"

void refreshFile(NSString *path);

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

        NSMutableArray<NSURL *> *machOURLs = [NSMutableArray array];
        NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
            enumeratorAtURL:[NSURL fileURLWithPath:appPath]
            includingPropertiesForKeys:@[NSURLIsRegularFileKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles
            errorHandler:nil];
        BOOL signedApp = initialized;
        if (initialized) {
            for (NSURL *fileURL in enumerator) {
                NSNumber *isRegular = nil;
                if (![fileURL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil] || !isRegular.boolValue) { continue; }
                [machOURLs addObject:fileURL];
            }
            [machOURLs sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
                if (a.path.length == b.path.length) { return [a.path compare:b.path]; }
                return a.path.length > b.path.length ? NSOrderedAscending : NSOrderedDescending;
            }];
            for (NSURL *fileURL in machOURLs) {
                ZMachO macho;
                if (!macho.Init(fileURL.path.UTF8String)) {
                    continue;
                }
                // Passing an empty identifier makes ZSign use each Mach-O's
                // own embedded Info.plist. Extensions and frameworks must not
                // inherit the top-level application's bundle identifier.
                if (!macho.Sign(&signingAsset, true, "", "", "", "")) {
                    signedApp = NO;
                    continue;
                }
                refreshFile(fileURL.path);
            }
        }

        [[NSFileManager defaultManager] removeItemAtPath:certificatePath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:profilePath error:nil];
        progress.completedUnitCount = 1;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (signedApp) {
                completionHandler(YES, nil);
                return;
            }

            NSString *message = writeError.localizedDescription;
            if (message.length == 0 && initialized) { message = @"One or more nested Mach-O files could not be signed."; }
            if (message.length == 0) {
                message = @"The certificate does not match this provisioning profile or its password is incorrect.";
            }
            completionHandler(NO, [NSError errorWithDomain:@"WorkspaceSigner" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }]);
        });
    });

    return progress;
}

@end
