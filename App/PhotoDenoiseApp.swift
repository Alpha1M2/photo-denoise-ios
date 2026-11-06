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
    @Published var strength: Double = 0.50
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message = "未导入照片"
    @Published var lens = "未读取镜头"
    @Published var lensStatus = "镜头校正尚未检测"
    @Published var correctionAvailable = false
    @Published var correctDistortion=false
    @Published var correctVignetting=false
    @Published var correctChromatic=false
    @Published var availableOptions=LensRenderer.Options(distortion:false,vignetting:false,chromatic:false)
    var correction:Bool {
        get {correctDistortion || correctVignetting || correctChromatic}
        set {correctDistortion=newValue && availableOptions.distortion;correctVignetting=newValue && availableOptions.vignetting;correctChromatic=newValue && availableOptions.chromatic}
    }
    @Published var cancelling = false
    @Published var previewImage: UIImage?
    @Published var previewRegion = CGRect.zero
    @Published var previewAmount: Double = 0
    @Published var previewing = false
    @Published var eta = ""
    @Published var backgroundStatus = ""
    var visibleRegion = CGRect(x:0,y:0,width:1,height:1)
    var interruptedMessage:String?
    var preparing = false
    var cachedInput:URL?
    var cachedKey:String?
    var estimate=RenderEstimate()
    var wholeSeconds:Double?
    var inferenceStarted:TimeInterval=0
    var etaDeadline:TimeInterval?
    let engine = DenoiseEngine()
    var detectedRaw=false
    @Published var accelerate=true
    @Published var backend=""
    var isRaw: Bool { detectedRaw || ["arw", "dng", "nef", "cr2", "cr3", "raf"].contains(source?.pathExtension.lowercased() ?? "") }
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let smoke = ProcessInfo.processInfo.arguments.contains("--smoke-lcp") || ProcessInfo.processInfo.arguments.contains("--smoke-background") || ProcessInfo.processInfo.arguments.contains("--smoke-preview") || ProcessInfo.processInfo.arguments.contains("--smoke-linear") || ProcessInfo.processInfo.arguments.contains("--smoke-cancel") || ProcessInfo.processInfo.arguments.contains("--smoke-zoom") || ProcessInfo.processInfo.arguments.contains("--smoke-rgb") || ProcessInfo.processInfo.arguments.contains("--smoke-raw") || ProcessInfo.processInfo.arguments.contains("--smoke-lens")
    init() {
        if !smoke,let saved=UserDefaults.standard.string(forKey:"lastOutput"),FileManager.default.fileExists(atPath:saved) {
            result=URL(fileURLWithPath:saved)
            if let input=UserDefaults.standard.string(forKey:"lastSource"),FileManager.default.fileExists(atPath:input) {source=URL(fileURLWithPath:input)}
            message="上次处理结果";Task{@MainActor in self.refreshDisplay()}
        }
        if smoke { Task { @MainActor in
            if ProcessInfo.processInfo.arguments.contains("--smoke-lcp") {let local=LocalLensProfiles.selfTest(),sony=SonyCorrections.selfTest();reportSmoke(local.hasPrefix("PASS") && sony.hasPrefix("PASS"),local+"; "+sony);return}
            if ProcessInfo.processInfo.arguments.contains("--smoke-background") {
                var mode="",starts=0,sawBackground=false
                mode=RenderLifetime.shared.start(smoke:false,work:{
                    starts+=1
                    DispatchQueue.global(qos:.userInitiated).async {
                        let end=Date().addingTimeInterval(30)
                        var nextProbe=Date()
                        var checksum:UInt64=1
                        while Date()<end {
                            for _ in 0..<100_000 {checksum=checksum &* 6364136223846793005 &+ 1}
                            if Date()>=nextProbe {
                                nextProbe=Date().addingTimeInterval(0.25)
                                DispatchQueue.main.async {sawBackground = sawBackground || UIApplication.shared.applicationState == .background}
                            }
                        }
                        let value=checksum
                        Task{@MainActor in
                            self.reportSmoke(starts==1 && sawBackground,"\(mode); background=\(sawBackground); starts=\(starts); checksum=\(value)")
                            RenderLifetime.shared.finish(success:true,notify:false)
                        }
                    }
                },cancel:{self.reportSmoke(false,"Background test expired")})
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--smoke-linear") {
                DispatchQueue.global().async {let detail=DenoiseEngine.testLinearFixture();Task{@MainActor in self.reportSmoke(detail.hasPrefix("PASS"),detail)}};return
            }
            let raw=ProcessInfo.processInfo.arguments.contains("--smoke-raw") || ProcessInfo.processInfo.arguments.contains("--smoke-preview")
            // Photos may supply a generic RAW suffix. Recognition must inspect bytes.
            let url=FileManager.default.temporaryDirectory.appendingPathComponent(raw ? "synthetic.raw" : "synthetic.jpg")
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
                let offset=v.contentOffset,scale=v.zoomScale,region=v.visibleImageRegion()
                for _ in 0..<20 {v.show(UIImage(cgImage:im.cgImage!),identity:url);v.layoutIfNeeded()}
                var estimate=RenderEstimate();estimate.reset(now:10);estimate.update(done:1,now:12);estimate.update(done:2,now:14)
                reportSmoke(v.contentOffset==offset && v.zoomScale==scale && v.visibleImageRegion()==region && region.width<1 && estimate.remaining(10)==16,"Viewport, visible ROI and measured ETA retention");return
            }
            if ProcessInfo.processInfo.arguments.contains("--smoke-cancel") {
                DispatchQueue.global().async {
                    let worker=DenoiseEngine();let target=url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".jpg")
                    var cancelled=false
                    do {_ = try worker.process(url,destination:target,strength:0.2,raw:false,preview:false,center:.zero,progress:{value in if value>0 {worker.cancelled=true}})}catch{cancelled=worker.cancelled}
                    let absent = !FileManager.default.fileExists(atPath:target.path)
                    worker.cancelled=false
                    let recovered=(try? worker.process(url,destination:target,strength:0,raw:false,preview:false,center:.zero,progress:{_ in})) != nil
                    let ok=cancelled && absent && recovered
                    Task{@MainActor in self.reportSmoke(ok,"Cancel during processing and restart")}
                };return
            }
            load(url)
            if raw && !isRaw {reportSmoke(false,"RAW content was misclassified by filename");return}
            if ProcessInfo.processInfo.arguments.contains("--smoke-preview") {visibleRegion=CGRect(x:0.6,y:0.1,width:0.25,height:0.25);run(preview:true);return}
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
            if let cachedInput {try? FileManager.default.removeItem(at:cachedInput)}
            cachedInput=nil;cachedKey=nil;previewImage=nil;previewRegion = .zero;wholeSeconds=nil;eta=""
            source = target; result = nil; after = nil
            detectedRaw=DenoiseEngine.rawMetadata(target) != nil
            lens="镜头型号未识别"
            before = Self.thumbnail(target)
            if let s = CGImageSourceCreateWithURL(target as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any] {
                let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
                lens = exif?[kCGImagePropertyExifLensModel as String] as? String ?? "镜头型号未识别"
            }
            let metadata=LensRenderer.Metadata(target)
            availableOptions=LensRenderer.available(target)
            if !metadata.lens.isEmpty {lens=metadata.lens}
            if isRaw {
                correctionAvailable = LensRenderer.supports(target)
                if SonyCorrections(target) != nil {lensStatus="配置：索尼原片内嵌 · 独立校正"}
                else if let profile=LocalLensProfiles.profile(metadata) {
                    lensStatus="配置：本地 LCP · 畸变 / 暗角 · 自动裁切"+(profile.records.contains{$0.piecewise != nil} ? " · 暗角多项式近似" : "")
                } else {lensStatus = CIRAWFilter(imageURL:target)?.isLensCorrectionSupported == true ? "配置：系统镜头校正" : (correctionAvailable ? "配置：Lensfun · 畸变 / 暗角 / 色差 · 边缘裁切 4%" : "此原片暂无可用校正配置")}
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
        DenoiseEngine.linearBufferPreview(url)
    }
    func cancel() {
        guard busy,!cancelling else{return}
        cancelling=true;engine.cancelled=true;message="正在取消…"
    }
    func didBackground() {
        if busy && (preparing || previewing) {cancel()}
    }
    func refreshDisplay() {
        guard !busy,let result else{return}
        if result.pathExtension=="dng",let image=Self.linearThumbnail(result) {after=image}
        else {after=Self.thumbnail(result)}
    }
    func run(preview:Bool=false) {
        guard let source,!busy else{return}
        let localRaw=isRaw && DenoiseEngine.hasLocalLinearModel(),correct=correction && correctionAvailable
        let correctionOptions=LensRenderer.Options(distortion:correctDistortion,vignetting:correctVignetting,chromatic:correctChromatic)
        let linear=localRaw || correct,rawSensor=isRaw && !linear
        let key=source.path+"|"+correctionOptions.key+"|"+String(localRaw)
        let reused=cachedKey==key ? cachedInput : nil
        let amount=Float(strength),region=visibleRegion,engine=self.engine
        let target=folder.appendingPathComponent("\(preview ? "preview" : "denoised")-\(UUID().uuidString).\(linear || rawSensor ? "dng" : "jpg")")
        interruptedMessage=nil;engine.metadataSource=source;engine.cancelled=false;engine.useLocalLinearModel=localRaw;engine.requestedPreviewRegion=region;engine.accelerate=accelerate && !smoke
        backend=accelerate ? "准备加速引擎…" : "CPU"
        busy=true;cancelling=false;previewing=preview;preparing=true;progress=0;eta="";etaDeadline=nil;backgroundStatus="";message="准备图像 · 请保持前台"
        previewImage=nil;after=nil;result=nil
        UIApplication.shared.isIdleTimerDisabled=true
        if !preview && !smoke {RenderLifetime.shared.requestNotifications()}
        DispatchQueue.global(qos:.userInitiated).async {
            var prepared=reused ?? source;var reference:UIImage?;var created=false
            do {
                if !rawSensor && reused == nil {
                    prepared=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".jyl");created=true
                    try autoreleasepool {
                        if localRaw && !correct {try DenoiseEngine.renderLinearRaw(source,destination:prepared);reference=DenoiseEngine.linearBufferPreview(prepared)}
                        else {
                            if correct {
                                let image=try LensRenderer.correctedImage(source,options:correctionOptions)
                                try DenoiseEngine.prepareCIImage(image,destination:prepared,linear:localRaw)
                                if localRaw {reference=DenoiseEngine.linearBufferPreview(prepared)}
                                else if let cg=CIContext().createCGImage(image,from:image.extent) {reference=UIImage(cgImage:cg)}
                            } else {
                                reference=Self.thumbnail(source)
                                try DenoiseEngine.prepareImageBuffer(source,destination:prepared,linear:localRaw)
                            }
                        }
                    }
                    try? FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:prepared.path)
                }
                if engine.cancelled {throw LensRenderer.error("已取消")}
                let input=prepared,ref=reference
                Task{@MainActor in
                    self.preparing=false
                    if created {if let old=self.cachedInput,old != input {try? FileManager.default.removeItem(at:old)};self.cachedInput=input;self.cachedKey=key}
                    if let ref {self.before=ref}
                    let work={self.execute(input:input,target:target,source:source,amount:amount,raw:rawSensor,linear:linear,preview:preview)}
                    if preview {self.message="正在预览…";work()}
                    else {self.message="正在处理整图…";self.backgroundStatus=RenderLifetime.shared.start(smoke:self.smoke,work:work,cancel:{self.interruptedMessage="后台任务已结束，请在前台重试";self.cancel()})}
                }
            } catch {
                if created {try? FileManager.default.removeItem(at:prepared)}
                Task{@MainActor in self.failed(error)}
            }
        }
    }
    func updateProgress(_ value:Double,units:Int,fullUnits:Int) {
        guard busy,!cancelling else{return}
        progress=value
        backend=engine.backendName ?? "CPU"
        let now=ProcessInfo.processInfo.systemUptime
        if value==0 {estimate.reset(now:now);inferenceStarted=now;etaDeadline=nil;eta="正在测算…";return}
        let done=Int((value*Double(units)).rounded())
        estimate.update(done:done,now:now)
        if let rate=estimate.secondsPerUnit {wholeSeconds=rate*Double(fullUnits)}
        if value>=1 {etaDeadline=nil;eta="正在写出…"}
        else if let seconds=estimate.remaining(units) {etaDeadline=now+seconds;refreshETA()}
        if !previewing {RenderLifetime.shared.update(value,subtitle:eta)}
    }
    func refreshETA() {
        guard busy,!preparing,!cancelling,let deadline=etaDeadline else{return}
        let seconds=max(0,Int(ceil(deadline-ProcessInfo.processInfo.systemUptime)))
        eta=seconds>0 ? (seconds<60 ? "剩余约 \(seconds) 秒" : "剩余约 \(seconds/60) 分 \(seconds%60) 秒") : "仍在处理 · 正在更新估算…"
    }
    func execute(input:URL,target:URL,source:URL,amount:Float,raw:Bool,linear:Bool,preview:Bool) {
        let engine=self.engine
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let output=try autoreleasepool {try engine.process(input,destination:target,strength:amount,raw:raw,preview:preview,center:CGPoint(x:0.5,y:0.5),progress:{value in
                    let units=engine.workUnits,full=engine.fullWorkUnits
                    Task{@MainActor in self.updateProgress(value,units:units,fullUnits:full)}
                })}
                if engine.cancelled {try? FileManager.default.removeItem(at:output);throw LensRenderer.error("已取消")}
                let rect=engine.processedRegion
                Task{@MainActor in
                    guard !engine.cancelled else{try? FileManager.default.removeItem(at:output);self.failed(LensRenderer.error("已取消"));return}
                    self.busy=false;self.cancelling=false;self.preparing=false;UIApplication.shared.isIdleTimerDisabled=false
                    if preview {
                        self.previewImage=linear ? Self.linearThumbnail(output) : Self.thumbnail(output);self.previewRegion=rect;self.previewAmount=Double(amount)
                        self.message="预览 · \(Int((Double(amount)*100).rounded()))";self.eta=self.wholeSeconds.map{"预计整图 "+RenderEstimate.text($0)} ?? ""
                        try? FileManager.default.removeItem(at:output)
                    } else {
                        self.result=output;self.previewImage=nil;self.message="整图处理完成";self.eta=""
                        UserDefaults.standard.set(output.path,forKey:"lastOutput");UserDefaults.standard.set(source.path,forKey:"lastSource")
                        RenderLifetime.shared.finish(success:true,notify:!self.smoke)
                        if UIApplication.shared.applicationState == .active || self.smoke {self.refreshDisplay()}
                    }
                    if self.smoke {
                        let image=preview ? self.previewImage : self.after
                        let apple=(!linear || preview) ? true : CIRAWFilter(imageURL:output)?.outputImage != nil
                        self.reportSmoke(image != nil && apple && (!preview || (self.result == nil && rect.width<1)),"Image=\(image != nil) Apple=\(apple) preview=\(preview)")
                    }
                }
            }catch {Task{@MainActor in self.failed(error)}}
        }
    }
    func failed(_ error:Error) {
        busy=false;cancelling=false;preparing=false;eta="";message=interruptedMessage ?? (engine.cancelled ? "已取消" : error.localizedDescription)
        UIApplication.shared.isIdleTimerDisabled=false
        if !previewing {RenderLifetime.shared.finish(success:false,notify:false)}
        reportSmoke(false,message)
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
    func correctedJPEG() {run()}

}

