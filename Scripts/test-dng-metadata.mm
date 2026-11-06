#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "../App/DNGWriter.hpp"
int main(){@autoreleasepool{
 double m[9]={1,0,0,0,1,0,0,0,1},n[3]={1,1,1};dng::Metadata meta;meta.lens="Test 70-200mm";meta.dateTime="2026:01:02 03:04:05";meta.iso=12800;meta.aperture=2.8;
 for(bool linear:{false,true}){std::vector<uint16_t> pixels(768*768*(linear?3:1),20000);const char*path=linear?"linear-test.dng":"sensor-test.dng";dng::write(path,pixels,768,768,"SONY","ILCE-1M2",m,n,1,meta,linear);
 auto src=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)],NULL);NSDictionary*properties=src?CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src,0,NULL)):nil;NSLog(@"%s: %@",path,properties);if(src)CFRelease(src);}
}}
