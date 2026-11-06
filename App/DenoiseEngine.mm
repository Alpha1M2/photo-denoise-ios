#import "DenoiseEngine.h"
#import <onnxruntime_objc/onnxruntime.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "libraw/libraw.h"
#include "DNGWriter.hpp"
#include <memory>
#include <cmath>
static NSError *failure(NSString*s){return [NSError errorWithDomain:@"JingYing" code:1 userInfo:@{NSLocalizedDescriptionKey:s}];}
static int mirror(int n,int size){if(size<=1)return 0;while(n<0||n>=size){if(n<0)n=-n;if(n>=size)n=2*size-2-n;}return n;}
static std::vector<int> starts(int n,int core){std::vector<int> r;for(int i=0;i<n;i+=core)r.push_back(i);return r;}
@implementation DenoiseEngine
+ (UIImage*)rawPreview:(NSURL*)url {
 auto owner=std::make_unique<LibRaw>();auto&reader=*owner;reader.imgdata.params.half_size=0;reader.imgdata.params.use_camera_wb=1;reader.imgdata.params.output_color=1;reader.imgdata.params.output_bps=8;
 if(reader.open_file(url.fileSystemRepresentation)||reader.unpack()||reader.dcraw_process())return nil;
 int rc=0;libraw_processed_image_t*p=reader.dcraw_make_mem_image(&rc);
 if(!p||rc||p->type!=LIBRAW_IMAGE_BITMAP||p->colors!=3||p->bits!=8){if(p)LibRaw::dcraw_clear_mem(p);return nil;}
 NSData*data=[NSData dataWithBytes:p->data length:p->data_size];
 CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
 CGImageRef cg=CGImageCreate(p->width,p->height,8,24,p->width*3,space,kCGImageAlphaNone,provider,NULL,false,kCGRenderingIntentDefault);
 UIImage*image=cg?[UIImage imageWithCGImage:cg]:nil;
 if(cg)CGImageRelease(cg);CGColorSpaceRelease(space);CGDataProviderRelease(provider);LibRaw::dcraw_clear_mem(p);return image;
}
+ (BOOL)writeSmokeRaw:(NSURL*)url {
 double m[9]={.8161,-.2947,-.0739,-.4811,1.2668,.2389,-.0437,.1229,.6524};double n[3]={1024./1871,1,1024./2244};std::vector<uint16_t> p(128*128,8192);
 return dng::write(url.fileSystemRepresentation,p,128,128,"SONY","ILCE-1M2",m,n,1);
}
- (NSURL*)process:(NSURL*)source destination:(NSURL*)destination strength:(float)strength raw:(BOOL)raw preview:(BOOL)preview center:(CGPoint)center progress:(void(^)(double))progress error:(NSError**)error {
 if(self.cancelled){if(error)*error=failure(@"已取消");return nil;}
 strength=std::clamp(strength,0.f,1.f);
 if([[NSFileManager defaultManager] fileExistsAtPath:destination.path]){if(error)*error=failure(@"输出文件已存在，请使用新文件名。");return nil;}
 NSString*model=[[NSBundle mainBundle] pathForResource:raw?@"raw":@"rgb" ofType:@"onnx"];
 if(!model){if(error)*error=failure(@"安装包缺少 AI 模型。");return nil;}
 ORTEnv*env=[[ORTEnv alloc] initWithLoggingLevel:ORTLoggingLevelWarning error:error];if(!env)return nil;
 ORTSessionOptions*opts=[[ORTSessionOptions alloc] initWithError:error];if(!opts)return nil;
 [opts setIntraOpNumThreads:2 error:nil];
 // Conservative CPU baseline; accelerator support must pass device testing before enabled by default.
 ORTSession*session=[[ORTSession alloc] initWithEnv:env modelPath:model sessionOptions:opts error:error];if(!session)return nil;
 NSString*inName=[[session inputNamesWithError:error] firstObject];NSString*outName=[[session outputNamesWithError:error] firstObject];if(!inName||!outName)return nil;
 int tile=raw?512:768, pad=32, core=tile-2*pad, channels=raw?4:3;
 bool linear=!raw && [destination.pathExtension.lowercaseString isEqualToString:@"dng"];std::vector<float> rgbFloat;
 int width=0,height=0;std::unique_ptr<LibRaw> reader;std::vector<uint8_t> rgba;std::vector<uint16_t> output;
 int cx=0,cy=0;double wb[4]={1,1,1,1}, blacks[4]={}, ranges[4]={};
 CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
 if(raw){
   reader=std::make_unique<LibRaw>();int rc=reader->open_file(source.fileSystemRepresentation);if(!rc)rc=reader->unpack();
   if(rc || !reader->imgdata.rawdata.raw_image || reader->imgdata.idata.filters==9 || reader->imgdata.idata.filters==0){CGColorSpaceRelease(color);if(error)*error=failure(@"此 RAW 格式尚不支持，或解码失败。请保留原片。");return nil;}
   auto&s=reader->imgdata.sizes;cx=s.left_margin;cy=s.top_margin;
   int visibleW=s.width,visibleH=s.height;auto crop=s.raw_inset_crops[0];
   if(crop.cwidth>0 && crop.cheight>0 && crop.cleft+crop.cwidth<=s.raw_width && crop.ctop+crop.cheight<=s.raw_height){cx=crop.cleft;cy=crop.ctop;visibleW=crop.cwidth;visibleH=crop.cheight;}
   int baseX=cx,baseY=cy;bool found=false;
   for(int y=0;y<2;y++)for(int x=0;x<2;x++)if(reader->COLOR(cy+y,cx+x)==0){cx+=x;cy+=y;found=true;goto origin;}
   origin: if(!found){CGColorSpaceRelease(color);if(error)*error=failure(@"无法识别 Bayer 排列。");return nil;}
   width=(visibleW-(cx-baseX))&~1;height=(visibleH-(cy-baseY))&~1;
   auto&c=reader->imgdata.color;double green=c.pre_mul[1];
   if(green<=0)green=1;wb[0]=c.pre_mul[0]/green;wb[1]=wb[2]=1;wb[3]=c.pre_mul[2]/green;
   for(int i=0;i<4;i++){int fc=reader->COLOR(cy+i/2,cx+i%2);blacks[i]=c.black+c.cblack[fc];ranges[i]=std::max(1.,(double)c.maximum-blacks[i]);if(wb[i]<=0)wb[i]=1;}
   if(preview){int pw=std::min(width,1024),ph=std::min(height,1024);cx+=((int)std::clamp(center.x*width-pw/2,0.,(double)(width-pw)))&~1;cy+=((int)std::clamp(center.y*height-ph/2,0.,(double)(height-ph)))&~1;width=pw;height=ph;}
   if((double)width*height>65000000){CGColorSpaceRelease(color);if(error)*error=failure(@"RAW 超过6500万像素限制。");return nil;}
   output.resize((size_t)width*height);
 }else{
   CIImage*ci=[CIImage imageWithContentsOfURL:source options:@{kCIImageApplyOrientationProperty:@YES,kCIImageColorSpace:(__bridge id)color}];
   if(!ci){CGColorSpaceRelease(color);if(error)*error=failure(@"无法读取图片。");return nil;}
   CGRect rect=ci.extent;
   if(preview){CGFloat w=MIN(1024,rect.size.width),h=MIN(1024,rect.size.height);rect=CGRectMake(MAX(0,MIN(rect.size.width-w,center.x*rect.size.width-w/2)),MAX(0,MIN(rect.size.height-h,(1-center.y)*rect.size.height-h/2)),w,h);}
   width=rect.size.width;height=rect.size.height;
   if(width<1||height<1||(double)width*height>65000000){CGColorSpaceRelease(color);if(error)*error=failure(@"图片超过此版本的 6500 万像素限制。");return nil;}
   rgba.resize((size_t)width*height*4);
   CIContext*ctx=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
   if(linear){rgbFloat.resize((size_t)width*height*4);output.resize((size_t)width*height*3);[ctx render:ci toBitmap:rgbFloat.data() rowBytes:width*4*sizeof(float) bounds:rect format:kCIFormatRGBAf colorSpace:color];}else [ctx render:ci toBitmap:rgba.data() rowBytes:width*4 bounds:rect format:kCIFormatRGBA8 colorSpace:color];
 }
 const int W=raw?width/2:width,H=raw?height/2:height;
 auto xs=starts(W,core),ys=starts(H,core);int done=0,total=(int)(xs.size()*ys.size());
 // Keep an immutable RGB source to avoid tile-to-tile contamination while writing the destination.
 std::vector<uint8_t> original=rgba;
 for(int ty:ys)for(int tx:xs){@autoreleasepool {
   if(self.cancelled){CGColorSpaceRelease(color);if(error)*error=failure(@"已取消；原片未修改。");return nil;}
   NSMutableData*data=[NSMutableData dataWithLength:(size_t)channels*tile*tile*sizeof(float)];float*input=(float*)data.mutableBytes;double sum=0;
   for(int y=0;y<tile;y++)for(int x=0;x<tile;x++){
     int sx=mirror(tx+x-pad,W),sy=mirror(ty+y-pad,H);
     for(int c=0;c<channels;c++){
       float v;if(raw){int rx=cx+sx*2+c%2,ry=cy+sy*2+c/2;auto&s=reader->imgdata.sizes;unsigned short*row=(unsigned short*)((uint8_t*)reader->imgdata.rawdata.raw_image+(size_t)ry*s.raw_pitch);v=(row[rx]-blacks[c])/ranges[c]*wb[c];}
       else v=linear?rgbFloat[((size_t)sy*width+sx)*4+c]:original[((size_t)sy*width+sx)*4+c]/255.f;
       input[((size_t)c*tile+y)*tile+x]=v;sum+=v;
     }
   }
   if(strength==0 && !linear){
     if(raw)for(int y=0;y<std::min(core,H-ty);y++)for(int x=0;x<std::min(core,W-tx);x++)for(int p=0;p<4;p++){
       double v=input[((size_t)p*tile+y+pad)*tile+x+pad]/wb[p];output[((size_t)(ty+y)*2+p/2)*width+(tx+x)*2+p%2]=(uint16_t)std::llround(std::clamp(v,0.,1.)*65535);
     }
     progress((double)++done/total);continue;
   }
   ORTValue*value=[[ORTValue alloc] initWithTensorData:data elementType:ORTTensorElementDataTypeFloat shape:@[@1,@(channels),@(tile),@(tile)] error:error];if(!value){CGColorSpaceRelease(color);return nil;}
   NSDictionary*values=[session runWithInputs:@{inName:value} outputNames:[NSSet setWithObject:outName] runOptions:nil error:error];if(!values){CGColorSpaceRelease(color);return nil;}
   NSMutableData*result=[values[outName] tensorDataWithError:error];int outTile=raw?tile*2:tile;
   if(!result||result.length!=(size_t)3*outTile*outTile*4){CGColorSpaceRelease(color);if(error)*error=failure(@"AI 输出尺寸不匹配。");return nil;}
   float*pred=(float*)result.mutableBytes;double gain=1;
   if(raw){double outSum=0;for(size_t i=0;i<result.length/4;i++)outSum+=pred[i];double inMean=sum/(channels*tile*tile),outMean=outSum/(3*outTile*outTile);if(std::abs(outMean)>std::abs(inMean)*1e-6)gain=inMean/outMean;}
   for(int y=0;y<std::min(core,H-ty);y++)for(int x=0;x<std::min(core,W-tx);x++){
     if(raw){for(int p=0;p<4;p++){
       int ch=p==0?0:(p==3?2:1);int oy=(y+pad)*2+p/2,ox=(x+pad)*2+p%2;
       double den=pred[((size_t)ch*outTile+oy)*outTile+ox]*gain/wb[p];
       double src=input[((size_t)p*tile+y+pad)*tile+x+pad]/wb[p];
       double v=src+(den-src)*strength;
       output[((size_t)(ty+y)*2+p/2)*width+(tx+x)*2+p%2]=(uint16_t)std::llround(std::clamp(v,0.,1.)*65535);
     }}else for(int c=0;c<3;c++){
       float src=input[((size_t)c*tile+y+pad)*tile+x+pad];float den=pred[((size_t)c*tile+y+pad)*tile+x+pad];
       float blended=std::clamp(src+(den-src)*strength,0.f,1.f);if(linear){double v=blended<=0.04045?blended/12.92:std::pow((blended+0.055)/1.055,2.4);output[((size_t)(ty+y)*width+tx+x)*3+c]=(uint16_t)std::llround(v*65535);}else rgba[((size_t)(ty+y)*width+tx+x)*4+c]=(uint8_t)std::lround(std::clamp(src+(den-src)*strength,0.f,1.f)*255);
     }
   }
   progress((double)++done/total);
 }}
 if(self.cancelled){CGColorSpaceRelease(color);if(error)*error=failure(@"已取消");return nil;}
 BOOL ok=NO;
 if(raw){auto&c=reader->imgdata.color;double matrix[9],neutral[3];for(int i=0;i<9;i++)matrix[i]=c.cam_xyz[i/3][i%3];double g=c.cam_mul[1]>0?c.cam_mul[1]:1;for(int i=0;i<3;i++)neutral[i]=c.cam_mul[i]>0?g/c.cam_mul[i]:1;
   int flip=reader->imgdata.sizes.flip,orientation=flip==3?3:(flip==5?8:(flip==6?6:1));
   dng::Metadata meta;meta.lens=reader->imgdata.lens.Lens;meta.focal=reader->imgdata.other.focal_len;meta.aperture=reader->imgdata.other.aperture;meta.exposure=reader->imgdata.other.shutter;meta.iso=reader->imgdata.other.iso_speed;
   ok=dng::write(destination.fileSystemRepresentation,output,width,height,reader->imgdata.idata.make,reader->imgdata.idata.model,matrix,neutral,orientation,meta);
 }else if(linear){double matrix[9]={3.2404542,-1.5371385,-0.4985314,-0.9692660,1.8760108,0.0415560,0.0556434,-0.2040259,1.0572252},neutral[3]={1,1,1};ok=dng::write(destination.fileSystemRepresentation,output,width,height,"JingYing","Linear sRGB",matrix,neutral,1,dng::Metadata(),true);
 }else{
   CGContextRef bitmap=CGBitmapContextCreate(rgba.data(),width,height,8,width*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrderDefault);CGImageRef im=bitmap?CGBitmapContextCreateImage(bitmap):nil;
   if(im){
     NSMutableDictionary*properties=[NSMutableDictionary dictionaryWithDictionary:@{(__bridge NSString*)kCGImageDestinationLossyCompressionQuality:@0.97,(__bridge NSString*)kCGImagePropertyOrientation:@1}];
     CGImageSourceRef inputSource=CGImageSourceCreateWithURL((__bridge CFURLRef)source,nil);
     if(inputSource){NSDictionary*sourceProperties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(inputSource,0,nil));NSMutableDictionary*exif=[sourceProperties[(__bridge NSString*)kCGImagePropertyExifDictionary] mutableCopy];if(exif){exif[(__bridge NSString*)kCGImagePropertyExifPixelXDimension]=@(width);exif[(__bridge NSString*)kCGImagePropertyExifPixelYDimension]=@(height);properties[(__bridge NSString*)kCGImagePropertyExifDictionary]=exif;}CFRelease(inputSource);}
     CGImageDestinationRef dst=CGImageDestinationCreateWithURL((__bridge CFURLRef)destination,(__bridge CFStringRef)UTTypeJPEG.identifier,1,nil);
     if(dst){CGImageDestinationAddImage(dst,im,(__bridge CFDictionaryRef)properties);ok=CGImageDestinationFinalize(dst);CFRelease(dst);}CGImageRelease(im);
   }if(bitmap)CGContextRelease(bitmap);
 }
 CGColorSpaceRelease(color);if(!ok){[[NSFileManager defaultManager] removeItemAtURL:destination error:nil];if(error)*error=failure(@"写入失败，请检查存储空间。");return nil;}return destination;
}
@end
