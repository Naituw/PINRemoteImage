//
//  UIImage+DecodedImage.m
//  Pods
//
//  Created by Garrett Moon on 11/19/14.
//
//

#import "PINImage+DecodedImage.h"

#import <ImageIO/ImageIO.h>

#ifdef PIN_WEBP
#import "PINImage+WebP.h"
#endif

#import "NSData+ImageDetectors.h"

#if !PIN_TARGET_IOS
@implementation NSImage (PINiOSMapping)

- (CGImageRef)CGImage
{
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    NSRect rect = NSMakeRect(0.0, 0.0, self.size.width, self.size.height);
    return [self CGImageForProposedRect:&rect context:context hints:NULL];
}

+ (NSImage *)imageWithData:(NSData *)imageData;
{
    return [[self alloc] initWithData:imageData];
}

+ (NSImage *)imageWithContentsOfFile:(NSString *)path
{
    return path ? [[self alloc] initWithContentsOfFile:path] : nil;
}

+ (NSImage *)imageWithCGImage:(CGImageRef)imageRef
{
    return [[self alloc] initWithCGImage:imageRef size:CGSizeZero];
}

@end
#endif

NSData * __nullable PINImageJPEGRepresentation(PINImage * __nonnull image, CGFloat compressionQuality)
{
#if PIN_TARGET_IOS
    return UIImageJPEGRepresentation(image, compressionQuality);
#elif PIN_TARGET_MAC
    NSBitmapImageRep *imageRep = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
    NSDictionary *imageProperties = @{NSImageCompressionFactor : @(compressionQuality)};
    return [imageRep representationUsingType:NSJPEGFileType properties:imageProperties];
#endif
}

NSData * __nullable PINImagePNGRepresentation(PINImage * __nonnull image) {
#if PIN_TARGET_IOS
    return UIImagePNGRepresentation(image);
#elif PIN_TARGET_MAC
    NSBitmapImageRep *imageRep = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
    NSDictionary *imageProperties = @{NSImageCompressionFactor : @1};
    return [imageRep representationUsingType:NSPNGFileType properties:imageProperties];
#endif
}


@implementation PINImage (PINDecodedImage)

+ (PINImage *)pin_decodedImageWithData:(NSData *)data
{
    return [self pin_decodedImageWithData:data skipDecodeIfPossible:NO];
}

+ (PINImage *)pin_decodedImageWithData:(NSData *)data skipDecodeIfPossible:(BOOL)skipDecodeIfPossible
{
    if (data == nil) {
        return nil;
    }
    
#if PIN_WEBP
    if ([data pin_isWebP]) {
        return [PINImage pin_imageWithWebPData:data];
    }
#endif
    
    PINImage *decodedImage = nil;
    
    CGImageSourceRef imageSourceRef = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    
    if (imageSourceRef) {
        CGImageRef imageRef = CGImageSourceCreateImageAtIndex(imageSourceRef, 0, (CFDictionaryRef)@{(NSString *)kCGImageSourceShouldCache : (NSNumber *)kCFBooleanFalse});
        if (imageRef) {
#if PIN_TARGET_IOS
            UIImageOrientation orientation = pin_UIImageOrientationFromImageSource(imageSourceRef);
            if (skipDecodeIfPossible) {
                decodedImage = [PINImage imageWithCGImage:imageRef scale:1.0 orientation:orientation];
            } else {
                decodedImage = [self pin_decodedImageWithCGImageRef:imageRef orientation:orientation];
            }
#elif PIN_TARGET_MAC
            if (skipDecodeIfPossible) {
                CGSize imageSize = CGSizeMake(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));
                decodedImage = [[NSImage alloc] initWithCGImage:imageRef size:imageSize];
            } else {
                decodedImage = [self pin_decodedImageWithCGImageRef:imageRef];
            }
#endif
            CGImageRelease(imageRef);
        }
        
        CFRelease(imageSourceRef);
    }
    
    return decodedImage;
}

+ (PINImage *)pin_decodedImageWithCGImageRef:(CGImageRef)imageRef
{
#if PIN_TARGET_IOS
    return [self pin_decodedImageWithCGImageRef:imageRef orientation:UIImageOrientationUp];
}

+ (PINImage *)pin_decodedImageWithCGImageRef:(CGImageRef)imageRef orientation:(UIImageOrientation)orientation
{
#endif
#if PIN_TARGET_IOS
    return [UIImage imageWithCGImage:[self pin_decodedImageRefWithCGImageRef:imageRef] scale:1.0 orientation:orientation];
#elif PIN_TARGET_MAC
    return [[NSImage alloc] initWithCGImage:[self pin_decodedImageRefWithCGImageRef:imageRef] size:NSZeroSize];
#endif
}

+ (CGColorSpaceRef)pin_imageDecodingColorSpace
{
#if PIN_TARGET_MAC
    // use screen's colorSpace to prevent CA covert colorspace when preparing texture on main thread
    CGColorSpaceRef screenColorSpace = NSScreen.mainScreen.colorSpace.CGColorSpace;
    if (screenColorSpace) {
        return screenColorSpace;
    }
#endif
    
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return colorSpace;
}