struct StudioView: View {
    @StateObject var model = Studio()
    @State private var showFiles = false
    @State private var photo: PhotosPickerItem?
    @State private var compare = false
    @State private var share = false
    @State private var panel = 0
    @State private var about = false
    @Environment(\.scenePhase) private var scenePhase
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
                        ZoomImage(image:image,identity:model.source,patch:compare ? nil : model.previewImage,region:model.previewRegion,onVisible:{model.visibleRegion=$0})
                        VStack { HStack {
                            Text(compare ? "原片" : (model.previewImage != nil ? "预览 \(Int((model.previewAmount*100).rounded()))" : (model.after == nil ? "原片" : "降噪后"))).font(.caption)
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
                            Toggle("Core ML 加速",isOn:$model.accelerate).font(.subheadline)
                            if !model.backend.isEmpty {Text(model.backend).font(.caption).foregroundStyle(.secondary)}
                        } else {
                            Text(model.lens).font(.subheadline)
                            Text(model.lensStatus).font(.caption).foregroundStyle(.secondary)
                            if model.correctionAvailable {
                                Toggle("畸变",isOn:$model.correctDistortion).disabled(!model.availableOptions.distortion)
                                Toggle("暗角",isOn:$model.correctVignetting).disabled(!model.availableOptions.vignetting)
                                Toggle("色差",isOn:$model.correctChromatic).disabled(!model.availableOptions.chromatic)
                                if !model.isRaw {Text("仅用于未经机内校正的 JPEG").font(.caption).foregroundStyle(.secondary)}
                            }
                            Text(DenoiseEngine.hasLocalLinearModel() ? "RAW 输出 16 位线性 DNG" : "校正输出 16 位线性 DNG；未校正输出 Bayer DNG。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(model.busy).padding(.horizontal,20).padding(.bottom,12)
                }.frame(maxHeight:.infinity)
                VStack(spacing:10) {
                    if model.busy {ProgressView(value:model.progress)}
                    if !model.eta.isEmpty {Text(model.eta).font(.caption).monospacedDigit().frame(maxWidth:.infinity,alignment:.leading)}
                    if model.busy && !model.backgroundStatus.isEmpty {Text(model.backgroundStatus).font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)}
                    Text(model.message).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                    HStack(spacing:12) {
                        if model.busy {
                            Button(model.cancelling ? "正在取消…" : "取消") {model.cancel()}.disabled(model.cancelling).frame(maxWidth:.infinity).buttonStyle(.bordered)
                        } else {
                            Button("预览") {compare=false;model.run(preview:true)}.frame(maxWidth:.infinity).buttonStyle(.bordered)
                            Button("处理整图") {compare=false;model.run()}.frame(maxWidth:.infinity).buttonStyle(.borderedProminent)
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
        .onChange(of:scenePhase) {_,phase in if phase == .background {model.didBackground()};if phase == .active {model.refreshDisplay()}}
        .task(id:model.busy) {
            guard model.busy else{return}
            while !Task.isCancelled {
                do {try await Task.sleep(nanoseconds:1_000_000_000)}catch{break}
                model.refreshETA()
            }
        }
        .fileImporter(isPresented:$showFiles,allowedContentTypes:[.image,.data],allowsMultipleSelection:false) { result in if case .success(let urls)=result,let url=urls.first {model.load(url)} }
        .onChange(of:photo) { _, item in Task { if let data = try? await item?.loadTransferable(type:Data.self) { let ext=item?.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg";let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"."+ext);do {try data.write(to:url);model.load(url);try? FileManager.default.removeItem(at:url)}catch {model.message=error.localizedDescription} } } }
        .sheet(isPresented:$share) { if let url=model.result { ShareSheet(url:url) } }
        .alert("净影 0.5",isPresented:$about) {
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
    let picture=UIImageView(),patch=UIImageView()
    var identity:URL?
    var region=CGRect.zero
    var onVisible:((CGRect)->Void)?
    private var canvas=CGSize.zero
    override init(frame:CGRect){super.init(frame:frame);delegate=self;minimumZoomScale=1;maximumZoomScale=32;picture.contentMode = .scaleAspectFit;addSubview(picture);picture.addSubview(patch);patch.contentMode = .scaleToFill;patch.layer.borderWidth=0.5;patch.layer.borderColor=UIColor.systemBlue.cgColor;alwaysBounceHorizontal=true;alwaysBounceVertical=true}
    required init?(coder:NSCoder){fatalError()}
    func viewForZooming(in scrollView:UIScrollView)->UIView?{picture}
    var imageRect:CGRect {
        guard let size=picture.image?.size,size.width>0,size.height>0 else{return .zero}
        let factor=min(canvas.width/size.width,canvas.height/size.height)
        let w=size.width*factor,h=size.height*factor
        return CGRect(x:(canvas.width-w)/2,y:(canvas.height-h)/2,width:w,height:h)
    }
    func visibleImageRegion()->CGRect {
        let image=imageRect
        guard image.width>0,image.height>0 else{return CGRect(x:0,y:0,width:1,height:1)}
        let visible=convert(bounds,to:picture).intersection(image)
        guard !visible.isNull,!visible.isEmpty else{return CGRect(x:0.45,y:0.45,width:0.1,height:0.1)}
        return CGRect(x:(visible.minX-image.minX)/image.width,y:(visible.minY-image.minY)/image.height,width:visible.width/image.width,height:visible.height/image.height)
    }
    func scrollViewDidScroll(_ scrollView:UIScrollView){onVisible?(visibleImageRegion())}
    func scrollViewDidZoom(_ scrollView:UIScrollView){onVisible?(visibleImageRegion())}
    func layoutPatch(){let r=imageRect;patch.frame=CGRect(x:r.minX+region.minX*r.width,y:r.minY+region.minY*r.height,width:region.width*r.width,height:region.height*r.height)}
    override func layoutSubviews(){
        super.layoutSubviews()
        if bounds.size != canvas {
            let zoom=zoomScale,old=canvas,offset=contentOffset
            setZoomScale(1,animated:false);canvas=bounds.size;picture.frame=CGRect(origin:.zero,size:canvas);contentSize=canvas
            setZoomScale(zoom,animated:false)
            if old.width>0 && old.height>0 {contentOffset=CGPoint(x:offset.x*canvas.width/old.width,y:offset.y*canvas.height/old.height)}
        }
        layoutPatch();onVisible?(visibleImageRegion())
    }
    func show(_ image:UIImage,identity:URL?){
        let changed=self.identity != identity;self.identity=identity
        if changed {setZoomScale(1,animated:false);contentOffset = .zero}
        picture.image=image;layoutPatch();onVisible?(visibleImageRegion())
    }
}
struct ZoomImage:UIViewRepresentable {
    let image:UIImage
    let identity:URL?
    let patch:UIImage?
    let region:CGRect
    let onVisible:(CGRect)->Void
    func makeUIView(context:Context)->PhotoViewport{PhotoViewport(frame:.zero)}
    func updateUIView(_ view:PhotoViewport,context:Context){view.onVisible=onVisible;view.show(image,identity:identity);view.patch.image=patch;view.patch.isHidden=patch == nil;view.region=region;view.layoutPatch()}
}
