import SwiftUI

struct ImageCleanupView: View {
    @State private var model: ImageCleanupViewModel
    @State private var dropTargeted = false
    init(tool: ImageCleanupTool) { _model = State(initialValue: ImageCleanupViewModel(tool: tool)) }
    private var isCutout: Bool { model.tool == .cutout }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: isCutout ? "抠图" : "图片去水印", subtitle: isCutout ? "本机自动提取前景主体，导出透明背景 PNG" : "框选水印区域，通过周边或干净背景取样修补")
                selection
                if let asset = model.asset, let image = model.workingImage {
                    Text("输出尺寸 \(image.width) × \(image.height) px" + (asset.isDownscaled ? " · 原图 \(Int(asset.originalSize.width)) × \(Int(asset.originalSize.height))，为控制内存已等比缩小至最长边 4096 px" : ""))
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                    if !isCutout { repairControls }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("原图").font(.headline)
                            CleanupCanvas(image: asset.image, region: .constant(nil), sampleCenter: .constant(nil), pickingSample: .constant(false))
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text(model.hasResult ? "处理结果 · 可继续编辑" : "框选与预览").font(.headline)
                            CleanupCanvas(image: image, region: $model.region, sampleCenter: $model.sampleCenter, pickingSample: $model.pickingSample,
                                editable: !model.busy, showSample: !isCutout && model.repairMethod == .sample)
                        }
                    }
                    Text(isCutout ? "棋盘格表示透明区域。可在右图框选残留背景后清除；重新自动抠图会从原图开始。" : "在右图拖动红框包住水印。取样修补时点击“设置取样位置”，再点击附近干净背景；绿色框必须完整位于图内，且不与红框重叠。")
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                    actionButtons
                }
                if model.isLoading || model.isProcessing {
                    HStack { ProgressView().controlSize(.small); Text(model.isLoading ? "正在读取图片…" : "正在处理…"); Button("停止") { model.cancel() } }
                }
                CleanupMessages(error: model.errorMessage, status: model.statusMessage)
                Text(isCutout ? "自动抠图依赖主体与背景的区分程度，细发丝、透明物体及遮挡处需要检查。照片在本机处理，不上传。" : "周边修补适合纯色或简单渐变背景；取样修补适合附近有可用纹理的图片。遮挡的原始细节无法保证恢复，请对比检查后保存。原文件保留。")
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
            }
            .padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(AppColors.background)
    }
    private var selection: some View {
        HStack {
            Image(systemName: isCutout ? "person.crop.rectangle.badge.plus" : "eraser").font(.system(size: 28)).foregroundStyle(AppColors.primary)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.sourceURL?.lastPathComponent ?? "选择或拖入一张图片").font(.headline).lineLimit(2)
                Text("JPG / PNG / HEIC / TIFF / BMP · 每次处理一张静态图片").font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
            Button(model.sourceURL == nil ? "选择图片" : "更换图片") { model.chooseImage() }.buttonStyle(.borderedProminent)
            if model.sourceURL != nil { Button("清空") { model.clear() } }
        }
        .padding(20).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropTargeted ? AppColors.primary : .clear, lineWidth: 2))
        .disabled(model.busy)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.busy, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            model.load(url); return true
        } isTargeted: { dropTargeted = $0 }
    }
    private var repairControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("修补方式", selection: $model.repairMethod) {
                ForEach(WatermarkRepairMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 360)
            if model.repairMethod == .sample {
                HStack {
                    Button(model.pickingSample ? "点击右图选择干净背景…" : "设置取样位置") { model.pickingSample.toggle() }.disabled(model.region == nil)
                    Text("边缘羽化 \(Int(model.feather)) px").font(.callout)
                    Slider(value: $model.feather, in: 0...20, step: 1).frame(maxWidth: 180)
                }
            }
        }.disabled(model.busy)
    }
    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack { primaryActions; secondaryActions }
            VStack(alignment: .leading, spacing: 12) { HStack { primaryActions }; HStack { secondaryActions } }
        }
    }
    @ViewBuilder private var primaryActions: some View {
        Button(isCutout ? "自动抠图" : "修补选区") { model.process() }.buttonStyle(.borderedProminent).disabled(!model.canProcess)
        if isCutout { Button("清除框选背景") { model.process(erase: true) }.disabled(model.busy || model.region == nil) }
        Button(isCutout ? "保存透明 PNG…" : "保存 PNG…") { model.save() }.disabled(!model.canSave)
    }
    @ViewBuilder private var secondaryActions: some View {
        Button("撤销上一步") { model.undo() }.disabled(model.busy || model.undoImage == nil)
        Button("恢复原图") { model.restoreOriginal() }.disabled(model.busy || !model.hasResult)
        Button("清除选区") { model.region = nil; model.sampleCenter = nil; model.pickingSample = false }.disabled(model.busy || model.region == nil)
    }
}
