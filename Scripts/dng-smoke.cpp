#include "../App/DNGWriter.hpp"
int main(int argc,char**argv){
 if(argc!=2)return 1;
 double m[9]={.8161,-.2947,-.0739,-.4811,1.2668,.2389,-.0437,.1229,.6524};
 double n[3]={1024./1871,1,1024./2244};
 std::vector<uint16_t> p(64*64,8192);
 dng::Metadata meta;meta.lens="FE 70-200mm F2.8 GM OSS II";meta.focal=111;meta.aperture=2.8;meta.exposure=.005;meta.iso=8000;
 return dng::write(argv[1],p,64,64,"SONY","ILCE-1M2",m,n,1,meta)?0:2;
}
