// Small uncompressed Bayer DNG writer. Values are black-subtracted, scaled to 16-bit.
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
inline bool write(const char*path,const std::vector<uint16_t>&pixels,int w,int h,
 const std::string&make,const std::string&model,const double*matrix,const double*neutral,int orientation){
 std::vector<Tag> ts={nums(254,4,{0}),nums(256,4,{(uint32_t)w}),nums(257,4,{(uint32_t)h}),nums(258,3,{16}),nums(259,3,{1}),nums(262,3,{32803}),str(271,make),str(272,model),nums(273,4,{0}),nums(274,3,{(uint32_t)orientation}),nums(277,3,{1}),nums(278,4,{(uint32_t)h}),nums(279,4,{(uint32_t)pixels.size()*2}),nums(284,3,{1}),str(305,"JingYing 0.1 / RawNIND"),nums(33421,3,{2,2}),nums(33422,1,{0,1,1,2}),nums(50706,1,{1,4,0,0}),nums(50707,1,{1,3,0,0}),str(50708,make+" "+model),nums(50710,1,{0,1,2}),nums(50711,3,{1}),nums(50713,3,{1,1}),rational(50714,{0}),nums(50717,4,{65535}),rational(50718,{1,1}),nums(50719,4,{0,0}),nums(50720,4,{(uint32_t)w,(uint32_t)h}),rational(50721,std::vector<double>(matrix,matrix+9),true),rational(50728,std::vector<double>(neutral,neutral+3)),nums(50778,3,{21})};
 std::sort(ts.begin(),ts.end(),[](auto&a,auto&b){return a.id<b.id;});
 uint32_t offset=8+2+(uint32_t)ts.size()*12+4;std::vector<uint8_t> extra;
 for(auto&t:ts)if(t.data.size()>4){while((offset+extra.size())%4)extra.push_back(0);extra.insert(extra.end(),t.data.begin(),t.data.end());}
 uint32_t pixoff=offset+(uint32_t)extra.size();if(pixoff%2){extra.push_back(0);pixoff++;}
 std::vector<uint8_t> head={'I','I',42,0,8,0,0,0};u16(head,ts.size());uint32_t eo=offset;
 for(auto&t:ts){u16(head,t.id);u16(head,t.type);u32(head,t.count);if(t.id==273){u32(head,pixoff);}else if(t.data.size()<=4){head.insert(head.end(),t.data.begin(),t.data.end());for(size_t j=t.data.size();j<4;j++)head.push_back(0);}else{while(eo%4)eo++;u32(head,eo);eo+=(uint32_t)t.data.size();}}
 u32(head,0);std::ofstream f(path,std::ios::binary);f.write((char*)head.data(),head.size());f.write((char*)extra.data(),extra.size());f.write((char*)pixels.data(),pixels.size()*2);return f.good();
}
}
