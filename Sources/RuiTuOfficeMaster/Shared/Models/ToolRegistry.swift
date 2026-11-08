import Foundation

enum ToolRisk: String, Sendable { case readOnly = "读取文件", newFiles = "生成新文件", changesOriginals = "修改原文件路径" }
enum ToolInput: Sendable, Equatable { case image, pdf, pdfImage, word, video, gif, media, directory, file }
struct ToolParameter: Identifiable, Sendable {
    enum Kind: Sendable, Equatable { case text, number, integer, choice }
    let key: String, label: String, defaultValue: String
    var kind: Kind = .text
    var choices: [String] = []
    var minimum: Double? = nil
    var maximum: Double? = nil
    var required = false
    var id: String { key }
    func display(_ value: String) -> String {
        if key == "reduction", let n = Double(value) { return "减少 " + String(format: "%.1f%%", n * 100) }
        let labels = ["true":"是","false":"否","original":"保留原样","auto":"自动",
            "number":"自动编号","skip":"跳过同名","fit":"等比适应宽高","exact":"自定义宽高","longEdge":"限定最大边长",
            "blue":"蓝色","red":"红色","white":"白色","custom":"自定义","one":"一寸","smallTwo":"小二寸","two":"二寸",
            "prefix":"添加前缀","suffix":"添加后缀","replace":"查找替换","numbering":"序号命名",
            "zh-Hans":"简体中文","zh-Hant":"繁体中文","en-US":"英语","zh-CN":"中文",
            "surrounding":"周边修补","sample":"取样修补","sixInch":"6 寸相纸","a4":"A4",
            "high":"高画质","medium":"均衡","low":"小体积","uhd4K":"4K","fullHD":"1080p","hd":"720p","sd":"480p",
            "jpg":"JPG","png":"PNG","heic":"HEIC","webp":"WebP","h264":"H.264","hevc":"HEVC"]
        if key == "language", labels[value] == nil {
            return Locale.current.localizedString(forIdentifier:value) ?? value
        }
        return kind == .choice ? labels[value] ?? value : value
    }
}
struct RegisteredTool: Identifiable, Sendable {
    let operation: RitoToolCall.Operation
    let name: String, description: String
    let input: ToolInput
    let output: String
    let risk: ToolRisk
    let parameters: [ToolParameter]
    var requiresConfirmation: Bool { true }
    func shows(_ key: String, values: [String:String]) -> Bool {
        if operation == .image_compress || operation == .image_resize {
            if ["width","height"].contains(key) { return values["sizeMode"] != "longEdge" }
            if key == "maxDimension" { return values["sizeMode"] == "longEdge" }
            if key == "reduction" { return (values["maximumKB"] ?? "").isEmpty }
        }
        if operation == .id_photo || operation == .id_photo_print {
            if ["widthMM","heightMM"].contains(key) { return values["preset"] == "custom" }
            if ["red","green","blue"].contains(key) { return values["background"] == "custom" }
            if key == "maximumKB" { return values["format"] != "png" }
        }
        if operation == .file_rename {
            if key == "find" { return values["mode"] == "replace" }
            if ["start","digits"].contains(key) { return values["mode"] == "numbering" }
        }
        if operation == .watermark_remove {
            if ["sampleX","sampleY","feather"].contains(key) { return values["method"] == "sample" }
        }
        if operation == .collage {
            if ["ratio","template"].contains(key) { return values["mode"] == nil || values["mode"] == CollageMode.grid.rawValue }
            if key == "jpegQuality" { return values["format"] == CollageFormat.jpeg.rawValue }
        }
        return true
    }
    func parameterSummary(_ provided: [String:String]) -> [String] {
        let effective = (try? values(provided, allowMissing: true)) ?? provided
        return parameters.filter { shows($0.key, values: effective) }.compactMap { parameter in
            let value = effective[parameter.key] ?? parameter.defaultValue
            if value.isEmpty, !parameter.required { return nil }
            return parameter.label + "：" + (value.isEmpty ? "待设置" : parameter.display(value))
        }
    }
    var id: String { operation.rawValue }
    var symbol: String {
        switch input { case .image, .gif: "photo"; case .pdf, .pdfImage, .word: "doc.richtext"; case .video, .media: "waveform"; case .directory: "folder"; case .file: "pencil" }
    }
    func accepts(_ attachment: RToolAIAttachment) -> Bool {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        if input == .directory { return attachment.isDirectory == true }
        guard attachment.isDirectory != true else { return false }
        switch input {
        case .image: return ToolRegistry.imageExtensions.contains(ext)
        case .pdf: return ext == "pdf"
        case .pdfImage: return ext == "pdf" || ToolRegistry.imageExtensions.contains(ext)
        case .word: return ["doc", "docx"].contains(ext)
        case .video: return ToolRegistry.videoExtensions.contains(ext)
        case .gif: return ext == "gif"
        case .media: return ToolRegistry.videoExtensions.union(ToolRegistry.audioExtensions).contains(ext)
        case .file: return true
        case .directory: return false
        }
    }
    func values(_ provided: [String: String], allowMissing: Bool = false) throws -> [String: String] {
        guard Set(provided.keys).isSubset(of: Set(parameters.map(\.key))) else { throw RitoToolError.invalidPlan }
        var result: [String: String] = [:]
        for parameter in parameters {
            var value = provided[parameter.key] ?? parameter.defaultValue
            if provided[parameter.key] == nil {
                if parameter.key == "sizeMode", !(provided["maxDimension"] ?? "").isEmpty { value = "longEdge" }
                if parameter.key == "preset", provided["widthMM"] != nil || provided["heightMM"] != nil { value = "custom" }
                if parameter.key == "background", provided["red"] != nil || provided["green"] != nil || provided["blue"] != nil { value = "custom" }
            }
            if value.isEmpty, !parameter.defaultValue.isEmpty { value = parameter.defaultValue }
            if parameter.kind == .choice {
                value = parameter.choices.first { $0.caseInsensitiveCompare(value.trimmingCharacters(in:.whitespacesAndNewlines)) == .orderedSame } ?? value
            }
            if value.isEmpty {
                if parameter.required && !allowMissing { throw ToolExecutionError.message("请先设置“" + parameter.label + "”。") }
                result[parameter.key] = value; continue
            }
            guard value.count <= 256, !value.contains("\0") else { throw RitoToolError.invalidPlan }
            switch parameter.kind {
            case .text: break
            case .choice: guard parameter.choices.contains(value) else { throw RitoToolError.invalidPlan }
            case .integer, .number:
                guard let number = Double(value), number.isFinite,
                      parameter.minimum.map({ number >= $0 }) ?? true,
                      parameter.maximum.map({ number <= $0 }) ?? true,
                      parameter.kind != .integer || number.rounded() == number else { throw RitoToolError.invalidPlan }
            }
            result[parameter.key] = value
        }
        if operation == .image_compress, !(result["minimumKB"] ?? "").isEmpty, (result["maximumKB"] ?? "").isEmpty {
            throw ToolExecutionError.message("体积范围需要同时设置最小值与最大值。")
        }
        if operation == .image_compress, let lower = Double(result["minimumKB"] ?? ""), let upper = Double(result["maximumKB"] ?? ""), lower > upper {
            throw ToolExecutionError.message("最小体积不能大于最大体积。")
        }
        if !allowMissing, operation == .image_resize || operation == .image_compress {
            let mode = result["sizeMode"] ?? "fit"
            let dimensionsRequired = operation == .image_resize || mode == "exact"
            if mode != "longEdge", dimensionsRequired, (result["width"] ?? "").isEmpty || (result["height"] ?? "").isEmpty {
                throw ToolExecutionError.message("请设置图片宽度和高度。")
            }
            if mode == "longEdge", (result["maxDimension"] ?? "").isEmpty {
                throw ToolExecutionError.message("请设置图片最大边长。")
            }
        }
        return result
    }
    var parameterSchema: [String:Any] {
        let properties = Dictionary(uniqueKeysWithValues:parameters.map { p -> (String,[String:Any]) in
            var schema: [String:Any] = ["type":"string","description":p.label,"default":p.defaultValue]
            if !p.choices.isEmpty { schema["enum"] = p.choices }
            if let minimum = p.minimum { schema["x-numeric-minimum"] = minimum }
            if let maximum = p.maximum { schema["x-numeric-maximum"] = maximum }
            return (p.key,schema)
        })
        return ["type":"object","additionalProperties":false,"properties":properties,"required":parameters.filter(\.required).map(\.key)]
    }
    func execute(_ prepared: RitoPreparedTool, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult] {
        try await TaskEngine.execute(prepared, progress: progress)
    }
}
enum ToolRegistry {
    static let imageExtensions: Set<String> = ["jpg","jpeg","png","heic","heif","webp","bmp","tif","tiff"]
    static let videoExtensions: Set<String> = ["mp4","mov","m4v","avi","mkv"]
    static let audioExtensions: Set<String> = ["mp3","wav","m4a","aac","flac","aiff","aif","caf"]
    private static func text(_ key: String, _ label: String, _ value: String = "", required: Bool = false) -> ToolParameter { .init(key: key, label: label, defaultValue: value, required: required) }
    private static func choice(_ key: String, _ label: String, _ value: String, _ choices: [String]) -> ToolParameter { .init(key: key, label: label, defaultValue: value, kind: .choice, choices: choices) }
    private static func number(_ key: String, _ label: String, _ value: String, _ min: Double, _ max: Double, integer: Bool = false, required: Bool = false) -> ToolParameter { .init(key: key, label: label, defaultValue: value, kind: integer ? .integer : .number, minimum: min, maximum: max, required: required) }
    private static func tool(_ op: RitoToolCall.Operation, _ name: String, _ description: String, _ input: ToolInput, _ output: String, _ risk: ToolRisk = .newFiles, _ parameters: [ToolParameter] = []) -> RegisteredTool { .init(operation: op, name: name, description: description, input: input, output: output, risk: risk, parameters: parameters) }
    private static let imageFormats = ["original","jpg","png","heic","webp"]
    private static let sizing: [ToolParameter] = [
        choice("sizeMode","尺寸方式","fit",["fit","exact","longEdge"]),
        number("width","宽度（px）","",1,16384,integer:true),
        number("height","高度（px）","",1,16384,integer:true),
        number("maxDimension","最大边长（px）","2048",1,16384,integer:true)
    ]
    private static let photoFields: [ToolParameter] = [
        choice("background","背景底色","original",["original","blue","white","red","custom"]),
        choice("preset","照片规格","one",["one","smallTwo","two","custom"]),
        number("widthMM","照片宽度（mm）","25",10,100),number("heightMM","照片高度（mm）","35",10,100),
        choice("dpi","分辨率（DPI）","300",["150","300","600"]),
        number("red","红色分量","1",0,1),number("green","绿色分量","1",0,1),number("blue","蓝色分量","1",0,1),
        number("zoom","裁切放大","1",1,4),number("cropX","裁切水平","0",-1,1),number("cropY","裁切垂直","0",-1,1)
    ]
    private static let ocrFields = [
        choice("language","识别语言","auto",["auto","en-US","zh-Hans","zh-Hant"]),
        choice("preprocess","图片智能增强","true",["true","false"])
    ]
    private static let organizeFields = [
        choice("recursive","包含子文件夹","true",["true","false"]),
        choice("conflict","同名文件","number",["number","skip"])
    ]
    static let tools: [RegisteredTool] = [
        tool(.file_rename, "文件改名", "前后缀、查找替换、序号；原路径变化，可撤销", .file, "原类型", .changesOriginals, [choice("mode","方式","prefix",["prefix","suffix","replace","numbering"]),text("text","前后缀、替换文字或序号名称"),text("find","查找文字"),number("start","起始序号","1",0,1000000,integer:true),number("digits","序号位数","3",1,12,integer:true)]),
        tool(.organize_copy,"复制整理文件夹","按类型复制分类，源文件保留",.directory,"分类文件夹",.newFiles,organizeFields),
        tool(.organize_move,"移动整理文件夹","按类型移动分类，改变源路径；支持整理记录撤销",.directory,"分类文件夹",.changesOriginals,organizeFields),
        tool(.image_convert,"图片格式转换","按本机编码能力输出，JPG透明处变白",.image,"图片",.newFiles,[choice("format","格式","jpg",["jpg","png","heic","bmp","tiff","webp"])]),
        tool(.image_compress,"图片体积压缩","目标体积试编码，必要时等比缩小",.image,"图片",.newFiles,[number("reduction","减少比例","0.5",0.05,0.95),number("minimumKB","最小体积（KB）","",1,1000000),number("maximumKB","最大体积（KB）","",1,1000000),choice("format","输出格式","original",imageFormats),choice("allowResize","允许等比缩小","true",["true","false"]),number("qualityFloor","最低画质","0.2",0.05,1)] + sizing),
        tool(.image_resize,"调整图片尺寸","支持等比适应、自定义宽高和最大边长",.image,"图片",.newFiles,sizing + [choice("format","输出格式","original",imageFormats),number("quality","画质","0.9",0.05,1)]),
        tool(.cutout,"智能抠图","本机Vision提取全部前景，长边不超过4096",.image,"png"),
        tool(.watermark_remove,"图片去水印","必须在本机确认选区；周边或取样修补",.image,"png",.newFiles,[choice("method","修补方式","surrounding",["surrounding","sample"]),number("x","区域x","",0,1,required:true),number("y","区域y","",0,1,required:true),number("width","区域宽度","",0.002,1,required:true),number("height","区域高度","",0.002,1,required:true),number("sampleX","取样x","",0,1),number("sampleY","取样y","",0,1),number("feather","羽化","3",0,20)]),
        tool(.id_photo,"证件照制作","单人换底、规格裁切，需核对构图",.image,"jpg/png",.newFiles,photoFields + [choice("format","导出格式","jpg",["jpg","png"]),number("maximumKB","JPG大小上限（KB）","",10,5000,integer:true)]),
        tool(.id_photo_print,"证件照打印排版","生成实际尺寸排版PDF，需按100%打印",.image,"pdf",.newFiles,photoFields + [choice("paper","纸张","sixInch",["sixInch","a4"]),choice("cropMarks","裁切标记","true",["true","false"])]),
        tool(.pdf_merge,"PDF合并","至少两个PDF，按附件顺序合并",.pdf,"pdf"),
        tool(.pdf_split,"PDF拆分","按页码范围生成文件，需核对总页数",.pdf,"pdf",.newFiles,[text("ranges","页码范围（如1-3,5）",required:true)]),
        tool(.pdf_encrypt,"PDF加密","打开密码只在本机输入，不上传不记录",.pdf,"pdf",.newFiles,[choice("allowPrinting","允许打印","true",["true","false"]),choice("allowCopying","允许复制","false",["true","false"])]),
        tool(.pdf_watermark,"PDF文字水印","添加文字水印；原PDF保留",.pdf,"pdf",.newFiles,[text("text","水印文字",required:true),number("fontSize","字号","36",8,200),number("opacity","透明度","0.3",0.01,1),number("rotation","角度","-30",-180,180)]),
        tool(.pdf_image_watermark,"PDF图片水印","附件顺序：PDF、作为水印的图片；原PDF保留",.pdfImage,"pdf",.newFiles,[number("scale","图片比例","0.25",0.01,2),number("opacity","透明度","0.3",0.01,1)]),
        tool(.word_to_pdf,"Word转PDF","按现有文字排版转换，不保证原版式",.word,"pdf"),
        tool(.pdf_to_word,"PDF转Word","只提取文字，扫描文档请用PDF OCR",.pdf,"docx"),
        tool(.video_compress,"视频压缩","本机AVFoundation重新编码，实际体积可能变化",.video,"mp4/mov",.newFiles,[choice("quality","质量","medium",["high","medium","low"]),choice("resolution","分辨率","hd",["original","uhd4K","fullHD","hd","sd"]),choice("codec","编码","h264",["h264","hevc"]),choice("format","容器","mp4",["mp4","mov"])]),
        tool(.video_to_gif,"视频转GIF","最多60秒，控制尺寸和帧率",.video,"gif",.newFiles,[number("start","起始秒","0",0,86400),number("duration","时长秒","5",0.1,60),number("frameRate","帧率","10",1,30,integer:true),number("maxDimension","最长边px","480",16,2048,integer:true)]),
        tool(.gif_compress,"GIF压缩","缩小尺寸或减少帧数，保留时序",.gif,"gif",.newFiles,[number("maxDimension","最长边px","480",16,2048,integer:true),number("frameSkip","每几帧取一帧","2",1,30,integer:true)]),
        tool(.speech_to_text,"语音转字幕","系统本机识别，需授权及语言能力",.media,"txt/srt/vtt",.newFiles,[choice("format","字幕格式","txt",["txt","srt","vtt"]),choice("language","识别语言","auto",["auto","zh-CN","en-US"] + Array(Set(SpeechToTextService.supportedLanguages.map(\.code)).subtracting(["auto","zh-CN","en-US"])).sorted())]),
        tool(.collage,"图片拼图","本机将多张图片按布局或长图拼接；先预览并确认",.image,"png/jpg",.newFiles,[
            choice("mode","拼接方式",CollageMode.grid.rawValue,CollageMode.allCases.map(\.rawValue)),
            choice("ratio","画布比例",CollageRatio.portrait.rawValue,CollageRatio.allCases.map(\.rawValue)),
            choice("template","布局模板",CollageTemplate.grid.rawValue,CollageTemplate.allCases.map(\.rawValue)),
            choice("fitImages","图片完整显示","false",["true","false"]),
            number("spacing","图片间距px","12",0,80), number("margin","画布边距px","24",0,120),
            choice("background","画布背景",CollageBackground.white.rawValue,CollageBackground.allCases.map(\.rawValue)),
            choice("resolution","输出参考尺寸px","2400",["1200","1800","2400","3600"]),
            choice("filter","滤镜",CollageFilter.original.rawValue,CollageFilter.allCases.map(\.rawValue)),
            number("brightness","亮度","0",-0.5,0.5), number("contrast","对比度","1",0.5,1.5), number("saturation","饱和度","1",0,2),
            text("caption","标题文字（最多80字）"), choice("captionAtTop","标题位置","false",["true","false"]),
            number("captionSize","标题字号","64",24,120),
            choice("format","导出格式","PNG",CollageFormat.allCases.map(\.rawValue)),
            number("jpegQuality","JPG质量","0.9",0.1,1)
        ]),
        tool(.ocr,"图片文字识别","本机逐图识别，保留对应来源",.image,"文字",.readOnly,ocrFields),
        tool(.pdf_ocr,"PDF文字识别","优先提取文字，扫描页本机OCR",.pdf,"文字",.readOnly,ocrFields)
    ]
    static func lookup(_ operation: RitoToolCall.Operation) -> RegisteredTool { tools.first { $0.operation == operation }! }
    static func recommended(for attachments: [RToolAIAttachment]) -> [RegisteredTool] { tools.filter { tool in attachments.isEmpty || attachments.allSatisfy(tool.accepts) } }
    static func search(_ text: String) -> [RegisteredTool] { tools.filter { text.isEmpty || ($0.name + $0.description + $0.id).localizedCaseInsensitiveContains(text) } }
    static func validate(_ call: RitoToolCall, attachments: [RToolAIAttachment], allowMissing: Bool = false) throws {
        let tool = lookup(call.operation)
        let selected = call.attachmentIDs.compactMap { id in attachments.first { $0.id == id } }
        guard !selected.isEmpty, selected.count == call.attachmentIDs.count, selected.count <= 8,
              Set(call.attachmentIDs).count == selected.count, selected.allSatisfy(tool.accepts),
              call.operation != .pdf_merge || selected.count >= 2 else { throw RitoToolError.invalidPlan }
        _ = try tool.values(call.parameters ?? [:], allowMissing: allowMissing)
        if call.operation == .collage, !(2...8).contains(selected.count) { throw RitoToolError.invalidPlan }
        if [.watermark_remove,.id_photo,.id_photo_print,.pdf_split].contains(call.operation), selected.count != 1 { throw RitoToolError.invalidPlan }
        if call.operation == .pdf_image_watermark {
            guard selected.count == 2, (selected[0].name as NSString).pathExtension.lowercased() == "pdf",
                  imageExtensions.contains((selected[1].name as NSString).pathExtension.lowercased()) else { throw RitoToolError.invalidPlan }
        }
        if call.operation == .file_rename, selected.contains(where: { $0.isDirectory == true }) { throw RitoToolError.invalidPlan }
    }
    static func prompt(for attachments: [RToolAIAttachment]) -> String {
        tools.map { tool in
            let relevant = !attachments.isEmpty && attachments.allSatisfy(tool.accepts)
            let fields = tool.parameters.map { parameter -> String in
                var field = parameter.key
                if relevant { field += "[" + parameter.label + "]" }
                if !parameter.choices.isEmpty {
                    let choices = tool.operation == .speech_to_text && !relevant ? Array(parameter.choices.prefix(3)) : parameter.choices
                    field += "=" + choices.joined(separator: "|")
                }
                if relevant, let minimum = parameter.minimum, let maximum = parameter.maximum {
                    field += "(" + String(minimum) + ".." + String(maximum) + (parameter.kind == .integer ? ",整数" : "") + ")"
                }
                if parameter.required { field += "必填，未知留空" }
                return field
            }.joined(separator: ",")
            return tool.id + ":" + tool.name + "(" + fields + ")"
        }.joined(separator: ";")
    }
    /// Keep all IDs visible while reserving the small local model's context for relevant schemas.
    static func localPrompt(for attachments: [RToolAIAttachment], text: String) -> String {
        let aliases: [RitoToolCall.Operation:[String]] = [
            .file_rename:["改名","重命名","前缀","后缀"], .organize_copy:["整理","分类"], .organize_move:["移动"],
            .image_convert:["转成","转为","jpg","png","heic"], .image_compress:["压缩","体积","kb"], .image_resize:["尺寸","缩小","像素"],
            .cutout:["抠图","去背景"], .watermark_remove:["去水印","修补"], .id_photo:["证件照","换底","蓝色背景","白色背景","红色背景"],
            .id_photo_print:["打印","排版"], .pdf_merge:["合并"], .pdf_split:["拆分","提取页"], .pdf_encrypt:["加密","密码"],
            .pdf_watermark:["水印"], .pdf_image_watermark:["图片水印"], .word_to_pdf:["word","转pdf"], .pdf_to_word:["word"],
            .video_compress:["视频","压缩"], .video_to_gif:["gif"], .gif_compress:["gif","压缩"], .speech_to_text:["语音","字幕","转文字"],
            .ocr:["识别","提取文字","图片文字"], .pdf_ocr:["识别","提取文字","扫描"],
            .collage:["拼图","拼接","长图","模板","合成"]]
        let recommended = recommended(for:attachments)
        let ranked = tools.enumerated().sorted { a,b in
            func score(_ tool: RegisteredTool) -> Int {
                let matches = (aliases[tool.operation] ?? []).filter { text.localizedCaseInsensitiveContains($0) }.count
                return matches * 10 + (recommended.contains(where: { $0.id == tool.id }) ? 1 : 0)
            }
            let x = score(a.element), y = score(b.element)
            return x == y ? a.offset < b.offset : x > y
        }.prefix(3).map(\.element)
        let catalog = tools.map { $0.id + "=" + $0.name }.joined(separator:";")
        var schemas: [String] = []
        for tool in ranked {
            let fields = tool.parameters.map { parameter -> String in
                let choices = parameter.choices.isEmpty ? "" : "=" + parameter.choices.joined(separator:"|")
                return parameter.key + choices
            }.joined(separator:",")
            schemas.append(tool.id + ":" + fields)
        }
        return "工具ID=名称：" + catalog + "\n相关参数：" + schemas.joined(separator:";")
    }
}
enum ToolExecutionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}
