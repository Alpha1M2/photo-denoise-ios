import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreImage
import ImageIO

@main struct PhotoDenoiseApp: App {
    var body: some Scene { WindowGroup { StudioView().preferredColorScheme(.dark) } }
}

@MainActor final class Studio: ObservableObject {
    @Published var source: URL?
    @Published var result: URL?
    @Published var before: UIImage?
    @Published var after: UIImage?
    @Published var strength: Double = 0.35
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message = "导入照片，先检查局部，再处理原尺寸。"
    @Published var lens = "未读取镜头"
    @Published var lensStatus = "镜头校正尚未检测"
    @Published var correctionAvailable = false
    @Published var correction = false
    @Published var centerX = 0.5
    @Published var centerY = 0.5
    @Published var previewMode = false
    let engine = DenoiseEngine()
    var isRaw: Bool { ["arw", "dng", "nef", "cr2", "cr3", "raf"].contains(source?.pathExtension.lowercased() ?? "") }
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let smoke = ProcessInfo.processInfo.arguments.contains("--smoke-rgb") || ProcessInfo.processInfo.arguments.contains("--smoke-raw") || ProcessInfo.processInfo.arguments.contains("--smoke-lens")
    init() {
        if smoke { Task { @MainActor in
            let raw=ProcessInfo.processInfo.arguments.contains("--smoke-raw")
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(raw ? "synthetic.dng" : "synthetic.jpg")
            if raw { _=DenoiseEngine.writeSmokeRaw(url) }
            else {
                let format=UIGraphicsImageRendererFormat();format.scale=1
                let image=UIGraphicsImageRenderer(size:CGSize(width:768,height:768),format:format).image { ctx in
                    UIColor.darkGray.setFill();ctx.fill(CGRect(x:0,y:0,width:768,height:768))
                    for y in 0..<96 {for x in 0..<96 {let v=CGFloat((x*17+y*31)%51)/255+0.25;UIColor(white:v,alpha:1).setFill();ctx.fill(CGRect(x:x*8,y:y*8,width:8,height:8))}}
                    ("LOCAL TEST / JPEG" as NSString).draw(at:CGPoint(x:60,y:360),withAttributes:[.font:UIFont.boldSystemFont(ofSize:42),.foregroundColor:UIColor.white])
                }
                if ProcessInfo.processInfo.arguments.contains("--smoke-lens"),let cg=image.cgImage,let dst=CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil) {
                    CGImageDestinationAddImage(dst,cg,[kCGImagePropertyExifDictionary:[kCGImagePropertyExifLensModel:"FE 24-105mm F4 G OSS",kCGImagePropertyExifFocalLength:24,kCGImagePropertyExifFNumber:4]] as CFDictionary)
                    CGImageDestinationFinalize(dst)
                } else {try? image.jpegData(compressionQuality:1)?.write(to:url)}
            }
            load(url)
            if ProcessInfo.processInfo.arguments.contains("--smoke-lens"){correctedJPEG()}else{run(preview:true)}
        } }
    }
    func reportSmoke(_ ok:Bool,_ text:String) {
        guard smoke else{return}
        let data=try? JSONSerialization.data(withJSONObject:["ok":ok,"message":text])
        try? data?.write(to:folder.appendingPathComponent("smoke-status.json"),options:.atomic)
    }
    func load(_ url: URL) {
        guard !busy else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let target = folder.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            try FileManager.default.copyItem(at: url, to: target)
            source = target; result = nil; after = nil; previewMode = false
            before = Self.thumbnail(target)
            if let s = CGImageSourceCreateWithURL(target as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any] {
                let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
                lens = exif?[kCGImagePropertyExifLensModel as String] as? String ?? "镜头型号未识别"
            }
            if isRaw, let filter = CIRAWFilter(imageURL: target) {
                correctionAvailable = LensRenderer.supports(target)
                lensStatus = filter.isLensCorrectionSupported ? "系统支持此原片的镜头校正；用于显影导出，不改写传感器 DNG。" : (correctionAvailable ? "24–105 G：Lensfun 畸变、暗角、色差数据。显影导出四边各裁切4%。" : "系统未提供此原片的镜头校正；不会套用其他型号。")
            } else { correctionAvailable = LensRenderer.Metadata(target).matches24105; lensStatus = "JPEG 默认不重复校正。仅确认相机未校正时使用校正导出；24–105 配置四边各裁切4%。" }
            correction = isRaw && correctionAvailable
            message = "已导入 \(url.lastPathComponent)。建议先用 35% 强度试算。"
        } catch { message = error.localizedDescription }
    }
    nonisolated static func thumbnail(_ url: URL) -> UIImage? {
        if let s = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { return UIImage(cgImage: cg) }
        if let raw = CIRAWFilter(imageURL: url), let image = raw.outputImage {
            let scale = min(1,1600/image.extent.width)
            let small = image.transformed(by: CGAffineTransform(scaleX: scale,y: scale))
            if let cg = CIContext().createCGImage(small, from: small.extent) { return UIImage(cgImage: cg) }
        }
        return DenoiseEngine.rawPreview(url)
    }
    func run(preview: Bool) {
        guard let source, !busy else { return }
        engine.cancelled=false;busy = true; progress = 0; result = nil; after = nil; previewMode = preview
        message = preview ? "正在试算 1024 像素局部…" : "正在逐块处理全尺寸，请保持 App 在前台。"
        let raw = isRaw, amount = Float(strength), center = CGPoint(x:centerX,y:centerY)
        let target = folder.appendingPathComponent("\(preview ? "preview" : "denoised")-\(UUID().uuidString).\(raw ? "dng" : "jpg")")
        let engine = self.engine
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            do {
                if preview {
                    let reference=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".\(raw ? "dng" : "jpg")")
                    let referenceURL=try engine.process(source,destination:reference,strength:0,raw:raw,preview:true,center:center,progress:{_ in})
                    let originalPatch=Self.thumbnail(referenceURL)
                    try? FileManager.default.removeItem(at:reference)
                    Task{@MainActor in self.before=originalPatch}
                    if engine.cancelled {throw LensRenderer.error("已取消；原片未修改。")}
                } else {let full=Self.thumbnail(source);Task{@MainActor in self.before=full}}
                let output = try engine.process(source, destination: target, strength: amount, raw: raw, preview: preview, center: center, progress: { value in
                    Task { @MainActor in self.progress = value }
                })
                let image = Self.thumbnail(output)
                Task { @MainActor in
                    self.after=image; self.result=preview ? nil : output; self.busy=false
                    self.message="完成，用时 \(Int(Date().timeIntervalSince(start))) 秒。\(preview ? "这是局部预览，尚未导出全图。" : "原片保留，可分享导出。")"
                    self.reportSmoke(image != nil,self.message)
                    UIApplication.shared.isIdleTimerDisabled=false
                }
            } catch { Task { @MainActor in self.busy=false;self.message=error.localizedDescription;self.reportSmoke(false,error.localizedDescription);UIApplication.shared.isIdleTimerDisabled=false } }
        }
    }
    func correctedJPEG() {
        guard let source,!busy,correctionAvailable else{return}
        engine.cancelled=false;busy=true;progress=0;message="正在校正显影，再进行 JPEG/RGB AI 降噪…"
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".tiff")
        let target=folder.appendingPathComponent("corrected-\(UUID().uuidString).jpg")
        let engine=self.engine,amount=Float(strength)
        UIApplication.shared.isIdleTimerDisabled=true
        DispatchQueue.global(qos:.userInitiated).async {
            defer {try? FileManager.default.removeItem(at:temp)}
            do {
                try LensRenderer.renderCorrected(source,to:temp)
                if engine.cancelled {throw LensRenderer.error("已取消；原片未修改。")}
                let output=try engine.process(temp,destination:target,strength:amount,raw:false,preview:false,center:CGPoint(x:0.5,y:0.5),progress:{value in Task{@MainActor in self.progress=value}})
                let image=Self.thumbnail(output)
                Task{@MainActor in self.after=image;self.result=output;self.previewMode=false;self.busy=false;self.message="校正并降噪完成。这是显影后的 JPEG，原 RAW 保留。";self.reportSmoke(image != nil,self.message);UIApplication.shared.isIdleTimerDisabled=false}
            }catch {Task{@MainActor in self.busy=false;self.message=error.localizedDescription;self.reportSmoke(false,error.localizedDescription);UIApplication.shared.isIdleTimerDisabled=false}}
        }
    }
}

