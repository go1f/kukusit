import Foundation
import SwiftUI
import PostureCore

@MainActor
final class OralSampleStore: ObservableObject {
    @Published private(set) var libraries: [String: OralPoseExamples] = [:]
    @Published private(set) var progress: Double?
    @Published private(set) var message = "先录入自然放松，再录入需要提醒的动作外观。"
    @Published var selectedAction: OralPoseAction = .jawTension
    @Published var sampleLabel = "紧咬牙示范"
    private var url: URL?
    private let persistent: Bool
    private var storageReady = false
    private struct Archive: Codable { var schemaVersion = 1; var libraries: [String: OralPoseExamples] }
    private struct Recording {
        var context: ViewingContext
        var signature: String
        var action: OralPoseAction?
        var label: String
        var start: Double
        var samples: [FacialFeatures] = []
        var lastTimestamp: Double?
        var usableSeconds = 0.0
        var bestSamples: [FacialFeatures] = []
        var bestSeconds = 0.0
    }
    private var recording: Recording?
    var isRecording: Bool { recording != nil }
    init(persistent: Bool, archiveURL: URL? = nil) {
        self.persistent = persistent
        guard persistent else { return }
        do {
            let root = try archiveURL?.deletingLastPathComponent() ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("PostureDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            url = archiveURL ?? root.appendingPathComponent("oral-examples-v1.json")
            if let url, FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576 else { throw StoreError.tooLarge }
                let saved = try JSONDecoder().decode(Archive.self, from: data)
                guard saved.schemaVersion == 1 else { throw StoreError.invalidVersion }
                libraries = saved.libraries
            }
            storageReady = true
        } catch { message = "动作示范读取失败：\(error.localizedDescription)" }
    }
    func library(context: ViewingContext, signature: String?) -> OralPoseExamples? {
        guard let signature, let library = libraries[context.rawValue], library.matchesFace(signature) else { return nil }
        return library
    }
    func begin(context: ViewingContext, signature: String, action: OralPoseAction?, label: String,
               at now: Double = ProcessInfo.processInfo.systemUptime) {
        recording = Recording(context: context, signature: signature, action: action,
            label: String(label.prefix(60)), start: now)
        progress = 0
        message = action == nil ? "自然放松、不讲话，采集 3 秒。" : "采集你的动作外观 3 秒，提醒暂缓。"
    }
    func consume(_ observation: Observation, metrics: Metrics) {
        guard var r = recording, observation.cameraSignature == r.signature,
              observation.timestamp >= r.start, observation.timestamp <= r.start + 3,
              r.lastTimestamp.map({ observation.timestamp > $0 }) ?? true else { return }
        let valid = metrics.faceUsable && observation.faceCount == 1 && observation.bodyCount <= 1
            && abs(metrics.yaw ?? 90) <= 15 && abs(metrics.pitch ?? 90) <= 30
        if valid, let features = observation.oral?.features, features.isFinite {
            if let last = r.lastTimestamp, observation.timestamp - last <= 0.5 {
                r.usableSeconds += observation.timestamp - last
            } else {
                r.samples = []; r.usableSeconds = 0
            }
            r.samples.append(features)
            r.lastTimestamp = observation.timestamp
            if r.usableSeconds > r.bestSeconds { r.bestSeconds = r.usableSeconds; r.bestSamples = r.samples }
        } else { r.lastTimestamp = nil; r.samples = []; r.usableSeconds = 0 }
        recording = r
    }
    @discardableResult func tick(at now: Double) -> Bool {
        guard let r = recording else { return false }
        progress = min(1, max(0, (now - r.start) / 3))
        guard now >= r.start + 3 else { return false }
        defer { recording = nil; progress = nil }
        guard r.bestSamples.count >= 6, r.bestSeconds + 0.000001 >= 2 else {
            message = "清晰口部观察不足 2 秒，未保存；请近正对镜头再采集。"; return true
        }
        var library = libraries[r.context.rawValue].flatMap { $0.matchesFace(r.signature) ? $0 : nil }
            ?? OralPoseExamples(cameraSignature: r.signature)
        if let action = r.action {
            guard library.hasNeutralReference else { message = "请先采集自然放松参考。"; return true }
            let label = r.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let example = OralPoseExample(action: action, label: label.isEmpty ? action.title : label, samples: r.bestSamples)
            if let index = library.examples.firstIndex(where: { $0.action == action && $0.label == example.label }) {
                library.examples[index] = example
            } else { library.examples.append(example) }
            library.examples = Array(library.examples.suffix(20))
        } else { library.neutral = r.bestSamples }
        let previous = libraries
        libraries[r.context.rawValue] = library
        do {
            try save()
            message = r.action == nil ? "自然放松参考已保存。" : "已保存“\(r.label)”外观示范；匹配相近外观时才提醒。"
        } catch { libraries = previous; message = "保存示范失败：\(error.localizedDescription)" }
        return true
    }
    func cancel() {
        guard recording != nil else { return }
        recording = nil; progress = nil; message = "采样已取消，保留已保存的示范。"
    }
    func remove(context: ViewingContext) {
        let previous = libraries
        libraries.removeValue(forKey: context.rawValue)
        do { try save(); message = "该观看情境的动作示范已清除。" }
        catch { libraries = previous; message = "清除失败：\(error.localizedDescription)" }
    }
    private func save() throws {
        guard persistent else { return }
        guard storageReady, let url else { throw StoreError.storageUnavailable }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Archive(libraries: libraries)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private enum StoreError: Error { case tooLarge, invalidVersion, storageUnavailable }
}

struct OralSampleSettingsView: View {
    @ObservedObject var model: DiagnosticModel
    @ObservedObject var store: OralSampleStore
    private var library: OralPoseExamples? {
        store.library(context: model.selectedContext, signature: model.frame?.observation.cameraSignature)
    }
    var body: some View {
        Section("个人动作示范") {
            Toggle("匹配我的口部动作示范", isOn: $model.settings.oralPoseMonitoring)
            Text("比较你示范的紧咬、咬唇、歪嘴或舌部动作外观。相似外观提示不能确认咬合力量或具体牙齿接触。")
                .font(.caption).foregroundStyle(.secondary)
            if let progress = store.progress {
                ProgressView(value: progress)
                Button("取消采样") { model.cancelOralRecording() }
            } else {
                HStack {
                    Button(library?.hasNeutralReference == true ? "重录自然放松 3 秒" : "录入自然放松 3 秒") { model.beginOralRecording(action: nil) }
                        .disabled(!model.canRecordOralPose)
                    Text(library?.hasNeutralReference == true ? "自然参考已就绪" : "先录自然参考").font(.caption).foregroundStyle(.secondary)
                }
                Picker("动作类别", selection: $store.selectedAction) {
                    ForEach(OralPoseAction.allCases) { Text($0.title).tag($0) }
                }.onChange(of: store.selectedAction) { _, action in store.sampleLabel = action.title }
                TextField("示范名称", text: $store.sampleLabel)
                Button("采集该动作 3 秒") { model.beginOralRecording(action: store.selectedAction) }
                    .disabled(!model.canRecordOralPose || library?.hasNeutralReference != true)
                if let library, !library.examples.isEmpty {
                    Text("已保存：" + library.examples.map(\.label).joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("清除当前情境的动作示范") { model.removeOralExamples() }
                }
            }
            Text(store.message).font(.caption).foregroundStyle(.secondary)
            Text("仅保存本机几何特征，不保存照片。新电脑需要重新采样。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
