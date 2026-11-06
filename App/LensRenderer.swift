import Foundation
import CoreImage
import ImageIO

enum LensRenderer {
    struct Metadata {
        var lens = "", focal = 0.0, aperture = 0.0
        init(_ url:URL) {
            if let src=CGImageSourceCreateWithURL(url as CFURL,nil),let p=CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String:Any],let e=p[kCGImagePropertyExifDictionary as String] as? [String:Any] {
                lens=e[kCGImagePropertyExifLensModel as String] as? String ?? ""
                focal=(e[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue ?? 0
                aperture=(e[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? 0
            }
        }
        var matches24105:Bool { lens.uppercased().contains("FE 24-105MM") && lens.uppercased().contains("G OSS") && focal>=24 && focal<=105 }
    }
    static func supports(_ url:URL)->Bool {
        if let raw=CIRAWFilter(imageURL:url), raw.isLensCorrectionSupported{return true}
        return Metadata(url).matches24105
    }
    private static func interpolate(_ rows:[[String:Double]],at x:Double,key:String)->[String:Double] {
        let sorted=rows.sorted{($0[key] ?? 0)<($1[key] ?? 0)}
        guard let first=sorted.first,let last=sorted.last else{return [:]}
        if x <= first[key]! {return first};if x>=last[key]! {return last}
        for i in 1..<sorted.count where x<=sorted[i][key]! {
            let a=sorted[i-1],b=sorted[i],t=(x-a[key]!)/(b[key]!-a[key]!)
            return Dictionary(uniqueKeysWithValues:Set(a.keys).union(b.keys).map{ k in (k,(a[k] ?? 0)*(1-t)+(b[k] ?? 0)*t) })
        }
        return last
    }
    // Lensfun ptlens/poly3/pa models; full-frame sensor, no pre-existing digital crop.
    // One remap handles distortion and transverse CA. Vignetting is corrected in linear light.
    private static let kernel = CIKernel(source:"""
    kernel vec4 lens24105(sampler src, vec2 centre, float scale, float diag, vec3 dist, vec4 ca, vec3 vig) {
        vec2 q=destCoord()-centre;
        float r=length(q)/scale;
        float f=dist.x*r*r*r+dist.y*r*r+dist.z*r+1.0-dist.x-dist.y-dist.z;
        vec2 p=q*f;float rd=length(p)/scale;
        vec2 pr=centre+p*(ca.x*rd*rd+ca.y);
        vec2 pb=centre+p*(ca.z*rd*rd+ca.w);
        vec4 g=sample(src,samplerTransform(src,centre+p));
        float red=sample(src,samplerTransform(src,pr)).r;
        float blue=sample(src,samplerTransform(src,pb)).b;
        float rv=length(p)/diag;float r2=rv*rv;
        float v=max(0.15,1.0+vig.x*r2+vig.y*r2*r2+vig.z*r2*r2*r2);
        return vec4(vec3(red,g.g,blue)/v,g.a);
    }
    """)
    static func renderCorrected(_ source:URL,to destination:URL,correct:Bool=true) throws {
        let result=try correctedImage(source,correct:correct)
        let context=CIContext(options:[.cacheIntermediates:false,.workingFormat:CIFormat.RGBAf.rawValue])
        try context.writeTIFFRepresentation(of:result,to:destination,format:.RGBA16,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,options:[:])
    }
    static func correctedImage(_ source:URL,correct:Bool=true) throws -> CIImage {
        let meta=Metadata(source)
        var image:CIImage?
        var systemCorrected=false
        if let raw=CIRAWFilter(imageURL:source) {
            raw.isLensCorrectionEnabled=correct && raw.isLensCorrectionSupported
            raw.baselineExposure=0;raw.exposure=0;raw.boostAmount=0;raw.boostShadowAmount=0;raw.localToneMapAmount=0;raw.contrastAmount=0;raw.detailAmount=0;raw.sharpnessAmount=0;raw.moireReductionAmount=0
            raw.luminanceNoiseReductionAmount=0
            raw.colorNoiseReductionAmount=0
            image=raw.outputImage
            systemCorrected=raw.isLensCorrectionSupported
        } else { image=CIImage(contentsOf:source,options:[.applyOrientationProperty:true]) }
        guard var result=image else{throw error("无法显影原片，不能应用镜头校正。")}
        if correct && !systemCorrected {
            guard meta.matches24105,meta.aperture>0,let path=Bundle.main.url(forResource:"sony24105",withExtension:"json"),let data=try JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any],let ds=data["distortion"] as? [[String:Double]],let cs=data["tca"] as? [[String:Double]],let vs=data["vignetting"] as? [[String:Double]],let kernel else{throw error("此镜头尚无可用的校正数据，未应用替代配置。")}
            let d=interpolate(ds,at:meta.focal,key:"focal"),c=interpolate(cs,at:meta.focal,key:"focal")
            let focals=Set(vs.compactMap{$0["focal"]}).sorted()
            let v=interpolate(focals.map{f -> [String:Double] in var row=interpolate(vs.filter{$0["focal"]==f},at:meta.aperture,key:"aperture");row["focal"]=f;return row},at:meta.focal,key:"focal")
            let rect=result.extent,w=rect.width,h=rect.height
            let args:[Any]=[result,CIVector(x:rect.midX,y:rect.midY),min(w,h)/2,hypot(w,h)/2,CIVector(x:d["a"] ?? 0,y:d["b"] ?? 0,z:d["c"] ?? 0),CIVector(x:c["br"] ?? 0,y:c["vr"] ?? 1,z:c["bb"] ?? 0,w:c["vb"] ?? 1),CIVector(x:v["k1"] ?? 0,y:v["k2"] ?? 0,z:v["k3"] ?? 0)]
            guard let corrected=kernel.apply(extent:rect,roiCallback:{_,_ in rect},arguments:args) else{throw error("镜头校正内核运行失败。")}
            // Conservative crop avoids extrapolated corner pixels. The UI discloses this crop.
            let inset=rect.insetBy(dx:w*0.04,dy:h*0.04)
            result=corrected.cropped(to:inset).transformed(by:CGAffineTransform(translationX:-inset.minX,y:-inset.minY))
        }
        return result
    }
    static func error(_ message:String)->NSError{NSError(domain:"LensCorrection",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}
