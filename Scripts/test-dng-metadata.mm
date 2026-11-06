#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "../App/DNGWriter.hpp"
int main(){@autoreleasepool{
 double m[9]={1,0,0,0,1,0,0,0,1},n[3]={1,1,1};dng::Metadata meta;meta.lens="Test 70-200mm";meta.dateTime="2026:01:02 03:04:05";meta.iso=12800;meta.aperture=2.8;
 for(bool linear:{false,true}){int w=linear?8672:768,h=linear?5784:768;std::vector<uint16_t> pixels((size_t)w*h*(linear?3:1),20000);const char*path=linear?"linear-test.dng":"sensor-test.dng";dng::write(path,pixels,w,h,"SONY","ILCE-1M2",m,n,1,meta,linear);
 auto src=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)],NULL);NSDictionary*properties=src?CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src,0,NULL)):nil;NSLog(@"%s: %@",path,properties);
 if(!properties || ![properties[@"{TIFF}"][@"Make"] isEqual:@"SONY"] || ![properties[@"{Exif}"][@"DateTimeOriginal"] isEqual:@"2026:01:02 03:04:05"])return 1;
 CGImageRef image=CGImageSourceCreateImageAtIndex(src,0,NULL);if(!image || CGImageGetWidth(image)!=w || CGImageGetHeight(image)!=h)return 2;
 NSLog(@"Full image decoded: %zu x %zu",CGImageGetWidth(image),CGImageGetHeight(image));CGImageRelease(image);
 CGImageRef preview=CGImageSourceCreateThumbnailAtIndex(src,0,(__bridge CFDictionaryRef)@{(NSString*)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(NSString*)kCGImageSourceThumbnailMaxPixelSize:@4096});if(!preview)return 3;
 NSLog(@"Preview decoded: %zu x %zu",CGImageGetWidth(preview),CGImageGetHeight(preview));CGImageRelease(preview);if(src)CFRelease(src);}
}}