struct StudioView: View {
    @StateObject var model = Studio()
    @State private var showFiles = false
    @State private var photo: PhotosPickerItem?
    @State private var compare = false
    @State private var share = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack { VStack(alignment:.leading,spacing:5) { Text("保留夜色，也保留细节").font(.title2.bold()); Text("RAW · JPEG / 本机离线 AI").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName:"moon.stars.fill").font(.largeTitle).foregroundStyle(.mint) }
                    HStack { Button { showFiles=true } label: { Label("文件导入",systemImage:"folder") }; PhotosPicker(selection:$photo,matching:.images,preferredItemEncoding:.current) { Label("相册导入",systemImage:"photo") } }.buttonStyle(.bordered).disabled(model.busy)
                    if let image = compare ? model.before : (model.after ?? model.before) {
                        ZoomImage(image:image).frame(height:320).clipShape(RoundedRectangle(cornerRadius:18))
                        Text("双指缩放检查细节。\(model.previewMode ? "试算前后为同一局部、同一显影方式。" : "")").font(.caption).foregroundStyle(.secondary)
                        Toggle("查看原片参考",isOn:$compare)
                    } else { RoundedRectangle(cornerRadius:18).fill(.white.opacity(0.04)).frame(height:250).overlay { ContentUnavailableView("导入一张夜景照片",systemImage:"photo.badge.plus",description:Text("Sony ARW / DNG / JPEG")) } }
                    VStack(alignment:.leading,spacing:10) {
                        HStack { Text("降噪强度").bold(); Spacer(); Text("\(Int(model.strength*100))%").monospacedDigit().foregroundStyle(.mint) }
                        Slider(value:$model.strength,in:0...1,step:0.05)
                        Text("低强度保留纹理。不要用额外锐化掩盖已丢失的细节。").font(.caption).foregroundStyle(.secondary)
                        Text("局部试算位置").font(.subheadline)
                        HStack { Text("左右");Slider(value:$model.centerX,in:0...1);Text("上下");Slider(value:$model.centerY,in:0...1) }
                    }.disabled(model.busy)
                    VStack(alignment:.leading,spacing:8) {
                        Label("镜头",systemImage:"camera.aperture").bold();Text(model.lens).font(.subheadline)
                        Text(model.lensStatus).font(.caption).foregroundStyle(.secondary)
                        Text("传感器 DNG 保留原始几何；镜头校正需要在显影输出阶段进行。").font(.caption).foregroundStyle(.secondary)
                        if model.correctionAvailable {
                            Toggle(model.isRaw ? "启用校正 JPEG 导出" : "确认 JPEG 尚未经过镜头校正",isOn:$model.correction)
                            Button("校正并降噪 → JPEG") {compare=false;model.correctedJPEG()}.disabled(model.busy || !model.correction)
                        }
                    }.padding().frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:14))
                    if model.busy { ProgressView(value:model.progress).tint(.mint); Button("取消处理",role:.destructive) { model.engine.cancelled=true } }
                    Text(model.message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("局部试算") {compare=false;model.run(preview:true)}.buttonStyle(.bordered)
                        Button("处理原尺寸") {compare=false;model.run(preview:false)}.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    }.disabled(model.source==nil || model.busy)
                    if model.result != nil { Button {share=true} label:{Label("导出 / 存储到文件",systemImage:"square.and.arrow.up")}.buttonStyle(.bordered) }
                    Text("净影 0.1 · RawNIND / NIND · GPL-3.0\n一次处理一张；原始文件不会被覆盖。此版本推理使用 CPU，真机性能以实际计时为准。").font(.caption2).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("净影").background(Color(red:0.035,green:0.055,blue:0.075)).tint(.mint)
        }
        .fileImporter(isPresented:$showFiles,allowedContentTypes:[.image,.data],allowsMultipleSelection:false) { result in if case .success(let urls)=result,let url=urls.first {model.load(url)} }
        .onChange(of:photo) { _, item in Task { if let data = try? await item?.loadTransferable(type:Data.self) { let ext=item?.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg";let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"."+ext);do {try data.write(to:url);model.load(url);try? FileManager.default.removeItem(at:url)}catch {model.message=error.localizedDescription} } } }
        .sheet(isPresented:$share) { if let url=model.result { ShareSheet(url:url) } }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context)->UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }
    func updateUIViewController(_ vc:UIActivityViewController,context:Context){}
}
struct ZoomImage:UIViewRepresentable {
    let image:UIImage
    func makeCoordinator()->Coordinator{Coordinator()}
    func makeUIView(context:Context)->UIScrollView{let v=UIScrollView();v.delegate=context.coordinator;v.minimumZoomScale=1;v.maximumZoomScale=12;let im=UIImageView();im.contentMode = .scaleAspectFit;im.tag=9;v.addSubview(im);return v}
    func updateUIView(_ view:UIScrollView,context:Context){guard let im=view.viewWithTag(9) as? UIImageView else{return};if im.image !== image {view.zoomScale=1;im.image=image};im.frame=view.bounds;view.contentSize=view.bounds.size}
    class Coordinator:NSObject,UIScrollViewDelegate{func viewForZooming(in scrollView:UIScrollView)->UIView?{scrollView.viewWithTag(9)}}
}
