import SwiftUI
import PhotosUI
import Photos
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
    @Published var message = "未导入照片"
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
                lensStatus = filter.isLensCorrectionSupported ? "配置：系统镜头校正" : (correctionAvailable ? "配置：Lensfun · 畸变 / 暗角 / 色差 · 边缘裁切 4%" : "无可用校正配置")
            } else { correctionAvailable = LensRenderer.Metadata(target).matches24105; lensStatus = "JPEG 校正默认关闭 · 24–105 G 配置裁切 4%" }
            correction = isRaw && correctionAvailable
            message = "已导入 · \(url.lastPathComponent)"
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
        message = preview ? "正在生成预览…" : "正在处理全尺寸…"
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
                    self.message="完成，用时 \(Int(Date().timeIntervalSince(start))) 秒。\(preview ? "局部预览" : "可导出")"
                    self.reportSmoke(image != nil,self.message)
                    UIApplication.shared.isIdleTimerDisabled=false
                }
            } catch { Task { @MainActor in self.busy=false;self.message=error.localizedDescription;self.reportSmoke(false,error.localizedDescription);UIApplication.shared.isIdleTimerDisabled=false } }
        }
    }
    func saveToPhotos() {
        guard let result,!busy else{return}
        Task {
            let status=await PHPhotoLibrary.requestAuthorization(for:.addOnly)
            guard status == .authorized || status == .limited else{message="请允许添加照片";return}
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request=PHAssetCreationRequest.forAsset()
                    request.addResource(with:.photo,fileURL:result,options:nil)
                }
                message="已存入相册"
            }catch{message="相册导入失败："+error.localizedDescription}
        }
    }
    func correctedJPEG() {
        guard let source,!busy,correctionAvailable else{return}
        engine.cancelled=false;busy=true;progress=0;message="正在校正显影，再进行 JPEG/RGB AI 降噪…"
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".tiff")
        let target=folder.appendingPathComponent("corrected-\(UUID().uuidString).dng")
        let engine=self.engine,amount=Float(strength)
        UIApplication.shared.isIdleTimerDisabled=true
        DispatchQueue.global(qos:.userInitiated).async {
            defer {try? FileManager.default.removeItem(at:temp)}
            do {
                try LensRenderer.renderCorrected(source,to:temp)
                if engine.cancelled {throw LensRenderer.error("已取消；原片未修改。")}
                let output=try engine.process(temp,destination:target,strength:amount,raw:false,preview:false,center:CGPoint(x:0.5,y:0.5),progress:{value in Task{@MainActor in self.progress=value}})
                let image=Self.thumbnail(output)
                Task{@MainActor in self.after=image;self.result=output;self.previewMode=false;self.busy=false;self.message="线性 DNG 已就绪";if self.smoke {
                    let apple=CIRAWFilter(imageURL:output)?.outputImage
                    self.reportSmoke(apple != nil && image != nil,apple == nil ? "Apple RAW decoder rejected linear DNG" : self.message)
                };UIApplication.shared.isIdleTimerDisabled=false}
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
    @State private var panel = 0
    @State private var about = false
    private let accent = Color(red:0.32,green:0.65,blue:1)
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                HStack {
                    Text("净影").font(.headline)
                    Spacer()
                    if model.source != nil { Text(model.isRaw ? "RAW" : "JPEG").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    Button { about=true } label:{Image(systemName:"info.circle")}.accessibilityLabel("关于")
                    Menu { Button("存入相册") {model.saveToPhotos()};Button("导出到文件 / App") {share=true} } label:{Image(systemName:"square.and.arrow.up")}.disabled(model.result==nil).accessibilityLabel("导出")
                }.padding(.horizontal,20).frame(height:48)
                ZStack {
                    Color.black
                    if let image=compare ? model.before : (model.after ?? model.before) {
                        ZoomImage(image:image)
                        VStack { HStack {
                            Text(compare ? "原片" : (model.after == nil ? "原片" : "降噪后")).font(.caption)
                                .padding(.horizontal,10).padding(.vertical,5).background(.black.opacity(0.65),in:Capsule())
                            Spacer()
                            if model.previewMode {Text("局部预览").font(.caption).padding(6).background(.black.opacity(0.65),in:Capsule())}
                        }; Spacer() }.padding(12).allowsHitTesting(false)
                    } else {
                        VStack(spacing:14) {
                            Image(systemName:"photo").font(.system(size:32,weight:.light))
                            Text("导入照片").font(.subheadline)
                            Text("ARW · DNG · JPEG").font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(.secondary)
                    }
                }.frame(height:max(180,geometry.size.height*0.43))
                HStack {
                    Button {compare.toggle()} label:{Label(compare ? "原片" : "对比",systemImage:"square.on.square")}
                        .disabled(model.before==nil).tint(compare ? accent : .white)
                    Spacer()
                    if model.busy {Text("\(Int(model.progress*100))%").monospacedDigit()}
                    else {Text(model.previewMode ? "1024 px" : "全尺寸").foregroundStyle(.secondary)}
                }.font(.caption).padding(.horizontal,20).frame(height:38)
                Divider()
                Picker("调整",selection:$panel) {Text("细节").tag(0);Text("光学").tag(1)}
                    .pickerStyle(.segmented).padding(.horizontal,20).padding(.vertical,12)
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        if panel==0 {
                            HStack {Text("AI 降噪");Spacer();Text("\(Int(model.strength*100))").monospacedDigit().foregroundStyle(.secondary)}
                            Slider(value:$model.strength,in:0...1,step:0.05)
                            DisclosureGroup("预览区域") {
                                VStack(spacing:6) {
                                    HStack {Text("水平").font(.caption);Slider(value:$model.centerX,in:0...1)}
                                    HStack {Text("垂直").font(.caption);Slider(value:$model.centerY,in:0...1)}
                                }.padding(.top,8)
                            }.font(.subheadline)
                        } else {
                            Text(model.lens).font(.subheadline)
                            Text(model.lensStatus).font(.caption).foregroundStyle(.secondary)
                            if model.correctionAvailable {
                                Toggle("镜头校正",isOn:$model.correction)
                                if !model.isRaw {Text("仅用于未经机内校正的 JPEG").font(.caption).foregroundStyle(.secondary)}
                            }
                            Text("校正输出 16 位线性 DNG；未校正输出 Bayer DNG。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(model.busy).padding(.horizontal,20).padding(.bottom,12)
                }.frame(maxHeight:.infinity)
                VStack(spacing:10) {
                    if model.busy {ProgressView(value:model.progress)}
                    Text(model.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                    HStack(spacing:12) {
                        if model.busy {
                            Button("取消") {model.engine.cancelled=true}.frame(maxWidth:.infinity).buttonStyle(.bordered)
                        } else {
                            Button("预览") {compare=false;model.run(preview:true)}.frame(maxWidth:.infinity).buttonStyle(.bordered)
                            Button(panel==1 && model.correction ? "校正并降噪" : "应用降噪") {
                                compare=false
                                if panel==1 && model.correction {model.correctedJPEG()}else{model.run(preview:false)}
                            }.frame(maxWidth:.infinity).buttonStyle(.borderedProminent)
                        }
                    }.disabled(model.source==nil).controlSize(.regular)
                    Divider()
                    HStack {
                        Button {showFiles=true} label:{Label("文件",systemImage:"folder")}
                        Spacer()
                        PhotosPicker(selection:$photo,matching:.images,preferredItemEncoding:.current) {Label("照片",systemImage:"photo.on.rectangle")}
                    }.font(.subheadline).disabled(model.busy).padding(.vertical,4)
                }.padding(.horizontal,20).padding(.bottom,8)
            }.background(Color(white:0.10)).tint(accent)
        }
        .fileImporter(isPresented:$showFiles,allowedContentTypes:[.image,.data],allowsMultipleSelection:false) { result in if case .success(let urls)=result,let url=urls.first {model.load(url)} }
        .onChange(of:photo) { _, item in Task { if let data = try? await item?.loadTransferable(type:Data.self) { let ext=item?.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg";let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"."+ext);do {try data.write(to:url);model.load(url);try? FileManager.default.removeItem(at:url)}catch {model.message=error.localizedDescription} } } }
        .sheet(isPresented:$share) { if let url=model.result { ShareSheet(url:url) } }
        .alert("净影 0.1",isPresented:$about) {
            Button("完成",role:.cancel){}
        } message: {Text("离线 RAW / JPEG 降噪\nRawNIND · NIND · LibRaw\nCPU 推理 · GPL-3.0\n原片不会被覆盖")}
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
