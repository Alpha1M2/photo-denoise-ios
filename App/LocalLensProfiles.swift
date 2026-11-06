import Foundation
import CoreImage

// User-supplied LCP data is installed locally, never distributed by public CI.
enum LocalLensProfiles {
    struct Record:Decodable {
        let focal:Double, distance:Double, av:Double
        let distortion:[String:Double]?, fisheye:[String:Double]?, vignette:[String:Double]?
        let red:[String:Double]?,green:[String:Double]?,blue:[String:Double]?
        let piecewise:[[Double]]?
    }
    struct Profile:Decodable {let name:String,camera:String;let raw:Bool;let crop:Double;let records:[Record]}
    struct Catalog:Decodable {let schema:Int;let profiles:[Profile]}
    static let catalog:Catalog? = {
        guard let url=Bundle.main.url(forResource:"local-sony-lcp",withExtension:"json"),let data=try? Data(contentsOf:url),let result=try? JSONDecoder().decode(Catalog.self,from:data),result.schema==1 else{return nil}
        return result
    }()
    static func normalized(_ name:String)->String {
        var s=name.uppercased().replacingOccurrences(of:"F/",with:"F").replacingOccurrences(of:"–",with:"-")
        if s.hasPrefix("SONY "){s=String(s.dropFirst(5))}
        return s.filter{!$0.isWhitespace}
    }
    static func profile(_ meta:LensRenderer.Metadata)->Profile? {
        guard !meta.lens.isEmpty,meta.focal>0,meta.isRaw else{return nil}
        let matches=catalog?.profiles.filter{$0.raw && normalized($0.name)==normalized(meta.lens) && $0.records.contains{$0.distortion != nil || $0.fisheye != nil}} ?? []
        if matches.count==1{return matches[0]}
        return matches.first{!$0.camera.isEmpty && $0.camera==meta.camera}
    }
    static func blend(_ a:[String:Double],_ b:[String:Double],_ t:Double)->[String:Double] {
        Dictionary(uniqueKeysWithValues:Set(a.keys).union(b.keys).map{key in
            let fallback:Double = key=="ScaleFactor" ? 1 : (key=="ImageXCenter" || key=="ImageYCenter" ? 0.5 : 0)
            return (key,(a[key] ?? fallback)*(1-t)+(b[key] ?? fallback)*t)
        })
    }
    static func bracket(_ values:[Double],_ x:Double)->(Double,Double,Double) {
        let v=Array(Set(values)).sorted();guard let first=v.first,let last=v.last else{return (0,0,0)}
        if x<=first{return(first,first,0)};if x>=last{return(last,last,0)}
        for i in 1..<v.count where x<=v[i] {return(v[i-1],v[i],(x-v[i-1])/(v[i]-v[i-1]))}
        return(last,last,0)
    }
    static func parameters(_ profile:Profile,_ meta:LensRenderer.Metadata,vignette:Bool=false,channel:String?=nil)->[String:Double]? {
        func selected(_ r:Record)->[String:Double]? {
            if let channel {return channel=="red" ? r.red : (channel=="blue" ? r.blue:r.green)}
            return vignette ? r.vignette : (r.distortion ?? r.fisheye)
        }
        let rows=profile.records.filter{selected($0) != nil}
        guard !rows.isEmpty else{return nil}
        func value(_ row:Record)->[String:Double] {selected(row)!}
        func atFocal(_ f:Double)->[String:Double] {
            let group=rows.filter{abs(log($0.focal)-f)<0.00001}
            // Unknown focus uses the farthest calibration; no invented close-focus distance.
            let focus=meta.distance>0 ? log(max(0.001,meta.distance)) : log(max(0.001,group.map{$0.distance}.max() ?? 10000))
            let (lo,hi,t)=bracket(group.map{log(max(0.001,$0.distance))},focus)
            func atDistance(_ d:Double)->[String:Double] {
                let choices=group.filter{abs(log(max(0.001,$0.distance))-d)<0.00001}
                if !vignette {return value(choices.min{($0.distortion?["ResidualMeanError"] ?? 0)<($1.distortion?["ResidualMeanError"] ?? 0)}!)}
                let av=meta.aperture>0 ? 2*log2(meta.aperture) : choices.map{$0.av}.min()!
                let (a,b,u)=bracket(choices.map{$0.av},av)
                return blend(value(choices.first{$0.av==a}!),value(choices.first{$0.av==b}!),u)
            }
            return blend(atDistance(lo),atDistance(hi),t)
        }
        let (lo,hi,t)=bracket(rows.map{log($0.focal)},log(meta.focal))
        return blend(atFocal(lo),atFocal(hi),t)
    }
    struct Mapping {
        let center:CGPoint, focal:CGSize, k:[Double], fish:Bool
        func point(_ p:CGPoint)->CGPoint {
            let x=(p.x-center.x)/focal.width,y=(p.y-center.y)/focal.height,r2=x*x+y*y
            if fish {
                let radius=hypot(p.x-center.x,p.y-center.y),f=sqrt(focal.width*focal.height)
                if radius<0.000001{return center}
                let a=atan2(radius,f),t=a*a,q=(1+k[0]*t+k[1]*t*t)*a/radius
                return CGPoint(x:center.x+q*focal.width*(p.x-center.x),y:center.y+q*focal.height*(p.y-center.y))
            }
            let q=1+r2*(k[0]+r2*(k[1]+r2*k[2]))
            return CGPoint(x:center.x+x*q*focal.width,y:center.y+y*q*focal.height)
        }
    }
    static func mapping(_ values:[String:Double],_ meta:LensRenderer.Metadata,_ profile:Profile,_ size:CGSize,fish:Bool=false)->Mapping {
        let d=max(size.width,size.height),defaultF=(meta.focal35>0 ? meta.focal35 : meta.focal*profile.crop)/35
        var x=values["ImageXCenter"] ?? 0.5,y=values["ImageYCenter"] ?? 0.5
        var fx=values["FocalLengthX"] ?? defaultF,fy=values["FocalLengthY"] ?? defaultF
        switch meta.orientation {
        case 3:x=1-x;y=1-y
        case 6:(x,y)=(1-y,x);swap(&fx,&fy)
        case 8:(x,y)=(y,1-x);swap(&fx,&fy)
        default:break
        }
        return Mapping(center:CGPoint(x:x*size.width,y:(1-y)*size.height),focal:CGSize(width:fx*d,height:fy*d),k:(1...3).map{values["RadialDistortParam\($0)"] ?? 0},fish:fish)
    }
    static func cropScale(_ m:Mapping,_ size:CGSize)->Double {
        func safe(_ z:Double)->Bool {
            for i in 0...128 {
                let t=Double(i)/128
                for p in [CGPoint(x:t*size.width,y:0),CGPoint(x:t*size.width,y:size.height),CGPoint(x:0,y:t*size.height),CGPoint(x:size.width,y:t*size.height)] {
                    let q=m.point(CGPoint(x:size.width/2+(p.x-size.width/2)*z,y:size.height/2+(p.y-size.height/2)*z))
                    if !q.x.isFinite || !q.y.isFinite || q.x<1 || q.y<1 || q.x>size.width-1 || q.y>size.height-1{return false}
                }
            };return true
        }
        if safe(1){return 1};var lo=0.1,hi=1.0
        for _ in 0..<24 {let mid=(lo+hi)/2;if safe(mid){lo=mid}else{hi=mid}}
        return lo*0.999
    }
    static let kernel=CIKernel(source:"""
    kernel vec4 localLens(sampler src,vec2 size,vec2 c,vec2 f,vec3 k,float fish,float zoom,vec2 vc,vec2 vf,vec3 vk,float vig) {
        vec2 p=(destCoord()-size*0.5)*zoom+size*0.5;
        vec2 n=(p-c)/f;float r2=dot(n,n);vec2 q;
        if(fish>0.5){float r=length(p-c);float a=atan(r/sqrt(f.x*f.y));float t=a*a;q=c+(p-c)*f*((1.0+k.x*t+k.y*t*t)*a/max(r,0.000001));}
        else {q=c+n*f*(1.0+r2*(k.x+r2*(k.y+r2*k.z)));}
        vec4 color=sample(src,samplerTransform(src,q));
        vec2 vn=(q-vc)/vf;float vr=dot(vn,vn);
        float falloff=1.0+vr*(vk.x+vr*(vk.y+vr*vk.z));
        return vec4(color.rgb/mix(1.0,max(0.125,falloff),vig),color.a);
    }
    """)
    static let caKernel=CIKernel(source:"""
    kernel vec4 localCA(sampler src,vec2 gc,vec2 gf,vec2 rc,vec2 rf,vec3 rk,float rs,vec2 bc,vec2 bf,vec3 bk,float bs) {
        vec2 n=(destCoord()-gc)/gf;float r2=dot(n,n);
        vec2 pr=rc+n*rf*rs*(1.0+r2*(rk.x+r2*(rk.y+r2*rk.z)));
        vec2 pb=bc+n*bf*bs*(1.0+r2*(bk.x+r2*(bk.y+r2*bk.z)));
        vec4 g=sample(src,samplerTransform(src,destCoord()));
        return vec4(sample(src,samplerTransform(src,pr)).r,g.g,sample(src,samplerTransform(src,pb)).b,g.a);
    }
    """)
    static func applyCA(_ image:CIImage,meta:LensRenderer.Metadata,profile:Profile)throws->CIImage {
        guard let g=parameters(profile,meta,channel:"green"),let r=parameters(profile,meta,channel:"red"),let b=parameters(profile,meta,channel:"blue"),let caKernel else{throw LensRenderer.error("没有可用的色差校正参数")}
        let size=image.extent.size,gm=mapping(g,meta,profile,size),rm=mapping(r,meta,profile,size),bm=mapping(b,meta,profile,size)
        func pair(_ m:Mapping)->[Any] {[CIVector(cgPoint:m.center),CIVector(x:m.focal.width,y:m.focal.height)]}
        var args:[Any]=[image]
        args.append(contentsOf:pair(gm));args.append(contentsOf:pair(rm))
        args.append(CIVector(x:rm.k[0],y:rm.k[1],z:rm.k[2]));args.append(r["ScaleFactor"] ?? 1)
        args.append(contentsOf:pair(bm))
        args.append(CIVector(x:bm.k[0],y:bm.k[1],z:bm.k[2]));args.append(b["ScaleFactor"] ?? 1)
        guard let out=caKernel.apply(extent:image.extent,roiCallback:{_,_ in image.extent},arguments:args) else{throw LensRenderer.error("色差校正失败")};return out
    }
    static func apply(_ image:CIImage,meta:LensRenderer.Metadata,profile:Profile,options:LensRenderer.Options=LensRenderer.Options(distortion:true,vignetting:true,chromatic:false))throws->CIImage {
        guard let values=parameters(profile,meta),let kernel else{throw LensRenderer.error("本地镜头配置无法使用")}
        let rect=image.extent,size=rect.size
        var base=image.transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY))
        if options.chromatic {base=try applyCA(base,meta:meta,profile:profile)}
        let m=mapping(options.distortion ? values:[:],meta,profile,size,fish:options.distortion && profile.records.contains{$0.fisheye != nil})
        let v=options.vignetting ? parameters(profile,meta,vignette:true):nil,vm=mapping(v ?? [:],meta,profile,size)
        let z=options.chromatic ? min(0.99,cropScale(m,size)) : (options.distortion ? cropScale(m,size):1)
        guard z>0.15 else{throw LensRenderer.error("镜头校正参数超出可用范围")}
        let args:[Any]=[base,CIVector(x:size.width,y:size.height),CIVector(cgPoint:m.center),CIVector(x:m.focal.width,y:m.focal.height),CIVector(x:m.k[0],y:m.k[1],z:m.k[2]),m.fish ? 1.0:0.0,z,CIVector(cgPoint:vm.center),CIVector(x:vm.focal.width,y:vm.focal.height),CIVector(x:v?["VignetteModelParam1"] ?? 0,y:v?["VignetteModelParam2"] ?? 0,z:v?["VignetteModelParam3"] ?? 0),v == nil ? 0.0:1.0]
        guard let result=kernel.apply(extent:CGRect(origin:.zero,size:size),roiCallback:{_,_ in base.extent},arguments:args) else{throw LensRenderer.error("本地镜头校正失败")}
        return result
    }
    static func selfTest()->String {
        do {
            let fixture=Data(#"{"name":"TEST","camera":"","raw":true,"crop":1,"records":[{"focal":35,"distance":10000,"av":4,"distortion":{"RadialDistortParam1":-0.12,"RadialDistortParam2":0.01}}]}"#.utf8)
            let profile=try JSONDecoder().decode(Profile.self,from:fixture)
            var meta=LensRenderer.Metadata(URL(fileURLWithPath:"/nonexistent"));meta.lens="TEST";meta.focal=35;meta.aperture=4;meta.isRaw=true
            let w=300,h=200;var pixels=[Float](repeating:0,count:w*h*4)
            for y in 0..<h {for x in 0..<w {let i=(y*w+x)*4;pixels[i]=Float(x)/Float(w);pixels[i+1]=Float(y)/Float(h);pixels[i+2]=0.5;pixels[i+3]=1}}
            let data=pixels.withUnsafeBytes{Data($0)},space=CGColorSpace(name:CGColorSpace.linearSRGB)!
            let image=CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:space)
            let output=try apply(image,meta:meta,profile:profile)
            let m=mapping(parameters(profile,meta)!,meta,profile,image.extent.size),z=cropScale(m,image.extent.size)
            let point=CGPoint(x:40.5,y:50.5),q=m.point(CGPoint(x:150+(point.x-150)*z,y:100+(point.y-100)*z))
            var actual=[Float](repeating:0,count:4)
            var expected=[Float](repeating:0,count:4);let context=CIContext()
            actual.withUnsafeMutableBytes{context.render(output,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:40,y:50,width:1,height:1),format:.RGBAf,colorSpace:space)}
            expected.withUnsafeMutableBytes{context.render(image,toBitmap:$0.baseAddress!,rowBytes:16,bounds:CGRect(x:q.x-0.5,y:q.y-0.5,width:1,height:1),format:.RGBAf,colorSpace:space)}
            let delta=max(abs(Double(actual[0]-expected[0])),abs(Double(actual[1]-expected[1])))
            return delta<0.02 && actual[3]>0.99 ? "PASS: LCP remap delta=\(delta)" : "FAIL: LCP remap delta=\(delta) rgba=\(actual)"
        } catch{return "FAIL: \(error.localizedDescription)"}
    }
}
