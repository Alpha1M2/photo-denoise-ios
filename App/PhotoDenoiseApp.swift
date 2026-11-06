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
    @Published var strength: Double = 0.20
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message = "未导入照片"
    @Published var lens = "未读取镜头"
    @Published var lensStatus = "镜头校正尚未检测"
    @Published var correctionAvailable = false
    @Published var correction = false
    @Published var cancelling = false
    let engine = DenoiseEngine()
    var isRaw: Bool { ["arw", "dng", "nef", "cr2", "cr3", "raf"].contains(source?.pathExtension.lowercased() ?? "") }
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let smoke = ProcessInfo.processInfo.arguments.contains("--smoke-linear") || ProcessInfo.processInfo.arguments.contains("--smoke-cancel") || ProcessInfo.processInfo.arguments.contains("--smoke-zoom") || ProcessInfo.processInfo.arguments.contains("--smoke-rgb") || ProcessInfo.processInfo.arguments.contains("--smoke-raw") || ProcessInfo.processInfo.arguments.contains("--smoke-lens")
    init() {
        if smoke { Task { @MainActor in
            if ProcessInfo.processInfo.arguments.contains("--smoke-linear") {
                DispatchQueue.global().async {let detail=DenoiseEngine.testLinearFixture();Task{@MainActor in self.reportSmoke(detail.hasPrefix("PASS"),detail)}};return
            }
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
            if ProcessInfo.processInfo.arguments.contains("--smoke-zoom") {
                let v=PhotoViewport(frame:CGRect(x:0,y:0,width:320,height:400));v.layoutIfNeeded()
                let im=UIImage(contentsOfFile:url.path)!;v.show(im,identity:url);v.setZoomScale(3,animated:false);v.contentOffset=CGPoint(x:150,y:210)
                let offset=v.contentOffset,scale=v.zoomScale
                for _ in 0..<20 {v.show(UIImage(cgImage:im.cgImage!),identity:url);v.layoutIfNeeded()}
                reportSmoke(v.contentOffset==offset && v.zoomScale==scale,"Viewport comparison retention");return
            }
            if ProcessInfo.processInfo.arguments.contains("--smoke-cancel") {
                DispatchQueue.global().async {
                    let worker=DenoiseEngine();let target=url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".jpg")
                    var cancelled=false
                    do {_ = try worker.process(url,destination:target,strength:0.2,raw:false,preview:false,center:.zero,progress:{_ in worker.cancelled=true})}catch{cancelled=worker.cancelled}
                    let absent = !FileManager.default.fileExists(atPath:target.path)
                    worker.cancelled=false
                    let recovered=(try? worker.process(url,destination:target,strength:0,raw:false,preview:false,center:.zero,progress:{_ in})) != nil
                    let ok=cancelled && absent && recovered
                    Task{@MainActor in self.reportSmoke(ok,"Cancel during processing and restart")}
                };return
            }
            load(url)
            if ProcessInfo.processInfo.arguments.contains("--smoke-lens"){correction=true;correctedJPEG()}else{run()}
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
            source = target; result = nil; after = nil
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
        if let s = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 10000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) { return UIImage(cgImage: cg) }
        if let raw = CIRAWFilter(imageURL: url), let image = raw.outputImage {
            let scale = min(1,10000/image.extent.width)
            let small = image.transformed(by: CGAffineTransform(scaleX: scale,y: scale))
            if let cg = CIContext().createCGImage(small, from: small.extent) { return UIImage(cgImage: cg) }
        }
        return DenoiseEngine.rawPreview(url)
    }
    nonisolated static func linearThumbnail(_ url:URL)->UIImage? {
        guard let raw=CIRAWFilter(imageURL:url) else{return thumbnail(url)}
        raw.baselineExposure=0;raw.exposure=0;raw.boostAmount=0;raw.boostShadowAmount=0;raw.localToneMapAmount=0
        raw.contrastAmount=0;raw.detailAmount=0;raw.sharpnessAmount=0;raw.moireReductionAmount=0
        raw.luminanceNoiseReductionAmount=0;raw.colorNoiseReductionAmount=0;raw.isLensCorrectionEnabled=false
        guard let image=raw.outputImage,let cg=CIContext().createCGImage(image,from:image.extent) else{return nil}
        return UIImage(cgImage:cg)
    }
    func cancel() {
        guard busy,!cancelling else{return}
        cancelling=true;engine.cancelled=true;message="正在取消…"
    }
    func run() {
        guard let source,!busy else{return}
        if (isRaw && DenoiseEngine.hasLocalLinearModel()) || (correction && correctionAvailable) {correctedJPEG();return}
        engine.useLocalLinearModel=false
        engine.cancelled=false;cancelling=false;busy=true;progress=0
        message="正在降噪…"
        let raw=isRaw,amount=Float(strength),engine=self.engine
        let target=folder.appendingPathComponent("denoised-\(UUID().uuidString).\(raw ? "dng" : "jpg")")
        UIApplication.shared.isIdleTimerDisabled=true
        DispatchQueue.global(qos:.userInitiated).async {
            let start=Date()
            do {
                let output=try autoreleasepool {try engine.process(source,destination:target,strength:amount,raw:raw,preview:false,center:CGPoint(x:0.5,y:0.5),progress:{value in Task{@MainActor in if !self.cancelling {self.progress=value}}})}
                if engine.cancelled {try? FileManager.default.removeItem(at:output);throw LensRenderer.error("已取消")}
                let image=autoreleasepool {Self.thumbnail(output)}
                Task{@MainActor in
                    defer {self.busy=false;self.cancelling=false;UIApplication.shared.isIdleTimerDisabled=false}
                    guard !engine.cancelled else{try? FileManager.default.removeItem(at:output);self.message="已取消";return}
                    self.after=image;self.result=output;self.message="完成 · \(Int(Date().timeIntervalSince(start))) 秒"
                    self.reportSmoke(image != nil,self.message)
                }
            }catch{Task{@MainActor in self.busy=false;self.cancelling=false;self.message=engine.cancelled ? "已取消" : error.localizedDescription;self.reportSmoke(false,self.message);UIApplication.shared.isIdleTimerDisabled=false}}
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
        guard let source,!busy else{return}
        engine.cancelled=false;cancelling=false;busy=true;progress=0;message="正在处理线性 RAW…"
        let directLinear=isRaw && !(correction && correctionAvailable) && DenoiseEngine.hasLocalLinearModel()
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+(directLinear ? ".jyl" : ".tiff"))
        let target=folder.appendingPathComponent("corrected-\(UUID().uuidString).dng")
        let engine=self.engine,amount=Float(strength),applyCorrection=correction && correctionAvailable,isRawInput=isRaw
        engine.useLocalLinearModel=isRawInput
        UIApplication.shared.isIdleTimerDisabled=true
        DispatchQueue.global(qos:.userInitiated).async {
            defer {try? FileManager.default.removeItem(at:temp)}
            do {
                try autoreleasepool {
                    if isRawInput && !applyCorrection {try DenoiseEngine.renderLinearRaw(source,destination:temp)}
                    else {try LensRenderer.renderCorrected(source,to:temp,correct:applyCorrection)}
                }
                if engine.cancelled {throw LensRenderer.error("已取消；原片未修改。")}
                let output=try autoreleasepool {try engine.process(temp,destination:target,strength:amount,raw:false,preview:false,center:CGPoint(x:0.5,y:0.5),progress:{value in Task{@MainActor in if !self.cancelling {self.progress=value}}})}
                if engine.cancelled {try? FileManager.default.removeItem(at:output);throw LensRenderer.error("已取消")}
                let reference=temp.pathExtension == "jyl" ? DenoiseEngine.linearBufferPreview(temp) : Self.thumbnail(temp)
                let image=Self.linearThumbnail(output)
                Task{@MainActor in guard !engine.cancelled else{try? FileManager.default.removeItem(at:output);self.busy=false;self.cancelling=false;self.message="已取消";UIApplication.shared.isIdleTimerDisabled=false;return};self.before=reference;self.after=image;self.result=output;self.busy=false;self.cancelling=false;self.message="线性 DNG 已就绪";if self.smoke {
                    let apple=CIRAWFilter(imageURL:output)?.outputImage
                    self.reportSmoke(apple != nil && image != nil && reference != nil,"Apple=\(apple != nil) output=\(image != nil) reference=\(reference != nil)")
                };UIApplication.shared.isIdleTimerDisabled=false}
            }catch {Task{@MainActor in self.busy=false;self.cancelling=false;self.message=error.localizedDescription;self.reportSmoke(false,error.localizedDescription);UIApplication.shared.isIdleTimerDisabled=false}}
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
                        ZoomImage(image:image,identity:model.source)
                        VStack { HStack {
                            Text(compare ? "原片" : (model.after == nil ? "原片" : "降噪后")).font(.caption)
                                .padding(.horizontal,10).padding(.vertical,5).background(.black.opacity(0.65),in:Capsule())
                            Spacer()
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
                    else {Text("全尺寸").foregroundStyle(.secondary)}
                }.font(.caption).padding(.horizontal,20).frame(height:38)
                Divider()
                Picker("调整",selection:$panel) {Text("细节").tag(0);Text("光学").tag(1)}
                    .pickerStyle(.segmented).padding(.horizontal,20).padding(.vertical,12)
                ScrollView {
                    VStack(alignment:.leading,spacing:14) {
                        if panel==0 {
                            HStack {Text(model.isRaw && DenoiseEngine.hasLocalLinearModel() ? "本地模型 · 实验" : "AI 降噪");Spacer();Text("\(Int(model.strength*100))").monospacedDigit().foregroundStyle(.secondary)}
                            Slider(value:$model.strength,in:0...1,step:0.05)
                        } else {
                            Text(model.lens).font(.subheadline)
                            Text(model.lensStatus).font(.caption).foregroundStyle(.secondary)
                            if model.correctionAvailable {
                                Toggle("镜头校正",isOn:$model.correction)
                                if !model.isRaw {Text("仅用于未经机内校正的 JPEG").font(.caption).foregroundStyle(.secondary)}
                            }
                            Text(DenoiseEngine.hasLocalLinearModel() ? "RAW 输出 16 位线性 DNG" : "校正输出 16 位线性 DNG；未校正输出 Bayer DNG。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(model.busy).padding(.horizontal,20).padding(.bottom,12)
                }.frame(maxHeight:.infinity)
                VStack(spacing:10) {
                    if model.busy {ProgressView(value:model.progress)}
                    Text(model.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                    HStack(spacing:12) {
                        if model.busy {
                            Button(model.cancelling ? "正在取消…" : "取消") {model.cancel()}.disabled(model.cancelling).frame(maxWidth:.infinity).buttonStyle(.bordered)
                        } else {
                            Button("降噪") {compare=false;model.run()}.frame(maxWidth:.infinity).buttonStyle(.borderedProminent)
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
        .alert("净影 0.3",isPresented:$about) {
            Button("完成",role:.cancel){}
        } message: {Text("离线 RAW / JPEG 降噪\nRawNIND · NIND · LibRaw\nCPU 推理 · GPL-3.0\n原片不会被覆盖")}
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url:URL
    func makeUIViewController(context:Context)->UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }
    func updateUIViewController(_ vc:UIActivityViewController,context:Context){}
}
final class PhotoViewport:UIScrollView,UIScrollViewDelegate {
    let picture=UIImageView()
    var identity:URL?
    private var canvas=CGSize.zero
    override init(frame:CGRect){super.init(frame:frame);delegate=self;minimumZoomScale=1;maximumZoomScale=32;picture.contentMode = .scaleAspectFit;addSubview(picture);alwaysBounceHorizontal=true;alwaysBounceVertical=true}
    required init?(coder:NSCoder){fatalError()}
    func viewForZooming(in scrollView:UIScrollView)->UIView?{picture}
    override func layoutSubviews(){
        super.layoutSubviews()
        guard bounds.size != canvas else{return}
        let zoom=zoomScale,old=canvas,offset=contentOffset
        setZoomScale(1,animated:false);canvas=bounds.size;picture.frame=CGRect(origin:.zero,size:canvas);contentSize=canvas
        setZoomScale(zoom,animated:false)
        if old.width>0 && old.height>0 {contentOffset=CGPoint(x:offset.x*canvas.width/old.width,y:offset.y*canvas.height/old.height)}
    }
    func show(_ image:UIImage,identity:URL?){
        let changed=self.identity != identity
        self.identity=identity
        if changed {setZoomScale(1,animated:false);contentOffset = .zero}
        // Image replacement never changes the canvas, zoom or content offset.
        picture.image=image
    }
}
struct ZoomImage:UIViewRepresentable {
    let image:UIImage
    let identity:URL?
    func makeUIView(context:Context)->PhotoViewport{PhotoViewport(frame:.zero)}
    func updateUIView(_ view:PhotoViewport,context:Context){view.show(image,identity:identity)}
}
