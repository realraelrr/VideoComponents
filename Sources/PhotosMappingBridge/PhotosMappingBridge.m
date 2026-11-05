#import "PhotosMappingBridge.h"
#import <Photos/Photos.h>

NSString *VRResolvePhotosReference(NSString *value, NSError **error) {
  @try {
    PHCloudIdentifier *cloud = [[PHCloudIdentifier alloc] initWithStringValue:value];
    PHLocalIdentifierMapping *mapping = [[PHPhotoLibrary sharedPhotoLibrary]
      localIdentifierMappingsForCloudIdentifiers:@[cloud]][cloud];
    if (mapping.localIdentifier.length > 0) return mapping.localIdentifier;
    if (error) *error = mapping.error;
  } @catch (NSException *exception) {
    if (![exception.name isEqualToString:NSInvalidArgumentException]) @throw;
    // Only the native mapping is inside this boundary. Never expose exception
    // reasons: they can contain the caller's serialized Photos reference.
    if (error) *error = [NSError errorWithDomain:@"VideoResources.PhotosReference" code:1 userInfo:nil];
  }
  return nil;
}
