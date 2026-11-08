import SwiftUI
import AppKit

struct RitoToolParameterEditor: View {
    let plan: RToolAITaskPlan
    let originalURL: URL?
    let save: ([String:String],[RitoToolStage],Bool,String,[UUID],RitoLocalToolOptions) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var parameters: [String:String]
    @State private var stages: [RitoToolStage]
    @State private var password: String
    @State private var order: [UUID]
    @State private var localOptions: RitoLocalToolOptions
    @State private var errorMessage: String?
    @State private var pdfPreview = PDFSplitPreviewViewModel()
    @State private var image: CGImage?
    @State private var imageError: String?
    @State private var region: CleanupRegion?
    @State private var sampleCenter: CGPoint?
    @State private var pickingSample = false
    @State private var selectedRegion = false
    init(plan: RToolAITaskPlan, originalURL: URL?, password: String, localOptions: RitoLocalToolOptions,
         save: @escaping ([String:String],[RitoToolStage],Bool,String,[UUID],RitoLocalToolOptions) throws -> Void) {
        self.plan = plan; self.originalURL = originalURL; self.save = save
        var initial = plan.liveCall?.parameters ?? [:]
        if let call = plan.liveCall {
            initial = (try? ToolRegistry.lookup(call.operation).values(initial, allowMissing:true)) ?? initial
            if call.operation == .watermark_remove, let suggested = try? TaskEngine.cleanupRegion(initial) {
                _region = State(initialValue: suggested)
                _selectedRegion = State(initialValue: call.regionConfirmed == true)
                if let x = Double(initial["sampleX"] ?? ""), let y = Double(initial["sampleY"] ?? "") {
                    _sampleCenter = State(initialValue:CGPoint(x:x,y:y))
                }
            }
        }
        if plan.liveCall?.operation == .pdf_split {
            initial["ranges"] = PDFSplitSelection.editableText(initial["ranges"])
        }
        _parameters = State(initialValue:initial)
        _stages = State(initialValue:plan.liveCall?.following ?? [])
        _password = State(initialValue:password)
        _order = State(initialValue:plan.liveCall?.attachmentIDs ?? [])
        _localOptions = State(initialValue:localOptions)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(plan.title + " · 设置参数").font(.title2.bold())
            Text("已填入对话中的参数；未指定的项目使用工具默认值。").font(.caption)
            Text("修改后必须重新生成预览并确认；不会自动执行。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                if let call = plan.liveCall {
                    if order.count > 1 { orderFields(call.operation) }
                    if call.operation == .image_compress { compressionPresets }
                    if call.operation == .pdf_split {
                        RitoPDFSplitParameterView(sourceURL:originalURL,preview:pdfPreview,
                            rangesText:Binding(get:{ parameters["ranges"] ?? "" },set:{ parameters["ranges"] = $0 }))
                    } else {
                        parameterFields(call.operation,values:$parameters)
                    }
                    if [.organize_copy,.organize_move].contains(call.operation) { exclusionFields }
                    if call.operation == .collage, parameters["mode"] == CollageMode.grid.rawValue,
                       parameters["fitImages"] != "true" { collageCropFields }
                    ForEach(stages.indices,id:\.self) { index in
                        Text("步骤\(index + 2)：" + ToolRegistry.lookup(stages[index].operation).name).font(.headline).padding(.top,12)
                        parameterFields(stages[index].operation,values:Binding(get:{ stages[index].parameters ?? [:] },set:{ stages[index].parameters = $0 }))
                    }
                    if call.operation == .pdf_encrypt {
                        SecureField("打开PDF的密码（只在本机使用）",text:$password)
                        SecureField("权限密码（可选）",text:$localOptions.ownerPassword)
                        Text("密码不发送给AI、不保存到聊天记录。重新打开任务需重新设置。").font(.caption2).foregroundStyle(.secondary)
                    }
                    if call.operation == .watermark_remove {
                        if let image {
                            CleanupCanvas(image:image,region:$region,sampleCenter:$sampleCenter,pickingSample:$pickingSample,editable:true,showSample:parameters["method"] == "sample")
                            HStack { Button("重新框选") { region = nil; selectedRegion = false }; Button("设置取样区域") { pickingSample = true }.disabled(region == nil) }
                            if region != nil, !selectedRegion { Button("确认使用此选区") { selectedRegion = true } }
                            Text("请在原图框选水印区域。取样方式还需选择不重叠的干净背景。").font(.caption)
                        } else { Text(imageError ?? "正在读取本机图片…").font(.caption) }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存参数") {
                guard canSave else { return }
                if let region, selectedRegion {
                    parameters["x"] = String(Double(region.rect.minX)); parameters["y"] = String(Double(region.rect.minY))
                    parameters["width"] = String(Double(region.rect.width)); parameters["height"] = String(Double(region.rect.height))
                    if let sampleCenter { parameters["sampleX"] = String(Double(sampleCenter.x)); parameters["sampleY"] = String(Double(sampleCenter.y)) }
                }
                do {
                    try save(parameters,stages,selectedRegion,password,order,localOptions)
                    password = ""; localOptions.ownerPassword = ""; dismiss()
                } catch { errorMessage = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(!canSave) }
        }.padding(20).frame(width:640,height:600)
            .task {
                guard plan.liveCall?.operation == .watermark_remove, let originalURL else { return }
                do { image = try await Task.detached { try ImageCleanupService.prepare(originalURL).image }.value }
                catch { imageError = error.localizedDescription }
            }
            .onChange(of:region) { _, value in if value != nil { selectedRegion = true } }
    }
    private var compressionPresets: some View {
        HStack {
            Text("压缩预设").font(.headline)
            ForEach([CompressionLevel.light,.balanced,.strong], id:\.self) { level in
                Button(level.rawValue) {
                    parameters["minimumKB"] = ""; parameters["maximumKB"] = ""
                    parameters["reduction"] = String(level.reductionFraction)
                    parameters["qualityFloor"] = String(level.qualityValue)
                }
            }
        }.padding(.bottom,6)
    }
    private func name(for id: UUID) -> String {
        guard let i = plan.liveCall?.attachmentIDs.firstIndex(of:id), plan.sourceNames.indices.contains(i) else { return "附件" }
        return plan.sourceNames[i]
    }
    private func orderFields(_ operation: RitoToolCall.Operation) -> some View {
        VStack(alignment:.leading, spacing:6) {
            Text("附件顺序").font(.headline)
            ForEach(Array(order.enumerated()),id:\.element) { index,id in
                HStack {
                    Text("\(index+1). " + name(for:id)).lineLimit(1)
                    Spacer()
                    if operation != .pdf_image_watermark {
                        Button { order.swapAt(index,index-1) } label: { Image(systemName:"arrow.up") }
                            .disabled(index == 0).accessibilityLabel("上移 " + name(for:id))
                        Button { order.swapAt(index,index+1) } label: { Image(systemName:"arrow.down") }
                            .disabled(index == order.count-1).accessibilityLabel("下移 " + name(for:id))
                    }
                }
            }
        }.padding(.bottom,8)
    }
    private var exclusionFields: some View {
        VStack(alignment:.leading,spacing:6) {
            Button("选择排除文件夹…") {
                Task { @MainActor in
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    if await FileDialogs.response(to:panel) == .OK {
                        for url in panel.urls where !localOptions.exclusions.contains(url) { localOptions.exclusions.append(url) }
                    }
                }
            }
            ForEach(localOptions.exclusions,id:\.self) { url in
                HStack {
                    Text(url.path).lineLimit(1)
                    Spacer()
                    Button("移除") { localOptions.exclusions.removeAll { $0 == url } }
                }
            }
        }
    }
    private var collageCropFields: some View {
        DisclosureGroup("逐张调整拼图构图") {
            ForEach(order,id:\.self) { id in
                let crop = Binding(get:{ localOptions.collageCrops[id] ?? .init() },set:{ localOptions.collageCrops[id] = $0 })
                VStack(alignment:.leading) {
                    Text(name(for:id)).font(.caption.bold())
                    Slider(value:crop.zoom,in:1...3) { Text("放大") }
                    Slider(value:crop.x,in:-1...1) { Text("水平位置") }
                    Slider(value:crop.y,in:-1...1) { Text("垂直位置") }
                    Button("重置构图") { localOptions.collageCrops[id] = nil }
                }.padding(.vertical,5)
            }
        }
    }
    private var canSave: Bool {
        guard plan.liveCall?.operation == .pdf_split else { return true }
        return pdfPreview.isReady && pdfPreview.sourceIsCurrent
            && PDFSplitSelection(text:parameters["ranges"] ?? "",pageCount:pdfPreview.pageCount).isValid
    }
    @ViewBuilder private func parameterFields(_ operation: RitoToolCall.Operation, values: Binding<[String:String]>) -> some View {
        let tool = ToolRegistry.lookup(operation)
        let effective = (try? tool.values(values.wrappedValue,allowMissing:true)) ?? values.wrappedValue
        let isPhoto = operation == .id_photo || operation == .id_photo_print
        ForEach(tool.parameters.filter { tool.shows($0.key, values:effective) && !(isPhoto && ["red","green","blue"].contains($0.key)) }) { parameter in
            let binding = Binding<String>(get:{
                (parameter.kind == .choice ? effective[parameter.key] : values.wrappedValue[parameter.key]) ?? parameter.defaultValue
            },set:{ values.wrappedValue[parameter.key] = $0 })
            HStack(alignment:.top) {
                Text(parameter.label).frame(width:150,alignment:.leading)
                if parameter.choices == ["true","false"] {
                    Toggle(parameter.label,isOn:Binding(get:{ binding.wrappedValue == "true" },set:{ binding.wrappedValue = $0 ? "true" : "false" })).labelsHidden()
                } else if parameter.kind == .choice {
                    Picker(parameter.label,selection:binding) {
                        ForEach(parameter.choices,id:\.self) { value in Text(parameter.display(value)).tag(value) }
                    }.labelsHidden()
                } else { TextField(parameter.label,text:binding,prompt:Text(parameter.defaultValue)).labelsHidden().textFieldStyle(.roundedBorder) }
            }.padding(.vertical,4)
        }
        if isPhoto, effective["background"] == "custom" {
            ColorPicker("自选底色",selection:Binding(get:{
                Color(red:Double(effective["red"] ?? "") ?? 1,green:Double(effective["green"] ?? "") ?? 1,blue:Double(effective["blue"] ?? "") ?? 1)
            },set:{ color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                values.wrappedValue["red"] = String(Double(rgb.redComponent))
                values.wrappedValue["green"] = String(Double(rgb.greenComponent))
                values.wrappedValue["blue"] = String(Double(rgb.blueComponent))
            }),supportsOpacity:false)
        }
    }
}
