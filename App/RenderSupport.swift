import UIKit
import BackgroundTasks
import UserNotifications

struct RenderEstimate {
    private var started: TimeInterval = 0
    private var completed = 0
    var secondsPerUnit: Double?
    mutating func reset(now: TimeInterval) { started=now;completed=0;secondsPerUnit=nil }
    mutating func update(done:Int,now:TimeInterval) {
        guard done>completed else{return}
        let sample=(now-started)/Double(done-completed)
        if sample>0 {secondsPerUnit=secondsPerUnit.map{$0*0.7+sample*0.3} ?? sample}
        started=now;completed=done
    }
    func remaining(_ units:Int)->Double? {secondsPerUnit.map{max(0,$0*Double(units-completed))}}
    static func text(_ seconds:Double)->String {
        seconds<60 ? "约 \(max(1,Int(ceil(seconds/5))*5)) 秒" : "约 \(Int(ceil(seconds/60))) 分钟"
    }
}

@MainActor final class RenderLifetime: NSObject, UNUserNotificationCenterDelegate {
    static let shared=RenderLifetime()
    private var launchWork:(()->Void)?
    private var task: BGTask?
    private var identifier:String?
    private var assertion:UIBackgroundTaskIdentifier = .invalid
    private var cancelWork:(()->Void)?
    func requestNotifications() {
        let center=UNUserNotificationCenter.current();center.delegate=self
        center.requestAuthorization(options:[.alert,.sound]) {_,_ in}
    }
    func start(smoke:Bool,work:@escaping ()->Void,cancel:@escaping ()->Void)->String {
        cancelWork=cancel
        if smoke {work();return "测试中"}
        if #available(iOS 26.0,*) {
            // Sideload signing can change the bundle ID; use the permitted plist namespace.
            let patterns=Bundle.main.object(forInfoDictionaryKey:"BGTaskSchedulerPermittedIdentifiers") as? [String]
            let pattern=patterns?.first(where:{$0.hasSuffix(".render.*")}) ?? "io.alpha1m2.photodenoise.render.*"
            let id=String(pattern.dropLast())+UUID().uuidString
            identifier=id;launchWork=work
            let registered=BGTaskScheduler.shared.register(forTaskWithIdentifier:id,using:nil) { [weak self] task in
                Task{@MainActor in
                    guard let self,self.identifier==id else{task.setTaskCompleted(success:false);return}
                    self.task=task;task.expirationHandler={Task{@MainActor in self.expire()}}
                    if let continued=task as? BGContinuedProcessingTask {continued.progress.totalUnitCount=1000}
                    let launch=self.launchWork;self.launchWork=nil;launch?()
                }
            }
            if registered {
                let request=BGContinuedProcessingTaskRequest(identifier:id,title:"净影 · 整图降噪",subtitle:"正在处理")
                request.strategy = .fail
                do {try BGTaskScheduler.shared.submit(request);return "可切到后台"}
                catch {BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:id);identifier=nil;launchWork=nil}
            }
        }
        assertion=UIApplication.shared.beginBackgroundTask(withName:"净影渲染") { [weak self] in
            Task{@MainActor in self?.expire()}
        }
        work();return "后台额度有限 · 建议保持前台"
    }
    private func expire() {
        let cancel=cancelWork
        finish(success:false,notify:false)
        cancel?()
    }
    func update(_ fraction:Double,subtitle:String) {
        if #available(iOS 26.0,*),let task=task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount=Int64(min(0.99,fraction)*1000)
            task.updateTitle("净影 · 整图降噪",subtitle:subtitle)
        }
    }
    func finish(success:Bool,notify:Bool) {
        if success && notify {
            let content=UNMutableNotificationContent();content.title="净影 · 渲染完成";content.body="整张照片已处理，可打开净影导出。";content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:UUID().uuidString,content:content,trigger:UNTimeIntervalNotificationTrigger(timeInterval:1,repeats:false)))
        }
        if #available(iOS 26.0,*),let task=task as? BGContinuedProcessingTask,success {task.progress.completedUnitCount=1000}
        task?.setTaskCompleted(success:success);task=nil
        if let identifier {BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:identifier)};identifier=nil
        if assertion != .invalid {UIApplication.shared.endBackgroundTask(assertion);assertion = .invalid}
        cancelWork=nil;launchWork=nil
    }
    nonisolated func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification) async -> UNNotificationPresentationOptions {[.banner,.sound]}
}
