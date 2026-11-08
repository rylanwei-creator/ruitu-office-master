import SwiftUI
import AppKit

struct CollageView: View {
    @State private var model: CollageViewModel
    @State private var tab: CollageControlTab = .layout
    @State private var dropTargeted = false
    init() { _model = State(initialValue: CollageViewModel()) }
    init(model: CollageViewModel) { _model = State(initialValue: model) }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading,spacing: 18) {
                header
                if geometry.size.width >= 880 {
                    HStack(alignment: .top,spacing: 18) {
                        ScrollView { controls.padding(1) }.frame(width: 320)
                        previewPane
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 18) {
                            previewPane.frame(height: 440)
                            controls
                        }
                    }
                }
                footer
            }.padding(24)
        }
        .background(AppColors.background)
        .foregroundStyle(AppColors.textPrimary)
        .dropDestination(for: URL.self) { urls,_ in
            guard !model.busy else { return false }; model.add(urls); return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 16).stroke(AppColors.primary,lineWidth: 3).padding(8).allowsHitTesting(false) } }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                PageHeader(title: "拼图",subtitle: "自由排布照片，也可以拼接成长图")
                Spacer(minLength: 16); historyButtons; exportButton
            }
            VStack(alignment: .leading,spacing: 12) {
                PageHeader(title: "拼图",subtitle: "自由排布照片，也可以拼接成长图")
                HStack { historyButtons; Spacer(); exportButton }
            }
        }
    }
    private var historyButtons: some View {
        HStack(spacing: 6) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("撤销上一步")
                .accessibilityLabel("撤销上一步").disabled(model.busy || model.undoStack.isEmpty)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("重做")
                .accessibilityLabel("重做").disabled(model.busy || model.redoStack.isEmpty)
        }
    }
    private var exportButton: some View {
        Button { model.save() } label: { Label(model.isSaving ? "正在导出…" : "导出图片…",systemImage: "square.and.arrow.down") }
            .buttonStyle(.borderedProminent).tint(AppColors.primary).disabled(!model.canExport)
    }
    private var controls: some View {
        VStack(alignment: .leading,spacing: 18) {
            imageList
            VStack(alignment: .leading,spacing: 16) {
                Picker("拼图方式",selection: $model.settings.mode) {
                    ForEach(CollageMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Picker("调整项目",selection: $tab) {
                    ForEach(CollageControlTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                switch tab {
                case .layout: layoutControls
                case .filter: filterControls
                case .adjust: adjustmentControls
                case .text: textControls
                }
            }.padding(16).background(AppColors.cardBackground,in: RoundedRectangle(cornerRadius: 14))
            outputControls
        }.disabled(model.busy)
    }
    private var imageList: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack {
                Text("图片 · \(model.photos.count)/\(CollageService.maximumPhotos)").font(.headline)
                Spacer()
                Button { model.chooseImages() } label: { Image(systemName: "plus") }.help("添加图片").accessibilityLabel("添加图片")
                Button("清空") { model.clear() }.disabled(model.photos.isEmpty)
            }
            if model.photos.isEmpty {
                Button { model.chooseImages() } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 30))
                        Text("选择图片，或拖入这里").font(.callout)
                        Text("JPG / PNG / HEIC / TIFF / BMP").font(.caption).foregroundStyle(AppColors.textSecondary)
                    }.frame(maxWidth: .infinity).padding(.vertical,24)
                }.buttonStyle(.plain).foregroundStyle(AppColors.primary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(model.photos.enumerated()),id: \.element.id) { index,photo in
                        photoRow(photo,index: index)
                    }
                }
                Text("按列表顺序排布。选中图片可调整裁切位置。")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            if model.isLoading { ProgressView("正在读取图片…").controlSize(.small) }
        }.padding(16).background(AppColors.cardBackground,in: RoundedRectangle(cornerRadius: 14))
    }
    private func photoRow(_ photo: CollagePhoto,index: Int) -> some View {
        HStack(spacing: 8) {
            Button { model.selectedID = photo.id } label: {
                HStack(spacing: 8) {
                    Image(decorative: photo.thumbnail,scale: 1).resizable().scaledToFill()
                        .frame(width: 36,height: 36).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading,spacing: 3) {
                        Text("\(index+1). \(photo.url.lastPathComponent)").font(.caption).lineLimit(1).truncationMode(.middle)
                        Text("\(Int(photo.size.width)) × \(Int(photo.size.height))").font(.caption2).foregroundStyle(AppColors.textSecondary)
                    }.frame(maxWidth: .infinity,alignment: .leading)
                }
            }.buttonStyle(.plain)
            VStack(spacing: 1) {
                Button { model.move(photo.id,by: -1) } label: { Image(systemName: "chevron.up").font(.system(size: 9)) }.disabled(index == 0).help("向前移动")
                Button { model.move(photo.id,by: 1) } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }.disabled(index == model.photos.count-1).help("向后移动")
            }.buttonStyle(.plain)
            Button { model.remove(photo.id) } label: { Image(systemName: "xmark.circle").foregroundStyle(AppColors.textSecondary) }
                .buttonStyle(.plain).help("移除这张图片").accessibilityLabel("移除 \(photo.url.lastPathComponent)")
        }
        .padding(6)
        .background(model.selectedID == photo.id ? AppColors.primary.opacity(0.1) : Color.clear,in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var layoutControls: some View {
        if model.settings.mode == .grid {
            Text("画布比例").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 6),count: 4),spacing: 6) {
                ForEach(CollageRatio.allCases) { ratio in
                    Button { model.settings.ratio = ratio } label: {
                        Text(ratio.rawValue).font(.callout).frame(maxWidth: .infinity).padding(.vertical,7)
                            .background(model.settings.ratio == ratio ? AppColors.primary.opacity(0.14) : AppColors.background,in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).foregroundStyle(model.settings.ratio == ratio ? AppColors.primary : AppColors.textSecondary)
                }
            }
            Text("布局模板").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 8),count: 4),spacing: 8) {
                ForEach(CollageTemplate.allCases) { template in
                    Button { model.settings.template = template } label: {
                        VStack(spacing: 5) {
                            CollageLayoutIcon(template: template,count: max(2,model.photos.count)).frame(width: 44,height: 42)
                            Text(template.rawValue).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                        }.frame(maxWidth: .infinity).padding(.vertical,8)
                            .background(model.settings.template == template ? AppColors.primary.opacity(0.12) : AppColors.background,in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).foregroundStyle(model.settings.template == template ? AppColors.primary : AppColors.textSecondary)
                }
            }
            Toggle("完整显示图片（不裁切）",isOn: $model.settings.fitImages).font(.callout)
            if !model.settings.fitImages,let photo = model.selectedPhoto {
                Divider()
                Text("调整选中图片").font(.headline)
                Text(photo.url.lastPathComponent).font(.caption).lineLimit(1).foregroundStyle(AppColors.textSecondary)
                valueSlider("放大",value: Binding(get: { model.selectedPhoto?.zoom ?? 1 },set: { model.crop(zoom: $0) }),range: 1...3,format: "%.1f×")
                valueSlider("水平",value: Binding(get: { model.selectedPhoto?.panX ?? 0 },set: { model.crop(panX: $0) }),range: -1...1,format: "%.2f")
                valueSlider("垂直",value: Binding(get: { model.selectedPhoto?.panY ?? 0 },set: { model.crop(panY: $0) }),range: -1...1,format: "%.2f")
                Button("重置裁切") { model.crop(zoom: 1,panX: 0,panY: 0) }.font(.caption)
            }
        } else {
            Label(model.settings.mode == .vertical ? "等宽纵向拼接" : "等高横向拼接",
                  systemImage: model.settings.mode == .vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                .font(.headline)
            Text("按列表顺序拼接，保留每张图片的原始比例，不裁切、不拉伸。")
                .font(.callout).foregroundStyle(AppColors.textSecondary)
        }
        Divider()
        valueSlider("图片间距",value: $model.settings.spacing,range: 0...80,format: "%.0f px")
        valueSlider("画布边距",value: $model.settings.margin,range: 0...120,format: "%.0f px")
        Picker("背景",selection: $model.settings.background) {
            ForEach(CollageBackground.allCases) { Text($0.rawValue).tag($0) }
        }
    }
    private var filterControls: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("基础滤镜").font(.headline)
            ForEach(CollageFilter.allCases) { filter in
                Button { model.settings.filter = filter } label: {
                    HStack {
                        Label(filter.rawValue,systemImage: filter == .original ? "photo" : "camera.filters")
                        Spacer()
                        if filter == model.settings.filter { Image(systemName: "checkmark") }
                    }.padding(10).background(AppColors.background,in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Text("统一应用到所有照片，不改变背景与文字颜色。").font(.caption).foregroundStyle(AppColors.textSecondary)
        }
    }
    private var adjustmentControls: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("统一调节照片").font(.headline)
            valueSlider("亮度",value: $model.settings.brightness,range: -0.5...0.5,format: "%+.2f")
            valueSlider("对比度",value: $model.settings.contrast,range: 0.5...1.5,format: "%.2f")
            valueSlider("饱和度",value: $model.settings.saturation,range: 0...2,format: "%.2f")
            Button("重置滤镜与调节") { model.resetAdjustments() }
        }
    }
    private var textControls: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("添加一句话").font(.headline)
            TextField("例如：把今天拼在一起",text: $model.settings.caption)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.settings.caption) { _,text in
                    if text.count > 80 { model.settings.caption = String(text.prefix(80)) }
                }
            Text("最多 80 字，长文字会自动缩小。").font(.caption).foregroundStyle(AppColors.textSecondary)
            Toggle("文字置于顶部",isOn: $model.settings.captionAtTop)
            valueSlider("文字大小",value: $model.settings.captionSize,range: 24...120,format: "%.0f px")
            Button("清除文字") { model.settings.caption = "" }
        }
    }
    private var outputControls: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("输出设置").font(.headline)
            Picker(model.settings.mode == .grid ? "画布宽度" : (model.settings.mode == .vertical ? "图片等宽" : "图片等高"),selection: $model.settings.resolution) {
                Text("1200 px").tag(1200.0); Text("1800 px").tag(1800.0); Text("2400 px").tag(2400.0); Text("3600 px").tag(3600.0)
            }
            Picker("格式",selection: $model.settings.format) {
                ForEach(CollageFormat.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if model.settings.format == .jpeg {
                valueSlider("JPG 质量",value: $model.settings.jpegQuality,range: 0.5...1,format: "%.2f")
                if model.settings.background == .transparent { Text("JPG 不支持透明区域，将填充白色。").font(.caption).foregroundStyle(AppColors.textSecondary) }
            }
            Text("长图超出 2400 万像素或单边 16384 px 时整体等比缩小，最终尺寸显示在预览上方。")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
        }.padding(16).background(AppColors.cardBackground,in: RoundedRectangle(cornerRadius: 14))
    }
    private func valueSlider(_ title: String,value: Binding<Double>,range: ClosedRange<Double>,format: String) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format,value.wrappedValue)).monospacedDigit().foregroundStyle(AppColors.textSecondary)
            }.font(.caption)
            Slider(value: value,in: range)
        }
    }
    private var previewPane: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack {
                Text("实时预览").font(.headline)
                Spacer()
                if let geometry = model.geometry {
                    Text("\(Int(geometry.size.width)) × \(Int(geometry.size.height)) px\(geometry.reduced ? " · 已等比缩小" : "")")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                if model.isRendering { ProgressView().controlSize(.small) }
            }
            GeometryReader { space in
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(AppColors.sidebarBackground.opacity(0.65))
                    if let image = model.preview {
                        ScrollView([.vertical,.horizontal]) {
                            let size = displayedSize(CGSize(width: image.width,height: image.height),in: space.size)
                            Image(decorative: image,scale: 1).resizable().interpolation(.high)
                                .frame(width: size.width,height: size.height)
                                .background { CollageCheckerboard() }
                                .shadow(color: .black.opacity(0.10),radius: 10,y: 4)
                                .padding(20)
                                .frame(minWidth: max(0,space.size.width),minHeight: max(0,space.size.height))
                        }
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "square.grid.2x2").font(.system(size: 44,weight: .light)).foregroundStyle(AppColors.primary)
                            Text(model.photos.isEmpty ? "把照片拼成新的故事" : "正在生成预览").font(.title3.weight(.medium))
                            Text(model.photos.isEmpty ? "添加照片后，在这里查看排版效果" : (model.previewError ?? "处理在本机进行"))
                                .font(.callout).foregroundStyle(AppColors.textSecondary).multilineTextAlignment(.center)
                            if model.photos.isEmpty { Button("选择图片") { model.chooseImages() }.buttonStyle(.borderedProminent).tint(AppColors.primary) }
                        }.padding(24)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(model.settings.mode == .grid ? "照片按导入顺序填入布局；左侧选中照片可微调裁切。" : "长图预览可滚动查看；排列顺序与左侧图片列表一致。")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
        }.padding(16).background(AppColors.cardBackground,in: RoundedRectangle(cornerRadius: 14))
    }
    private func displayedSize(_ size: CGSize,in available: CGSize) -> CGSize {
        let w = max(120,available.width-40), h = max(120,available.height-40)
        let scale: CGFloat
        switch model.settings.mode {
        case .grid: scale = min(w/size.width,h/size.height)
        case .vertical: scale = min(w/size.width,1)
        case .horizontal: scale = min(h/size.height,1)
        }
        return CGSize(width: size.width*scale,height: size.height*scale)
    }
    private var footer: some View {
        VStack(alignment: .leading,spacing: 7) {
            if model.isSaving {
                HStack {
                    ProgressView(value: model.progress).frame(maxWidth: 180)
                    Text("正在导出 \(Int(model.progress*100))%").font(.caption)
                    Button("停止") { model.cancelExport() }.controlSize(.small)
                }
            }
            if let error = model.errorMessage ?? model.previewError {
                Label(error,systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(AppColors.error).textSelection(.enabled).lineLimit(3).help(error)
            }
            if let status = model.statusMessage {
                HStack {
                    Text(status).font(.callout).foregroundStyle(AppColors.success).lineLimit(2)
                    if let url = model.savedURL {
                        Button("打开图片") { NSWorkspace.shared.open(url) }
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
            Text("所有图片在本机处理 · 原图保留").font(.caption).foregroundStyle(AppColors.textSecondary)
        }
    }
}
private enum CollageControlTab: String,CaseIterable,Identifiable {
    case layout = "布局", filter = "滤镜", adjust = "调节", text = "文字"
    var id: Self { self }
}
private struct CollageLayoutIcon: View {
    let template: CollageTemplate
    let count: Int
    var body: some View {
        GeometryReader { geometry in
            let cells = template.cells(count: count)
            ForEach(Array(cells.enumerated()),id: \.offset) { _,cell in
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(lineWidth: 1.3)
                    .frame(width: max(1,cell.width*geometry.size.width-2),height: max(1,cell.height*geometry.size.height-2))
                    .position(x: cell.midX*geometry.size.width,y: cell.midY*geometry.size.height)
            }
        }
    }
}
private struct CollageCheckerboard: View {
    var body: some View {
        Canvas { context,size in
            context.fill(Path(CGRect(origin: .zero,size: size)),with: .color(.white))
            for y in stride(from: 0, to: Int(size.height),by: 12) {
                for x in stride(from: 0,to: Int(size.width),by: 12) where (x/12+y/12).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x,y: y,width: 12,height: 12)),with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}
