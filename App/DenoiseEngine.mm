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
+ (NSString*)testLinearFixture {
 const int w=601,h=319;std::vector<uint16_t> pixels((size_t)w*h*4);
 for(int y=0;y<h;y++)for(int x=0;x<w;x++){for(int c=0;c<3;c++)pixels[((size_t)y*w+x)*4+c]=1000+(x*31+y*53+c*7000)%50000;pixels[((size_t)y*w+x)*4+3]=65535;}
 NSURL*src=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".jyl"]]];
 NSURL*dst=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".dng"]]];
 uint32_t header[3]={0x314c594a,w,h};std::ofstream f(src.fileSystemRepresentation,std::ios::binary);f.write((char*)header,12);
 for(size_t i=0;i<(size_t)w*h;i++)f.write((char*)&pixels[i*4],6);BOOL ok=f.good();f.close();
 DenoiseEngine*engine=[DenoiseEngine new];engine.useLocalLinearModel=YES;
 if(ok)ok=[engine process:src destination:dst strength:1 raw:NO preview:NO center:CGPointZero progress:^(double v){} error:nil]!=nil;
 NSData*out=[NSData dataWithContentsOfURL:dst];size_t length=(size_t)w*h*6;
 if(!out||out.length<length)ok=NO;
 int maximum=0,flippedMaximum=0,first=-1;
 if(ok){const uint16_t*p=(const uint16_t*)((const uint8_t*)out.bytes+out.length-length);first=p[0];for(size_t i=0;i<(size_t)w*h;i++)for(int c=0;c<3;c++){maximum=std::max(maximum,std::abs((int)p[i*3+c]-(int)pixels[i*4+c]));size_t flipped=(h-1-i/w)*w+i%w;flippedMaximum=std::max(flippedMaximum,std::abs((int)p[i*3+c]-(int)pixels[flipped*4+c]));}}
 BOOL passed=ok && maximum<=3;
 NSURL*crop=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".dng"]]];
 engine.requestedPreviewRegion=CGRectMake(.7,.1,.2,.2);
 BOOL previewOK=[engine process:src destination:crop strength:1 raw:NO preview:YES center:CGPointZero progress:^(double v){} error:nil]!=nil;
 CGRect region=engine.processedRegion;int rx=std::lround(region.origin.x*w),ry=std::lround(region.origin.y*h),rw=std::lround(region.size.width*w),rh=std::lround(region.size.height*h);
 NSData*previewData=[NSData dataWithContentsOfURL:crop];size_t cropBytes=(size_t)rw*rh*6;
 if(!previewData||previewData.length<cropBytes||engine.workUnits>=engine.fullWorkUnits)previewOK=NO;
 if(previewOK){const uint16_t*p=(const uint16_t*)((const uint8_t*)previewData.bytes+previewData.length-cropBytes);for(int y=0;y<rh;y++)for(int x=0;x<rw;x++)for(int c=0;c<3;c++)if(std::abs((int)p[((size_t)y*rw+x)*3+c]-(int)pixels[((size_t)(ry+y)*w+rx+x)*4+c])>1)previewOK=NO;}
 [[NSFileManager defaultManager] removeItemAtURL:crop error:nil];
 engine.requestedPreviewRegion=CGRectMake(0,0,1,1);
 NSURL*cancelledOutput=[engine process:src destination:crop strength:1 raw:NO preview:YES center:CGPointZero progress:^(double v){if(v>0)engine.cancelled=YES;} error:nil];
 BOOL cancelOK=cancelledOutput==nil&&![[NSFileManager defaultManager] fileExistsAtPath:crop.path];
 passed=passed&&previewOK&&cancelOK;
 // Compare banded preparation against a single full-frame render to detect Y flips and seams.
 NSURL*tiff=[src URLByAppendingPathExtension:@"tiff"],*prepared=[src URLByAppendingPathExtension:@"prepared"];
 CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceLinearSRGB);CIContext*ctx=[CIContext contextWithOptions:@{kCIContextWorkingFormat:@(kCIFormatRGBAf)}];
 NSData*bitmap=[NSData dataWithBytes:pixels.data() length:pixels.size()*2];CIImage*image=[CIImage imageWithBitmapData:bitmap bytesPerRow:w*8 size:CGSizeMake(w,h) format:kCIFormatRGBA16 colorSpace:cs];
 BOOL bands=[ctx writeTIFFRepresentationOfImage:image toURL:tiff format:kCIFormatRGBA16 colorSpace:cs options:@{} error:nil]&&[DenoiseEngine prepareImageBuffer:tiff destination:prepared linear:YES error:nil];
 std::vector<uint16_t> expected((size_t)w*h*4);CIImage*decoded=[CIImage imageWithContentsOfURL:tiff];if(decoded)[ctx render:decoded toBitmap:expected.data() rowBytes:w*8 bounds:decoded.extent format:kCIFormatRGBA16 colorSpace:cs];else bands=NO;
 NSData*preparedData=[NSData dataWithContentsOfURL:prepared];if(preparedData.length!=12+(size_t)w*h*6)bands=NO;
 if(bands){const uint16_t*p=(const uint16_t*)((const uint8_t*)preparedData.bytes+12);for(size_t i=0;i<(size_t)w*h;i++)for(int c=0;c<3;c++)if(std::abs((int)p[i*3+c]-(int)expected[i*4+c])>1)bands=NO;}
 CGColorSpaceRelease(cs);[[NSFileManager defaultManager] removeItemAtURL:tiff error:nil];[[NSFileManager defaultManager] removeItemAtURL:prepared error:nil];passed=passed&&bands;
 [[NSFileManager defaultManager] removeItemAtURL:src error:nil];[[NSFileManager defaultManager] removeItemAtURL:dst error:nil];return [NSString stringWithFormat:@"%@: IO=%d max=%d flipped=%d first=%d expected=%d preview=%d cancel=%d bands=%d",passed?@"PASS":@"FAIL",ok,maximum,flippedMaximum,first,pixels[0],previewOK,cancelOK,bands];
}
 + (BOOL)prepareImageBuffer:(NSURL*)source destination:(NSURL*)destination linear:(BOOL)linear error:(NSError**)error {
 CIImage*ci=[CIImage imageWithContentsOfURL:source options:@{kCIImageApplyOrientationProperty:@YES}];if(!ci){if(error)*error=failure(@"无法读取输入图像，未能建立解码缓存。");return NO;}
 return [self prepareCIImage:ci destination:destination linear:linear error:error];
}
+ (BOOL)prepareCIImage:(CIImage*)ci destination:(NSURL*)destination linear:(BOOL)linear error:(NSError**)error {
 int w=ci.extent.size.width,h=ci.extent.size.height;if(w<1||h<1||(double)w*h>65000000){if(error)*error=failure(@"图像尺寸不支持");return NO;}
 CGColorSpaceRef cs=CGColorSpaceCreateWithName(linear?kCGColorSpaceLinearSRGB:kCGColorSpaceSRGB);
 CIContext*ctx=[CIContext contextWithOptions:@{kCIContextWorkingFormat:@(kCIFormatRGBAf),kCIContextCacheIntermediates:@NO}];
 std::vector<uint16_t> row((size_t)w*4);uint32_t header[3]={0x314c594a,(uint32_t)w,(uint32_t)h};std::ofstream f(destination.fileSystemRepresentation,std::ios::binary);f.write((char*)header,12);
 // Render bands in display order; inference and TIFF/DNG samples are top-down.
 const int band=64;std::vector<uint16_t> data((size_t)w*band*4);
 for(int y=0;y<h;y+=band){int bh=std::min(band,h-y);CGRect rect=CGRectMake(ci.extent.origin.x,ci.extent.origin.y+h-y-bh,w,bh);
 [ctx render:ci toBitmap:data.data() rowBytes:w*8 bounds:rect format:kCIFormatRGBA16 colorSpace:cs];
 for(int j=0;j<bh;j++)for(int x=0;x<w;x++)f.write((char*)&data[((size_t)j*w+x)*4],6);}
 CGColorSpaceRelease(cs);BOOL ok=f.good();if(!ok&&error)*error=failure(@"无法写入图像缓存");return ok;
}
+ (BOOL)hasLocalLinearModel {return [[NSBundle mainBundle] pathForResource:@"local-linear" ofType:@"onnx"] != nil;}
+ (BOOL)renderLinearRaw:(NSURL*)source destination:(NSURL*)destination error:(NSError**)error {
 auto reader=std::make_unique<LibRaw>();auto&p=reader->imgdata.params;p.use_camera_wb=1;p.no_auto_bright=1;p.output_color=1;p.output_bps=16;p.gamm[0]=1;p.gamm[1]=1;
 int rc=reader->open_file(source.fileSystemRepresentation);if(!rc)rc=reader->unpack();if(!rc)rc=reader->dcraw_process();
 if(rc){if(error)*error=failure(@"RAW 线性解码失败");return NO;}
 libraw_processed_image_t*im=reader->dcraw_make_mem_image(&rc);
 if(!im||rc||im->colors!=3||im->bits!=16){if(im)LibRaw::dcraw_clear_mem(im);if(error)*error=failure(@"RAW 线性输出格式不支持");return NO;}
 uint32_t header[3]={0x314c594a,im->width,im->height};std::ofstream f(destination.fileSystemRepresentation,std::ios::binary);
 f.write((const char*)header,sizeof(header));f.write((const char*)im->data,im->data_size);BOOL ok=f.good();f.close();LibRaw::dcraw_clear_mem(im);
 if(!ok&&error)*error=failure(@"Unable to write linear RAW buffer");return ok;
}
+ (UIImage*)linearBufferPreview:(NSURL*)url {
 NSData*data=[NSData dataWithContentsOfURL:url];if(data.length<12)return nil;const uint8_t*bytes=(const uint8_t*)data.bytes;uint32_t header[3];memcpy(header,bytes,12);size_t offset=12;
 if(header[0]!=0x314c594a){
   if(bytes[0]!='I'||bytes[1]!='I'||bytes[2]!=42||bytes[3]!=0)return nil;
   uint32_t root=0;memcpy(&root,bytes+4,4);if((size_t)root+2>data.length)return nil;uint16_t tags=0;memcpy(&tags,bytes+root,2);if((size_t)root+2+(size_t)tags*12>data.length)return nil;
   header[1]=header[2]=0;uint32_t photo=0,samples=0;offset=0;
   for(unsigned i=0;i<tags;i++){const uint8_t*entry=bytes+root+2+i*12;uint16_t tag=0;uint32_t value=0;memcpy(&tag,entry,2);memcpy(&value,entry+8,4);if(tag==256)header[1]=value;if(tag==257)header[2]=value;if(tag==262)photo=value;if(tag==277)samples=value;if(tag==273)offset=value;}
   if(photo!=34892||samples!=3)return nil;
 }
 size_t count=(size_t)header[1]*header[2];if(!count||count>65000000||offset+count*6!=data.length)return nil;
 NSMutableData*pixels=[NSMutableData dataWithLength:count*4];const uint16_t*src=(const uint16_t*)(bytes+offset);uint8_t*dst=(uint8_t*)pixels.mutableBytes;
 static const std::vector<uint8_t> transfer=[](){std::vector<uint8_t> t(65536);for(int i=0;i<65536;i++){double v=i/65535.;v=v<=.0031308?12.92*v:1.055*std::pow(v,1./2.4)-.055;t[i]=(uint8_t)std::lround(std::clamp(v,0.,1.)*255);}return t;}();
 for(size_t i=0;i<count;i++){for(int c=0;c<3;c++)dst[i*4+c]=transfer[src[i*3+c]];dst[i*4+3]=255;}
 CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
 CGImageRef cg=CGImageCreate(header[1],header[2],8,32,header[1]*4,cs,kCGImageAlphaNoneSkipLast,provider,NULL,false,kCGRenderingIntentDefault);
 UIImage*image=cg?[UIImage imageWithCGImage:cg]:nil;if(cg)CGImageRelease(cg);CGColorSpaceRelease(cs);CGDataProviderRelease(provider);return image;
}
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
 double m[9]={.8161,-.2947,-.0739,-.4811,1.2668,.2389,-.0437,.1229,.6524};double n[3]={1024./1871,1,1024./2244};std::vector<uint16_t> p(768*768,8192);
 return dng::write(url.fileSystemRepresentation,p,768,768,"SONY","ILCE-1M2",m,n,1);
}
- (NSURL*)process:(NSURL*)source destination:(NSURL*)destination strength:(float)strength raw:(BOOL)raw preview:(BOOL)preview center:(CGPoint)center progress:(void(^)(double))progress error:(NSError**)error {
 if(self.cancelled){if(error)*error=failure(@"已取消");return nil;}
 strength=std::clamp(strength,0.f,1.f);
 if([[NSFileManager defaultManager] fileExistsAtPath:destination.path]){if(error)*error=failure(@"输出文件已存在，请使用新文件名。");return nil;}
 NSURL*staging=[destination URLByAppendingPathExtension:@"partial"];
 BOOL localLinear=self.useLocalLinearModel && !raw && [destination.pathExtension.lowercaseString isEqualToString:@"dng"] && [DenoiseEngine hasLocalLinearModel];
 NSString*model=[[NSBundle mainBundle] pathForResource:localLinear?@"local-linear":(raw?@"raw":@"rgb") ofType:@"onnx"];
 if(!model){if(error)*error=failure(@"安装包缺少 AI 模型。");return nil;}
 ORTEnv*env=[[ORTEnv alloc] initWithLoggingLevel:ORTLoggingLevelWarning error:error];if(!env)return nil;
 ORTSessionOptions*opts=[[ORTSessionOptions alloc] initWithError:error];if(!opts)return nil;
 [opts setIntraOpNumThreads:2 error:nil];
 // Conservative CPU baseline; accelerator support must pass device testing before enabled by default.
 ORTSession*session=[[ORTSession alloc] initWithEnv:env modelPath:model sessionOptions:opts error:error];if(!session)return nil;
 NSString*inName=[[session inputNamesWithError:error] firstObject];NSString*outName=[[session outputNamesWithError:error] firstObject];if(!inName||!outName)return nil;
 int tile=localLinear?512:(raw?512:768), pad=localLinear?112:32, core=tile-2*pad, channels=raw?4:3;
 bool linear=!raw && [destination.pathExtension.lowercaseString isEqualToString:@"dng"];std::vector<uint16_t> rgb16;
 int width=0,height=0;std::unique_ptr<LibRaw> reader;std::vector<uint8_t> rgba;std::vector<uint16_t> output;
 int cx=0,cy=0;double wb[4]={1,1,1,1}, blacks[4]={}, ranges[4]={};
 CGColorSpaceRef color=CGColorSpaceCreateWithName(localLinear?kCGColorSpaceLinearSRGB:kCGColorSpaceSRGB);
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
   if((double)width*height>65000000){CGColorSpaceRelease(color);if(error)*error=failure(@"RAW 超过6500万像素限制。");return nil;}
   output.resize((size_t)width*height);
 }else if([source.pathExtension.lowercaseString isEqualToString:@"jyl"]){
   std::ifstream f(source.fileSystemRepresentation,std::ios::binary);uint32_t header[3]={};f.read((char*)header,12);width=header[1];height=header[2];
   if(!f||header[0]!=0x314c594a||width<1||height<1||(double)width*height>65000000){CGColorSpaceRelease(color);if(error)*error=failure(@"Invalid linear RAW buffer");return nil;}
   rgb16.resize((size_t)width*height*4);if(linear)output.resize((size_t)width*height*3);else rgba.assign((size_t)width*height*4,255);std::vector<uint16_t> row((size_t)width*3);
   for(int y=0;y<height;y++){f.read((char*)row.data(),row.size()*2);for(int x=0;x<width;x++){for(int c=0;c<3;c++)rgb16[((size_t)y*width+x)*4+c]=row[x*3+c];rgb16[((size_t)y*width+x)*4+3]=65535;}}
   if(!f){CGColorSpaceRelease(color);if(error)*error=failure(@"Truncated linear RAW buffer");return nil;}
 }else{
   CIImage*ci=[CIImage imageWithContentsOfURL:source options:@{kCIImageApplyOrientationProperty:@YES}];
   if(!ci){CGColorSpaceRelease(color);if(error)*error=failure(@"无法读取图片。");return nil;}
   CGRect rect=ci.extent;
   width=rect.size.width;height=rect.size.height;
   if(width<1||height<1||(double)width*height>65000000){CGColorSpaceRelease(color);if(error)*error=failure(@"图片超过此版本的 6500 万像素限制。");return nil;}
   if(!linear)rgba.resize((size_t)width*height*4);
   CIContext*ctx=[CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO,kCIContextWorkingFormat:@(kCIFormatRGBAf)}];
   if(linear){rgb16.resize((size_t)width*height*4);output.resize((size_t)width*height*3);[ctx render:ci toBitmap:rgb16.data() rowBytes:width*4*sizeof(uint16_t) bounds:rect format:kCIFormatRGBA16 colorSpace:color];}else [ctx render:ci toBitmap:rgba.data() rowBytes:width*4 bounds:rect format:kCIFormatRGBA8 colorSpace:color];
 }
 const int W=raw?width/2:width,H=raw?height/2:height;
 auto xs=starts(W,core),ys=starts(H,core);self.fullWorkUnits=xs.size()*ys.size();self.sourceSize=CGSizeMake(width,height);
 int roiX=0,roiY=0,roiW=width,roiH=height;
 if(preview){CGRect requested=self.requestedPreviewRegion;double rw=requested.size.width>0?requested.size.width*width:1024,rh=requested.size.height>0?requested.size.height*height:1024;double scale=std::min(1.,1024./std::max(rw,rh));roiW=std::max(1,std::min(width,(int)(rw*scale)));roiH=std::max(1,std::min(height,(int)(rh*scale)));double mx=requested.size.width>0?CGRectGetMidX(requested):center.x,my=requested.size.height>0?CGRectGetMidY(requested):center.y;roiX=std::clamp((int)(mx*width-roiW/2),0,width-roiW);roiY=std::clamp((int)(my*height-roiH/2),0,height-roiH);
 if(raw){roiX&=~1;roiY&=~1;roiW&=~1;roiH&=~1;}
 int factor=raw?2:1;xs.erase(std::remove_if(xs.begin(),xs.end(),[&](int x){return x*factor>=roiX+roiW||(x+core)*factor<=roiX;}),xs.end());ys.erase(std::remove_if(ys.begin(),ys.end(),[&](int y){return y*factor>=roiY+roiH||(y+core)*factor<=roiY;}),ys.end());}
 self.processedRegion=CGRectMake((double)roiX/width,(double)roiY/height,(double)roiW/width,(double)roiH/height);
 int done=0,total=(int)(xs.size()*ys.size());self.workUnits=total;progress(0);
 // Keep an immutable RGB source to avoid tile-to-tile contamination while writing the destination.
 std::vector<uint8_t> original=rgb16.empty()?rgba:std::vector<uint8_t>();
 for(int ty:ys)for(int tx:xs){
   if(self.cancelled){CGColorSpaceRelease(color);if(error)*error=failure(@"已取消；原片未修改。");return nil;}
   @autoreleasepool {
   NSMutableData*data=[NSMutableData dataWithLength:(size_t)channels*tile*tile*sizeof(float)];float*input=(float*)data.mutableBytes;double sum=0;
   for(int y=0;y<tile;y++)for(int x=0;x<tile;x++){
     int sx=mirror(tx+x-pad,W),sy=mirror(ty+y-pad,H);
     for(int c=0;c<channels;c++){
       float v;if(raw){int rx=cx+sx*2+c%2,ry=cy+sy*2+c/2;auto&s=reader->imgdata.sizes;unsigned short*row=(unsigned short*)((uint8_t*)reader->imgdata.rawdata.raw_image+(size_t)ry*s.raw_pitch);v=(row[rx]-blacks[c])/ranges[c]*wb[c];}
       else v=!rgb16.empty()?rgb16[((size_t)sy*width+sx)*4+c]/65535.f:original[((size_t)sy*width+sx)*4+c]/255.f;
       input[((size_t)c*tile+y)*tile+x]=v;sum+=v;
     }
   }
   if(strength==0 && raw){
     if(raw)for(int y=0;y<std::min(core,H-ty);y++)for(int x=0;x<std::min(core,W-tx);x++)for(int p=0;p<4;p++){
       double v=input[((size_t)p*tile+y+pad)*tile+x+pad]/wb[p];output[((size_t)(ty+y)*2+p/2)*width+(tx+x)*2+p%2]=(uint16_t)std::llround(std::clamp(v,0.,1.)*65535);
     }
     progress((double)++done/total);continue;
   }
   ORTValue*value=[[ORTValue alloc] initWithTensorData:data elementType:ORTTensorElementDataTypeFloat shape:@[@1,@(channels),@(tile),@(tile)] error:error];if(!value){CGColorSpaceRelease(color);return nil;}
   NSDictionary*values=[session runWithInputs:@{inName:value} outputNames:[NSSet setWithObject:outName] runOptions:nil error:error];if(!values){CGColorSpaceRelease(color);return nil;}
   NSMutableData*result=[values[outName] tensorDataWithError:error];int outTile=localLinear?core:(raw?tile*2:tile);
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
       float src=input[((size_t)c*tile+y+pad)*tile+x+pad];float den=localLinear?pred[((size_t)c*core+y)*core+x]:pred[((size_t)c*tile+y+pad)*tile+x+pad];
       float blended=std::clamp(src+(den-src)*strength,0.f,1.f);if(linear){double v=localLinear?blended:(blended<=0.04045?blended/12.92:std::pow((blended+0.055)/1.055,2.4));output[((size_t)(ty+y)*width+tx+x)*3+c]=(uint16_t)std::llround(v*65535);}else rgba[((size_t)(ty+y)*width+tx+x)*4+c]=(uint8_t)std::lround(std::clamp(src+(den-src)*strength,0.f,1.f)*255);
     }
   }
   progress((double)++done/total);
 }}
 if(self.cancelled){CGColorSpaceRelease(color);if(error)*error=failure(@"已取消");return nil;}
 if(preview){
 int channelsOut=raw?1:3;
 if(raw||linear){std::vector<uint16_t> cropped((size_t)roiW*roiH*channelsOut);for(int y=0;y<roiH;y++)std::copy_n(output.data()+((size_t)(roiY+y)*width+roiX)*channelsOut,(size_t)roiW*channelsOut,cropped.data()+(size_t)y*roiW*channelsOut);output.swap(cropped);}
 else {std::vector<uint8_t> cropped((size_t)roiW*roiH*4);for(int y=0;y<roiH;y++)std::copy_n(rgba.data()+((size_t)(roiY+y)*width+roiX)*4,(size_t)roiW*4,cropped.data()+(size_t)y*roiW*4);rgba.swap(cropped);}
 width=roiW;height=roiH;
 }
 BOOL ok=NO;
 if(raw){auto&c=reader->imgdata.color;double matrix[9],neutral[3];for(int i=0;i<9;i++)matrix[i]=c.cam_xyz[i/3][i%3];double g=c.cam_mul[1]>0?c.cam_mul[1]:1;for(int i=0;i<3;i++)neutral[i]=c.cam_mul[i]>0?g/c.cam_mul[i]:1;
   int flip=reader->imgdata.sizes.flip,orientation=flip==3?3:(flip==5?8:(flip==6?6:1));
   dng::Metadata meta;meta.lens=reader->imgdata.lens.Lens;meta.focal=reader->imgdata.other.focal_len;meta.aperture=reader->imgdata.other.aperture;meta.exposure=reader->imgdata.other.shutter;meta.iso=reader->imgdata.other.iso_speed;
   ok=dng::write(staging.fileSystemRepresentation,output,width,height,reader->imgdata.idata.make,reader->imgdata.idata.model,matrix,neutral,orientation,meta);
 }else if(linear){double matrix[9]={3.2404542,-1.5371385,-0.4985314,-0.9692660,1.8760108,0.0415560,0.0556434,-0.2040259,1.0572252},neutral[3]={1,1,1};ok=dng::write(staging.fileSystemRepresentation,output,width,height,"JingYing","Linear sRGB",matrix,neutral,1,dng::Metadata(),true);
 }else{
   CGContextRef bitmap=CGBitmapContextCreate(rgba.data(),width,height,8,width*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrderDefault);CGImageRef im=bitmap?CGBitmapContextCreateImage(bitmap):nil;
   if(im){
     NSMutableDictionary*properties=[NSMutableDictionary dictionaryWithDictionary:@{(__bridge NSString*)kCGImageDestinationLossyCompressionQuality:@0.97,(__bridge NSString*)kCGImagePropertyOrientation:@1}];
     CGImageSourceRef inputSource=CGImageSourceCreateWithURL((__bridge CFURLRef)source,nil);
     if(inputSource){NSDictionary*sourceProperties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(inputSource,0,nil));NSMutableDictionary*exif=[sourceProperties[(__bridge NSString*)kCGImagePropertyExifDictionary] mutableCopy];if(exif){exif[(__bridge NSString*)kCGImagePropertyExifPixelXDimension]=@(width);exif[(__bridge NSString*)kCGImagePropertyExifPixelYDimension]=@(height);properties[(__bridge NSString*)kCGImagePropertyExifDictionary]=exif;}CFRelease(inputSource);}
     CGImageDestinationRef dst=CGImageDestinationCreateWithURL((__bridge CFURLRef)staging,(__bridge CFStringRef)UTTypeJPEG.identifier,1,nil);
     if(dst){CGImageDestinationAddImage(dst,im,(__bridge CFDictionaryRef)properties);ok=CGImageDestinationFinalize(dst);CFRelease(dst);}CGImageRelease(im);
   }if(bitmap)CGContextRelease(bitmap);
 }
 CGColorSpaceRelease(color);
 if(!ok||self.cancelled){[[NSFileManager defaultManager] removeItemAtURL:staging error:nil];if(error)*error=failure(self.cancelled?@"已取消":@"写入失败，请检查存储空间。");return nil;}
 if(![[NSFileManager defaultManager] moveItemAtURL:staging toURL:destination error:error]){[[NSFileManager defaultManager] removeItemAtURL:staging error:nil];return nil;}return destination;
}
@end
