import SwiftUI
import AppKit

struct IDPhotoView: View {
    @State private var model = IDPhotoViewModel()
    @State private var dropTargeted = false
    @State private var dragStart: IDPhotoCrop?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "证件照", subtitle: "本机人像换底 · 等比裁切 · 单张导出与打印排版")
                selection
                if let asset = model.asset {
                    configuration
                        .disabled(model.isLoading || model.isExporting)
                    HStack(alignment: .top, spacing: 24) {
                        editor(asset: asset)
                        preview
                    }
                    .disabled(model.isExporting)
                    exportSection
                }
                if model.isLoading {
                    HStack { ProgressView().controlSize(.small); Text("正在读取照片并检测人脸…"); Button("停止") { model.cancel() } }
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.error).textSelection(.enabled)
                }
                if let message = model.saveMessage {
                    Label(message, systemImage: "info.circle").foregroundStyle(AppColors.textSecondary).textSelection(.enabled)
                }
                Text("尺寸预设只是常用快捷选项。提交前请核对接收方对尺寸、底色、头部比例及文件大小的具体要求；换底后需检查发丝、眼镜与衣服边缘。")
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
                Label("照片与人像分割均在本机处理，不上传照片，不接入大模型服务。", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            .padding(32)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AppColors.background)
        .onChange(of: model.settings) { _, _ in model.refresh() }
    }
    private var selection: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle").font(.system(size: 32)).foregroundStyle(AppColors.primary)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.sourceURL?.lastPathComponent ?? "拖入单张照片，或选择图片").font(.headline).lineLimit(2)
                Text("JPG / PNG / HEIC / TIFF / BMP · 建议正面、无遮挡、完整头肩")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
            Button(model.sourceURL == nil ? "选择图片" : "更换照片") { model.selectPhoto() }.buttonStyle(.borderedProminent)
            if model.sourceURL != nil { Button("清空") { model.clear() } }
        }
        .padding(20).frame(maxWidth: .infinity)
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropTargeted ? AppColors.primary : .clear, lineWidth: 2))
        .disabled(model.isExporting)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isExporting else { return false }
            guard urls.count == 1, let url = urls.first, url.isFileURL else {
                model.errorMessage = "证件照每次处理一张本地图片，请只拖入一个文件。"; return false
            }
            model.load(url); return true
        } isTargeted: { dropTargeted = $0 }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("1. 规格与底色").font(.title3.bold())
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("照片规格", selection: $model.settings.preset) {
                        ForEach(IDPhotoPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if model.settings.preset == .custom {
                        HStack {
                            numberField("宽 mm", value: $model.settings.widthMM)
                            numberField("高 mm", value: $model.settings.heightMM)
                        }
                    }
                    Picker("分辨率", selection: $model.settings.dpi) {
                        ForEach([150, 300, 600], id: \.self) { Text("\($0) DPI").tag($0) }
                    }
                    if (try? model.settings.validate()) != nil {
                        Text("导出 \(Int(model.settings.pixelSize.width)) × \(Int(model.settings.pixelSize.height)) 像素")
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    Picker("背景底色", selection: $model.settings.background) {
                        ForEach(IDPhotoBackground.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if model.settings.background == .custom {
                        ColorPicker("自选底色", selection: Binding(get: {
                            Color(red: model.settings.red, green: model.settings.green, blue: model.settings.blue)
                        }, set: { color in
                            if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                                model.settings.red = rgb.redComponent; model.settings.green = rgb.greenComponent; model.settings.blue = rgb.blueComponent
                            }
                        }), supportsOpacity: false)
                    }
                    Text("换底使用系统本地人像分割。复杂背景可能残留边缘，请检查右侧最终预览。")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                    Text(model.faceMessage).font(.caption).foregroundStyle(AppColors.textSecondary)
                }.frame(maxWidth: .infinity)
            }
        }.padding(20).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }
    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(AppColors.textSecondary)
            TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder)
        }
    }
    private func editor(asset: IDPhotoAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. 调整构图").font(.title3.bold())
            Text("拖动照片调整位置，滑块调整缩放。参考线不代表审核标准。")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
            GeometryReader { geometry in
                let size = asset.size
                let mm = model.settings.millimeters
                let aspect = mm.width.isFinite && mm.height.isFinite && (10...100).contains(mm.width) && (10...100).contains(mm.height) ? mm.width / mm.height : 25.0 / 35.0
                let rect = model.settings.crop.rect(in: size, aspect: aspect)
                let height = min(geometry.size.height, geometry.size.width / aspect)
                let width = height * aspect
                let scale = width / max(1, rect.width)
                ZStack(alignment: .topLeading) {
                    Color.white
                    if let image = model.editorImage {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high)
                            .frame(width: size.width * scale, height: size.height * scale)
                            .offset(x: -rect.minX * scale, y: -rect.minY * scale)
                    }
                    if model.showGuides {
                        Path { path in
                            for y in [0.16, 0.4, 0.70] {
                                path.move(to: CGPoint(x: 0, y: height * y))
                                path.addLine(to: CGPoint(x: width, y: height * y))
                            }
                            path.move(to: CGPoint(x: width / 2, y: 0))
                            path.addLine(to: CGPoint(x: width / 2, y: height))
                        }.stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading).clipped()
                .overlay(Rectangle().stroke(AppColors.primary, lineWidth: 2))
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { drag in
                    if dragStart == nil { dragStart = model.settings.crop }
                    guard let start = dragStart else { return }
                    let dx = (size.width - rect.width) * scale, dy = (size.height - rect.height) * scale
                    model.settings.crop.x = dx > 0 ? min(1, max(-1, start.x - 2 * drag.translation.width / dx)) : 0
                    model.settings.crop.y = dy > 0 ? min(1, max(-1, start.y - 2 * drag.translation.height / dy)) : 0
                }.onEnded { _ in dragStart = nil })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(height: 330)
            HStack {
                Text("缩放").frame(width: 42, alignment: .leading)
                Slider(value: $model.settings.crop.zoom, in: 1...4)
                Text(String(format: "%.2f×", model.settings.crop.zoom)).monospacedDigit().frame(width: 52)
            }
            HStack { Text("水平").frame(width: 42, alignment: .leading); Slider(value: $model.settings.crop.x, in: -1...1) }
            HStack { Text("垂直").frame(width: 42, alignment: .leading); Slider(value: $model.settings.crop.y, in: -1...1) }
            HStack {
                Button("自动构图") { model.autoFrame() }.disabled(asset.faces.count != 1)
                Button("重置") { model.settings.crop = IDPhotoCrop() }
                Button { model.rotateClockwise() } label: { Label("旋转", systemImage: "rotate.right") }
            }
            Toggle("显示构图参考线", isOn: $model.showGuides).font(.caption)
            if model.resolutionWarning {
                Label("当前裁切区域小于导出像素，会放大；建议使用更清晰原图或减少缩放。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("最终预览").font(.title3.bold())
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(AppColors.cardBackground)
                if let result = model.result, result.settings == model.settings {
                    Image(decorative: result.image, scale: 1).resizable().interpolation(.high).scaledToFit().padding(12)
                } else if model.isRendering {
                    VStack(spacing: 12) { ProgressView(); Text("正在生成实际文件…").font(.caption) }
                } else {
                    Text("调整设置后生成预览").foregroundStyle(AppColors.textSecondary)
                }
            }.frame(height: 330)
            if let result = model.result, result.settings == model.settings {
                Text("实际大小：\(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .binary))（\(result.data.count) 字节）")
                    .font(.callout).monospacedDigit().textSelection(.enabled)
                Text("\(result.image.width) × \(result.image.height) px · \(result.settings.dpi) DPI · \(result.settings.format.rawValue)")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            Button("更新预览") { model.refresh() }.disabled(model.isLoading)
            if model.isRendering { Button("停止生成") { model.cancel() } }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("3. 导出与打印").font(.title3.bold())
            HStack {
                Picker("文件格式", selection: $model.settings.format) {
                    ForEach(IDPhotoFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 180)
                Toggle("限制文件大小", isOn: $model.settings.limitSize).disabled(model.settings.format != .jpeg)
                if model.settings.limitSize && model.settings.format == .jpeg {
                    TextField("KB", value: $model.settings.maximumKB, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("KB")
                }
                Spacer()
                Button("保存单张…") { model.export(printSheet: false) }.buttonStyle(.borderedProminent).disabled(!model.canExport)
            }
            Text("1 KB = 1024 字节。大小上限通过调整 JPG 质量实现，保持像素尺寸；若最低质量仍超限会明确提示，不输出不合要求的文件。")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
            Divider()
            HStack {
                Picker("打印纸张", selection: $model.paper) {
                    ForEach(IDPhotoPaper.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 320)
                Toggle("裁切标记", isOn: $model.cropMarks)
                Spacer()
                Button("保存排版 PDF…") { model.export(printSheet: true) }.disabled(!model.canExport || printCount == 0)
            }
            Text("每页 \(printCount) 张 · 5 mm 页边距 · 2 mm 间距。打印 PDF 时选择“实际大小 / 100%”，关闭适应纸张，保证毫米尺寸。")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
            if model.isExporting { ProgressView("正在保存…").controlSize(.small) }
        }
        .padding(20).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .disabled(model.isExporting)
        .onChange(of: model.settings.format) { _, format in if format == .png { model.settings.limitSize = false } }
    }
    private var printCount: Int { (try? IDPhotoService.layout(photoMM: model.settings.millimeters, paper: model.paper).count) ?? 0 }
}
