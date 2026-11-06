import Foundation
import CoreImage

// Sony ARW SubIFD tags; radial formula cross-checked with RawTherapee lensmetadata.cc.
struct SonyCorrections {
    var distortion:[Double]?,red:[Double]?,blue:[Double]?,vignette:[Double]?
    init?(_ url:URL) {
        guard let handle=try? FileHandle(forReadingFrom:url) else{return nil};defer{try? handle.close()}
        guard let size=try? handle.seekToEnd(),size>=8 else{return nil}
        func read(_ offset:UInt64,_ length:Int)->Data? {
            guard length>=0,length<=65536,offset<=size,UInt64(length)<=size-offset else{return nil}
            do {try handle.seek(toOffset:offset);let data=try handle.read(upToCount:length);return data?.count==length ? data:nil}catch{return nil}
        }
        guard let header=read(0,8),Array(header.prefix(2))==[73,73] || Array(header.prefix(2))==[77,77] else{return nil}
        let little=header[0]==73
        func integer(_ d:Data,_ i:Int,_ n:Int)->UInt32 {
            var value:UInt32=0
            for k in 0..<n {value |= UInt32(d[i+k]) << (8*(little ? k:n-1-k))};return value
        }
        guard integer(header,2,2)==42 else{return nil}
        var visited=Set<UInt32>(),tags=[UInt32:[Double]]()
        func walk(_ offset:UInt32) {
            guard offset>0,visited.count<64,!visited.contains(offset),let countData=read(UInt64(offset),2) else{return}
            visited.insert(offset);let count=Int(integer(countData,0,2));guard count<=4096,let entries=read(UInt64(offset)+2,count*12+4) else{return}
            for i in 0..<count {
                let a=i*12,tag=integer(entries,a,2),type=integer(entries,a+2,2),n=Int(integer(entries,a+4,4)),ptr=integer(entries,a+8,4)
                if [0x7032,0x7035,0x7037].contains(tag),type==8,n>=2,n<=33,let data=read(UInt64(ptr),n*2) {
                    tags[tag]=(0..<n).map{Double(Int16(bitPattern:UInt16(integer(data,$0*2,2))))}
                }
                if [330,34665].contains(tag),type==4,n>0,n<=16 {
                    if n==1 {walk(ptr)}
                    else if let data=read(UInt64(ptr),n*4){for j in 0..<n {walk(integer(data,j*4,4))}}
                }
            };walk(integer(entries,count*12,4))
        }
        walk(integer(header,4,4))
        func values(_ tag:UInt32)->[Double]? {
            guard let data=tags[tag],let first=data.first,first>=2,first<=32,Int(first)==data.count-1 else{return nil};return Array(data.dropFirst())
        }
        if let d=values(0x7037),d.count<=16 {distortion=d.map{1+$0/16384}}
        if let c=values(0x7035),c.count%2==0 {let n=c.count/2;red=c.prefix(n).map{1+$0/2097152};blue=c.suffix(n).map{1+$0/2097152}}
        if let v=values(0x7032),v.count<=16 {vignette=v.map{min(16,pow(2,pow(2,$0/8192-1)-0.5))}}
        guard distortion != nil || red != nil || vignette != nil else{return nil}
    }
    static func sample(_ values:[Double]?,_ radius:Double)->Double {
        guard let values,values.count>=2 else{return 1}
        let x=max(0,min(Double(values.count-1),radius*Double(values.count-1)-0.5)),i=Int(floor(x)),j=min(i+1,values.count-1)
        return values[i]+(values[j]-values[i])*(x-Double(i))
    }
    static let kernel=CIKernel(source:"""
    float sonyCurve(float r,float n,vec4 a,vec4 b,vec4 c,vec4 d) {
        float x=clamp(r*(n-1.0)-0.5,0.0,n-1.0);
        return dot(a,max(vec4(0.0),vec4(1.0)-abs(vec4(x)-vec4(0.0,1.0,2.0,3.0))))
             + dot(b,max(vec4(0.0),vec4(1.0)-abs(vec4(x)-vec4(4.0,5.0,6.0,7.0))))
             + dot(c,max(vec4(0.0),vec4(1.0)-abs(vec4(x)-vec4(8.0,9.0,10.0,11.0))))
             + dot(d,max(vec4(0.0),vec4(1.0)-abs(vec4(x)-vec4(12.0,13.0,14.0,15.0))));
    }
    kernel vec4 sonyLens(sampler src,vec2 size,float zoom,vec3 flags,vec4 counts,
        vec4 d0,vec4 d1,vec4 d2,vec4 d3,vec4 r0,vec4 r1,vec4 r2,vec4 r3,
        vec4 b0,vec4 b1,vec4 b2,vec4 b3,vec4 v0,vec4 v1,vec4 v2,vec4 v3) {
        vec2 c=size*0.5;vec2 p=(destCoord()-c)*zoom;float r=length(p)/length(c);
        float d=mix(1.0,sonyCurve(r,counts.x,d0,d1,d2,d3),flags.x);
        float cr=mix(1.0,sonyCurve(r,counts.y,r0,r1,r2,r3),flags.y);
        float cb=mix(1.0,sonyCurve(r,counts.z,b0,b1,b2,b3),flags.y);
        vec4 g=sample(src,samplerTransform(src,c+p*d));
        float rr=sample(src,samplerTransform(src,c+p*d*cr)).r;
        float bb=sample(src,samplerTransform(src,c+p*d*cb)).b;
        float gain=sonyCurve(r*d,counts.w,v0,v1,v2,v3);
        return vec4(vec3(rr,g.g,bb)*mix(1.0,gain,flags.z),g.a);
    }
    """)
    func apply(_ image:CIImage,options:LensRenderer.Options)throws->CIImage {
        guard let kernel=Self.kernel else{throw LensRenderer.error("索尼校正内核不可用")}
        let size=image.extent.size,center=CGPoint(x:size.width/2,y:size.height/2),diag=hypot(center.x,center.y)
        func safe(_ z:Double)->Bool {
            for i in 0...128 {
                let t=Double(i)/128
                for p in [CGPoint(x:t*size.width,y:0),CGPoint(x:t*size.width,y:size.height),CGPoint(x:0,y:t*size.height),CGPoint(x:size.width,y:t*size.height)] {
                    let x=(p.x-center.x)*z,y=(p.y-center.y)*z,r=hypot(x,y)/diag,d=options.distortion ? Self.sample(distortion,r):1
                    for factor in [1,options.chromatic ? Self.sample(red,r):1,options.chromatic ? Self.sample(blue,r):1] {
                        let xx=center.x+x*d*factor,yy=center.y+y*d*factor
                        if !xx.isFinite || !yy.isFinite || xx<1 || yy<1 || xx>size.width-1 || yy>size.height-1{return false}
                    }
                }
            };return true
        }
        var zoom=1.0
        if options.distortion || options.chromatic {var low=0.1,high=1.0;for _ in 0..<24 {let mid=(low+high)/2;if safe(mid){low=mid}else{high=mid}};zoom=low*0.999}
        let curves=[distortion,red,blue,vignette].map{$0 ?? Array(repeating:1.0,count:16)}
        let base=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        var args:[Any]=[base,CIVector(x:size.width,y:size.height),zoom,CIVector(x:options.distortion ? 1:0,y:options.chromatic ? 1:0,z:options.vignetting ? 1:0),CIVector(x:Double(curves[0].count),y:Double(curves[1].count),z:Double(curves[2].count),w:Double(curves[3].count))]
        for curve in curves {
            let values=curve+Array(repeating:curve.last ?? 1,count:16-curve.count)
            for i in stride(from:0,to:16,by:4){args.append(CIVector(x:values[i],y:values[i+1],z:values[i+2],w:values[i+3]))}
        }
        guard let result=kernel.apply(extent:base.extent,roiCallback:{_,_ in base.extent},arguments:args) else{throw LensRenderer.error("索尼镜头校正失败")}
        return result
    }
    static func selfTest()->String {
        do {
            var data=Data([73,73,42,0,8,0,0,0])
            func append(_ value:UInt32,_ count:Int){for i in 0..<count{data.append(UInt8((value>>(i*8))&255))}}
            let arrays:[[Int16]]=[[16]+Array(repeating:1000,count:16),[32]+Array(repeating:20000,count:16)+Array(repeating:-20000,count:16),[16]+Array(repeating:100,count:16)]
            append(3,2);var offset=8+2+3*12+4
            for (i,tag) in [0x7032,0x7035,0x7037].enumerated(){append(UInt32(tag),2);append(8,2);append(UInt32(arrays[i].count),4);append(UInt32(offset),4);offset+=arrays[i].count*2};append(0,4)
            for array in arrays {for value in array {append(UInt32(UInt16(bitPattern:value)),2)}}
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".arw")
            try data.write(to:url);defer{try? FileManager.default.removeItem(at:url)}
            guard let correction=SonyCorrections(url),correction.red?.count==16,correction.distortion?.count==16 else{return "FAIL: Sony parser"}
            let w=300,h=200;var pixels=[Float](repeating:1,count:w*h*4)
            for y in 0..<h {for x in 0..<w {for c in 0..<3 {pixels[(y*w+x)*4+c]=Float(x)/Float(w)}}}
            let bitmap=pixels.withUnsafeBytes{Data($0)},space=CGColorSpace(name:CGColorSpace.linearSRGB)!,context=CIContext()
            let image=CIImage(bitmapData:bitmap,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:space)
            func pixel(_ image:CIImage)->[Float] {var result=[Float](repeating:0,count:4);result.withUnsafeMutableBytes{context.render(image,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:40,y:80,width:1,height:1),format:.RGBAf,colorSpace:space)};return result}
            let baseline=pixel(image),off=pixel(try correction.apply(image,options:LensRenderer.Options(distortion:false,vignetting:false,chromatic:false)))
            let ca=pixel(try correction.apply(image,options:LensRenderer.Options(distortion:false,vignetting:false,chromatic:true)))
            let vig=pixel(try correction.apply(image,options:LensRenderer.Options(distortion:false,vignetting:true,chromatic:false)))
            let dist=pixel(try correction.apply(image,options:LensRenderer.Options(distortion:true,vignetting:false,chromatic:false)))
            try data.prefix(20).write(to:url)
            let ok=SonyCorrections(url)==nil && abs(off[0]-baseline[0])<0.002 && abs(ca[0]-ca[2])>0.001 && vig[0]>off[0]+0.001 && abs(dist[0]-dist[1])<0.002
            return "\(ok ? "PASS":"FAIL"): Sony parser/switches off=\(off) ca=\(ca) vig=\(vig) dist=\(dist)"
        }catch{return "FAIL: \(error.localizedDescription)"}
    }
}
