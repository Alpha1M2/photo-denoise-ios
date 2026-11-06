// Uncompressed Bayer or linear RGB DNG writer. Values are scaled to 16-bit.
// No raw sensor geometry warping. Raw camera-space color and as-shot white balance retained.
#pragma once
#include <vector>
#include <string>
#include <fstream>
#include <algorithm>
#include <cstring>
#include <cmath>
#include <cstdint>
namespace dng {
struct Tag { uint16_t id,type; uint32_t count; std::vector<uint8_t> data; };
inline void u16(std::vector<uint8_t>&b,uint16_t x){b.push_back(x&255);b.push_back(x>>8);}
inline void u32(std::vector<uint8_t>&b,uint32_t x){for(int i=0;i<4;i++)b.push_back((x>>(8*i))&255);}
inline Tag nums(int id,int type,std::vector<uint32_t> v){Tag t{(uint16_t)id,(uint16_t)type,(uint32_t)v.size(),{}};for(auto x:v){if(type==3)u16(t.data,x);else if(type==1)t.data.push_back(x);else u32(t.data,x);}return t;}
inline Tag str(int id,std::string s){s.push_back(0);return Tag{(uint16_t)id,2,(uint32_t)s.size(),{s.begin(),s.end()}};}
inline Tag rational(int id,std::vector<double> values,bool sign=false){Tag t{(uint16_t)id,(uint16_t)(sign?10:5),(uint32_t)values.size(),{}};for(double x:values){u32(t.data,(uint32_t)(int32_t)std::llround(x*1000000));u32(t.data,1000000);}return t;}
struct Metadata { std::string lens;double focal=0,aperture=0,exposure=0;uint32_t iso=0; };
inline std::vector<uint8_t> ifd(std::vector<Tag> ts,uint32_t base){
 std::sort(ts.begin(),ts.end(),[](auto&a,auto&b){return a.id<b.id;});
 std::vector<uint8_t>b,extra;u16(b,ts.size());uint32_t dataStart=base+2+(uint32_t)ts.size()*12+4;
 for(auto&t:ts){u16(b,t.id);u16(b,t.type);u32(b,t.count);
  if(t.data.size()<=4){b.insert(b.end(),t.data.begin(),t.data.end());for(size_t j=t.data.size();j<4;j++)b.push_back(0);}
  else{while((dataStart+extra.size())%4)extra.push_back(0);u32(b,dataStart+extra.size());extra.insert(extra.end(),t.data.begin(),t.data.end());}}
 u32(b,0);b.insert(b.end(),extra.begin(),extra.end());while((base+b.size())%4)b.push_back(0);return b;
}
inline bool write(const char*path,const std::vector<uint16_t>&pixels,int w,int h,
 const std::string&make,const std::string&model,const double*matrix,const double*neutral,int orientation,const Metadata&meta=Metadata(),bool linear=false){
 std::vector<Tag> ts={nums(254,4,{0}),nums(256,4,{(uint32_t)w}),nums(257,4,{(uint32_t)h}),nums(258,3,{16}),nums(259,3,{1}),nums(262,3,{32803}),str(271,make),str(272,model),nums(273,4,{0}),nums(274,3,{(uint32_t)orientation}),nums(277,3,{1}),nums(278,4,{(uint32_t)h}),nums(279,4,{(uint32_t)pixels.size()*2}),nums(284,3,{1}),str(305,"JingYing 0.4"),nums(33421,3,{2,2}),nums(33422,1,{0,1,1,2}),nums(50706,1,{1,4,0,0}),nums(50707,1,{1,3,0,0}),str(50708,make+" "+model),nums(50710,1,{0,1,2}),nums(50711,3,{1}),nums(50713,3,{1,1}),rational(50714,{0}),nums(50717,4,{65535}),rational(50718,{1,1}),nums(50719,4,{0,0}),nums(50720,4,{(uint32_t)w,(uint32_t)h}),rational(50721,std::vector<double>(matrix,matrix+9),true),rational(50728,std::vector<double>(neutral,neutral+3)),nums(50778,3,{21})};
 if(linear){
  ts.erase(std::remove_if(ts.begin(),ts.end(),[](const Tag&t){return t.id==33421||t.id==33422||t.id==50710||t.id==50711;}),ts.end());
  for(auto&t:ts){if(t.id==262)t=nums(262,3,{34892});if(t.id==258)t=nums(258,3,{16,16,16});if(t.id==277)t=nums(277,3,{3});}
 }
 std::vector<Tag> exif;
 if(!meta.lens.empty())exif.push_back(str(42036,meta.lens));
 if(meta.focal>0)exif.push_back(rational(37386,{meta.focal}));
 if(meta.aperture>0)exif.push_back(rational(33437,{meta.aperture}));
 if(meta.exposure>0)exif.push_back(rational(33434,{meta.exposure}));
 if(meta.iso>0)exif.push_back(nums(34855,3,{std::min(meta.iso,65535u)}));
 if(!exif.empty())ts.push_back(nums(34665,4,{0}));
 auto root=ifd(ts,8);auto child=exif.empty()?std::vector<uint8_t>():ifd(exif,8+root.size());
 uint32_t pixelOffset=8+root.size()+child.size();
 for(auto&t:ts){if(t.id==273)t=nums(273,4,{pixelOffset});if(t.id==34665)t=nums(34665,4,{(uint32_t)(8+root.size())});}
 root=ifd(ts,8);const char head[8]={'I','I',42,0,8,0,0,0};std::ofstream f(path,std::ios::binary);
 f.write(head,8);f.write((char*)root.data(),root.size());f.write((char*)child.data(),child.size());f.write((char*)pixels.data(),pixels.size()*2);return f.good();
}
}