+ (CGImageRef)pin_decodedImageRefWithCGImageRef:(CGImageRef)imageRef
{
    BOOL opaque = YES;
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo(imageRef);
    if (alpha == kCGImageAlphaFirst || alpha == kCGImageAlphaLast || alpha == kCGImageAlphaOnly || alpha == kCGImageAlphaPremultipliedFirst || alpha == kCGImageAlphaPremultipliedLast) {
        opaque = NO;
    }
    
    CGSize imageSize = CGSizeMake(CGImageGetWidth(imageRef), CGImageGetHeight(imageRef));
    
    CGBitmapInfo info = opaque ? (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Host) : (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    
    //Use UIGraphicsBeginImageContext parameters from docs: https://developer.apple.com/library/ios/documentation/UIKit/Reference/UIKitFunctionReference/#//apple_ref/c/func/UIGraphicsBeginImageContextWithOptions
    CGContextRef ctx = CGBitmapContextCreate(NULL, imageSize.width, imageSize.height,
                                             8,
                                             0,
                                             [self pin_imageDecodingColorSpace],
                                             info);
        
    if (ctx) {
        CGContextSetBlendMode(ctx, kCGBlendModeCopy);
        
#if PIN_TARGET_MAC
        CGSize tileSize = CGSizeMake(8000, 8000);
        if (imageSize.width > tileSize.width || imageSize.height > tileSize.height) {
            [self pin_tiledDrawCGImageRef:imageRef size:imageSize context:ctx tileSize:tileSize];
        } else {
            CGContextDrawImage(ctx, CGRectMake(0, 0, imageSize.width, imageSize.height), imageRef);
        }
#else
        CGContextDrawImage(ctx, CGRectMake(0, 0, imageSize.width, imageSize.height), imageRef);
#endif
        
        CGImageRef decodedImageRef = CGBitmapContextCreateImage(ctx);
        if (decodedImageRef) {
            CFAutorelease(decodedImageRef);
        }
        CGContextRelease(ctx);
        return decodedImageRef;
        
    }
    
    return imageRef;
}

#if PIN_TARGET_MAC
+ (void)pin_tiledDrawCGImageRef:(CGImageRef)imageRef size:(CGSize)imageSize context:(CGContextRef)context tileSize:(CGSize)tileSize
{
    NSInteger tilesPerRow = ceil(imageSize.width / tileSize.width);
    NSInteger tilesPerCol = ceil(imageSize.height / tileSize.height);
    
    for (NSInteger row = 0; row < tilesPerCol; row++) {
        for (NSInteger col = 0; col < tilesPerRow; col++) {
            CGRect rect = CGRectMake(col * tileSize.width, row * tileSize.height, tileSize.width, tileSize.height);
            if (col == tilesPerRow - 1) {
                rect.size.width = imageSize.width - rect.origin.x;
            }
            if (row == tilesPerCol - 1) {
                rect.size.height = imageSize.height - rect.origin.y;
            }
            
            CGImageRef imageTileRef = CGImageCreateWithImageInRect(imageRef, rect);
            rect.origin.y = imageSize.height - rect.origin.y - rect.size.height;
            CGContextDrawImage(context, rect, imageTileRef);
        }
    }
}
#endif

#if PIN_TARGET_IOS
UIImageOrientation pin_UIImageOrientationFromImageSource(CGImageSourceRef imageSourceRef) {
    UIImageOrientation orientation = UIImageOrientationUp;
    
    if (imageSourceRef != nil) {
        NSDictionary *dict = (NSDictionary *)CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(imageSourceRef, 0, NULL));
        
        if (dict != nil) {
            
            NSNumber* exifOrientation = dict[(id)kCGImagePropertyOrientation];
            if (exifOrientation != nil) {
                
                switch (exifOrientation.intValue) {
                    case 1: /*kCGImagePropertyOrientationUp*/
                        orientation = UIImageOrientationUp;
                        break;
                        
                    case 2: /*kCGImagePropertyOrientationUpMirrored*/
                        orientation = UIImageOrientationUpMirrored;
                        break;
                        
                    case 3: /*kCGImagePropertyOrientationDown*/
                        orientation = UIImageOrientationDown;
                        break;
                        
                    case 4: /*kCGImagePropertyOrientationDownMirrored*/
                        orientation = UIImageOrientationDownMirrored;
                        break;
                    case 5: /*kCGImagePropertyOrientationLeftMirrored*/
                        orientation = UIImageOrientationLeftMirrored;
                        break;
                        
                    case 6: /*kCGImagePropertyOrientationRight*/
                        orientation = UIImageOrientationRight;
                        break;
                        
                    case 7: /*kCGImagePropertyOrientationRightMirrored*/
                        orientation = UIImageOrientationRightMirrored;
                        break;
                        
                    case 8: /*kCGImagePropertyOrientationLeft*/
                        orientation = UIImageOrientationLeft;
                        break;
                        
                    default:
                        break;
                }
            }
        }
    }
    
    return orientation;
}

#endif

@end
