import XCTest
import AppKit
import SwiftUI
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import RuiTuOfficeMaster

final class CollageTests: XCTestCase {
    func testEveryTemplateCoversCanvasExactlyForAllSupportedCounts() {
        for count in 1...CollageService.maximumPhotos {
            for template in CollageTemplate.allCases {
                let cells = template.cells(count: count)
                XCTAssertEqual(cells.count,count)
                XCTAssertEqual(cells.reduce(0) { $0+$1.width*$1.height },1,accuracy: 0.000001)
                for (i,cell) in cells.enumerated() {
                    XCTAssertGreaterThan(cell.width,0); XCTAssertGreaterThan(cell.height,0)
                    XCTAssertGreaterThanOrEqual(cell.minX,-0.000001); XCTAssertLessThanOrEqual(cell.maxX,1.000001)
                    XCTAssertGreaterThanOrEqual(cell.minY,-0.000001); XCTAssertLessThanOrEqual(cell.maxY,1.000001)
                    for j in cells.indices where j > i {
                        let intersection = cell.intersection(cells[j])
                        XCTAssertTrue(intersection.isNull || intersection.width*intersection.height < 0.000001)
                    }
                }
            }
        }
    }

    func testRatiosAndSharedGapMatchOutputGeometry() throws {
        var settings = CollageSettings(); settings.resolution = 1200; settings.template = .columns
        for ratio in CollageRatio.allCases {
            settings.ratio = ratio
            let geometry = try CollageService.geometry(sizes: [CGSize(width: 300,height: 200),CGSize(width: 200,height: 300)],settings: settings)
            XCTAssertEqual(geometry.size.width/geometry.size.height,ratio.value,accuracy: 0.001)
            XCTAssertEqual(geometry.cells[0].minX,24)
            XCTAssertEqual(geometry.cells[1].minX-geometry.cells[0].maxX,12,accuracy: 0.0001)
            XCTAssertEqual(geometry.cells[1].maxX,1176,accuracy: 0.0001)
        }
    }

    func testLongStitchKeepsEachSourceAspectRatioAndOrder() throws {
        let sizes = [CGSize(width: 600,height: 400),CGSize(width: 300,height: 600)]
        var settings = CollageSettings(); settings.resolution = 1200; settings.margin = 20; settings.spacing = 10
        settings.mode = .vertical
        let vertical = try CollageService.geometry(sizes: sizes,settings: settings)
        XCTAssertEqual(vertical.size,CGSize(width: 1240,height: 3250))
        XCTAssertEqual(vertical.cells[0],CGRect(x: 20,y: 20,width: 1200,height: 800))
        XCTAssertEqual(vertical.cells[1],CGRect(x: 20,y: 830,width: 1200,height: 2400))
        settings.mode = .horizontal
        let horizontal = try CollageService.geometry(sizes: sizes,settings: settings)
        XCTAssertEqual(horizontal.size,CGSize(width: 2450,height: 1240))
        for (index,cell) in horizontal.cells.enumerated() {
            XCTAssertEqual(cell.width/cell.height,sizes[index].width/sizes[index].height,accuracy: 0.0001)
        }
        XCTAssertLessThan(horizontal.cells[0].maxX,horizontal.cells[1].minX)
    }

    func testVeryLongOutputHasExplicitSafeDimensions() throws {
        var settings = CollageSettings(); settings.mode = .vertical
        let geometry = try CollageService.geometry(sizes: Array(repeating: CGSize(width: 100,height: 3000),count: 12),settings: settings)
        XCTAssertTrue(geometry.reduced)
        XCTAssertLessThanOrEqual(max(geometry.size.width,geometry.size.height),CollageService.maximumSide)
        XCTAssertLessThanOrEqual(geometry.size.width*geometry.size.height,CollageService.maximumPixels)
        XCTAssertTrue(geometry.cells.allSatisfy { $0.maxY <= geometry.size.height+1 })
    }

    func testInvalidInputsAndOverlargeGapsFailBeforeRendering() {
        var settings = CollageSettings()
        XCTAssertThrowsError(try CollageService.geometry(sizes: [],settings: settings))
        XCTAssertThrowsError(try CollageService.geometry(sizes: Array(repeating: .init(width: 20,height: 20),count: 13),settings: settings))
        XCTAssertThrowsError(try CollageService.geometry(sizes: [.zero],settings: settings))
        settings.resolution = .nan
        XCTAssertThrowsError(try CollageService.geometry(sizes: [.init(width: 20,height: 20)],settings: settings))
        settings.resolution = 1200; settings.mode = .vertical
        XCTAssertThrowsError(try CollageService.geometry(sizes: Array(repeating: .init(width: 1,height: 10000),count: 12),settings: settings))
        settings.mode = .grid
        settings.resolution = 600; settings.template = .columns; settings.spacing = 80; settings.margin = 120
        XCTAssertThrowsError(try CollageService.geometry(sizes: Array(repeating: .init(width: 20,height: 20),count: 12),settings: settings))
    }

    func testPNGAndJPGAreRealImagesAndSourceBytesAreUnchanged() throws {
        try withFixtures { root,photos in
            let originals = try photos.map { try Data(contentsOf: $0.url) }
            var settings = CollageSettings(); settings.resolution = 1200; settings.ratio = .square
            let png = root.appendingPathComponent("collage.png")
            try CollageService.export(photos: photos,settings: settings,to: png)
            XCTAssertEqual(try ImageCodec.dimensions(at: png),CGSize(width: 1200,height: 1200))
            XCTAssertEqual(try ImageCodec.sourceType(at: png),.png)
            settings.format = .jpeg
            let jpg = root.appendingPathComponent("collage.jpg")
            try CollageService.export(photos: photos,settings: settings,to: jpg)
            XCTAssertEqual(try ImageCodec.sourceType(at: jpg),.jpeg)
            XCTAssertEqual(try ImageCodec.dimensions(at: jpg),CGSize(width: 1200,height: 1200))
            XCTAssertEqual(try photos.map { try Data(contentsOf: $0.url) },originals)
            XCTAssertThrowsError(try CollageService.export(photos: photos,settings: settings,to: photos[0].url))
            let alias = root.appendingPathComponent("alias.jpg")
            try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: photos[0].url)
            XCTAssertThrowsError(try CollageService.export(photos: photos,settings: settings,to: alias))
            XCTAssertEqual(try photos.map { try Data(contentsOf: $0.url) },originals)
        }
    }

    func testPreviewAndExportHaveSameFramingAndInputOrder() throws {
        try withFixtures { _,photos in
            var settings = CollageSettings(); settings.resolution = 1200; settings.ratio = .square
            settings.template = .columns; settings.margin = 0; settings.spacing = 0
            let full = try CollageService.render(photos: photos,settings: settings)
            let preview = try CollageService.render(photos: photos,settings: settings,previewMaximum: 600)
            for (x,y) in [(0.15,0.5),(0.5,0.5),(0.85,0.5)] {
                let a = try pixel(full,x: x,y: y), b = try pixel(preview,x: x,y: y)
                for i in 0..<4 { XCTAssertEqual(a[i],b[i],accuracy: 2) }
            }
            let first = try pixel(full,x: 0.15,y: 0.5),last = try pixel(full,x: 0.85,y: 0.5)
            XCTAssertGreaterThan(first[0],first[1]); XCTAssertGreaterThan(last[2],last[0])
            let reversed = try CollageService.render(photos: Array(photos.reversed()),settings: settings)
            XCTAssertGreaterThan(try pixel(reversed,x: 0.15,y: 0.5)[2],try pixel(reversed,x: 0.15,y: 0.5)[0])
        }
    }

    func testFitPreservesWholeImageAndCropPanChangesSelectedPart() throws {
        try withFixtures { _,photos in
            var settings = CollageSettings(); settings.resolution = 1200; settings.ratio = .portrait
            settings.margin = 0; settings.spacing = 0; settings.fitImages = true
            let fit = try CollageService.render(photos: [photos[0]],settings: settings)
            let edge = try pixel(fit,x: 0.05,y: 0.05)
            XCTAssertEqual(edge[0],255); XCTAssertEqual(edge[1],255); XCTAssertEqual(edge[2],255)
            settings.fitImages = false
            let filled = try CollageService.render(photos: [photos[0]],settings: settings)
            XCTAssertNotEqual(try pixel(filled,x: 0.05,y: 0.05),edge)
        }
    }

    func testTransparencyFilterAndCaptionChangeExportPixels() throws {
        try withFixtures { _,photos in
            var settings = CollageSettings(); settings.resolution = 1200; settings.margin = 100
            settings.background = .transparent
            let original = try CollageService.render(photos: photos,settings: settings)
            XCTAssertEqual(try pixel(original,x: 0.01,y: 0.01)[3],0)
            settings.filter = .mono
            let mono = try CollageService.render(photos: photos,settings: settings)
            let gray = try pixel(mono,x: 0.2,y: 0.4)
            XCTAssertEqual(gray[0],gray[1],accuracy: 1); XCTAssertEqual(gray[1],gray[2],accuracy: 1)
            settings.caption = "RUITU COLLAGE"
            let caption = try CollageService.render(photos: photos,settings: settings)
            XCTAssertNotEqual(Data(try XCTUnwrap(mono.dataProvider?.data) as Data),Data(try XCTUnwrap(caption.dataProvider?.data) as Data))
        }
    }

    @MainActor func testOrdinaryNavigationAndUndoKeepCollageAvailableToAIRegistry() {
        XCTAssertTrue(ToolCatalog.tools.contains { $0.item == .collage })
        XCTAssertEqual(ToolCatalog.search("拼图").first?.item,.collage)
        XCTAssertTrue(ToolRegistry.tools.contains { $0.name.contains("拼图") && $0.operation == .collage })
        let model = CollageViewModel()
        model.settings.ratio = .square; model.settings.margin = 50
        model.undo(); XCTAssertEqual(model.settings.margin,24); XCTAssertEqual(model.settings.ratio,.square)
        model.undo(); XCTAssertEqual(model.settings.ratio,.portrait)
        model.redo(); XCTAssertEqual(model.settings.ratio,.square)
    }

    @MainActor func testImportReorderRemoveAndUndoPreservePhotoIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try makePhotos(root).map(\.url)
        let model = CollageViewModel(); model.add(urls)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while (model.isLoading || model.isRendering) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.photos.count,3); XCTAssertNotNil(model.preview)
        let first = try XCTUnwrap(model.photos.first?.id)
        model.move(first,by: 1); XCTAssertEqual(model.photos[1].id,first)
        model.remove(first); XCTAssertEqual(model.photos.count,2)
        model.undo(); XCTAssertEqual(model.photos[1].id,first)
        model.clear(); XCTAssertTrue(model.photos.isEmpty); XCTAssertNil(model.preview)
        model.undo(); XCTAssertEqual(model.photos.count,3)
    }

    func testCancellationDuringRenderingNeverWritesAnOutput() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = try makePhotos(root),output = root.appendingPathComponent("cancelled.png")
        let events = AsyncStream<Void>.makeStream()
        let proceed = DispatchSemaphore(value: 0)
        let task = Task.detached {
            defer { events.continuation.finish() }
            try CollageService.export(photos: photos,settings: CollageSettings(),to: output) { progress in
                if progress < 0.5 { events.continuation.yield(); _ = proceed.wait(timeout: .now()+5) }
            }
        }
        var iterator = events.stream.makeAsyncIterator()
        let didStart = await iterator.next() != nil
        task.cancel(); proceed.signal()
        XCTAssertTrue(didStart,"The real renderer must start before cancellation")
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testEXIFOrientationIsHonoredInLongGeometryAndRender() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let image = try fixture(width: 600,height: 300,color: (1,0,0),label: "")
        let url = root.appendingPathComponent("rotated.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photo = try CollageService.prepare(url)
        XCTAssertEqual(photo.size,CGSize(width: 300,height: 600))
        var settings = CollageSettings(); settings.mode = .vertical; settings.resolution = 1200; settings.margin = 0
        let imageOut = try CollageService.render(photos: [photo],settings: settings)
        XCTAssertEqual(imageOut.width,1200); XCTAssertEqual(imageOut.height,2400)
    }

    /// Persistent examples are requested only through an explicit test environment output directory.
    func testRenderReferenceArtifacts() throws {
        guard let path = ProcessInfo.processInfo.environment["RUITU_COLLAGE_ARTIFACTS"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let photos = try makePhotos(root)
        var settings = CollageSettings(); settings.resolution = 1200; settings.template = .left
        settings.background = .cream; settings.margin = 32; settings.spacing = 16; settings.caption = "把今天拼在一起 · 锐途拼图"
        try CollageService.export(photos: photos,settings: settings,to: root.appendingPathComponent("拼图示例.png"))
        settings.mode = .vertical; settings.caption = ""
        try CollageService.export(photos: photos,settings: settings,to: root.appendingPathComponent("纵向拼接示例.png"))
        settings.mode = .horizontal
        try CollageService.export(photos: photos,settings: settings,to: root.appendingPathComponent("横向拼接示例.png"))
    }

    @MainActor func testRenderNativeInterfaceArtifacts() async throws {
        guard let path = ProcessInfo.processInfo.environment["RUITU_COLLAGE_ARTIFACTS"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let model = CollageViewModel(); model.add(try makePhotos(root).map(\.url))
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while (model.isLoading || model.isRendering) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.preview)
        _ = NSApplication.shared
        let views: [(String, ColorScheme, CGFloat)] = [("界面预览-浅色",.light,1180),("界面预览-深色",.dark,1180),("界面预览-窄窗口",.light,760)]
        for (name,scheme,width) in views {
            let host = NSHostingView(rootView: CollageView(model: model).environment(\.colorScheme,scheme).frame(width: width,height: 820))
            host.frame = CGRect(x: 0,y: 0,width: width,height: 820)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw XCTSkip("当前系统无法离屏渲染 SwiftUI。") }
            host.cacheDisplay(in: host.bounds,to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
            try png.write(to: root.appendingPathComponent(name+".png"))
        }
    }

    private func withFixtures(_ work: (URL,[CollagePhoto]) throws -> Void) throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try work(root,makePhotos(root))
    }
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true); return root
    }
    private func makePhotos(_ root: URL) throws -> [CollagePhoto] {
        let colors: [(CGFloat,CGFloat,CGFloat)] = [(0.94,0.38,0.28),(0.14,0.62,0.51),(0.24,0.46,0.82)]
        return try colors.enumerated().map { i,color in
            let image = try fixture(width: i == 1 ? 400 : 600,height: i == 1 ? 600 : 400,color: color,label: "PHOTO \(i+1)")
            let url = root.appendingPathComponent("photo-\(i+1).png")
            try ImageCodec.encode(image,type: .png,quality: 1).write(to: url)
            return try CollageService.prepare(url)
        }
    }
    private func fixture(width: Int,height: Int,color: (CGFloat,CGFloat,CGFloat),label: String) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let c = try XCTUnwrap(CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(srgbRed: color.0,green: color.1,blue: color.2,alpha: 1)); c.fill(CGRect(x: 0,y: 0,width: width,height: height))
        c.setFillColor(CGColor(gray: 1,alpha: 0.12))
        c.fillEllipse(in: CGRect(x: -80,y: -100,width: 500,height: 450))
        c.fill(CGRect(x: 0,y: height-80,width: width,height: 6))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label,attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("HelveticaNeue-Bold" as CFString,44,nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1,alpha: 1)
        ]))
        c.textPosition = CGPoint(x: 40,y: height-65); CTLineDraw(line,c)
        return try XCTUnwrap(c.makeImage())
    }
    private func pixel(_ image: CGImage,x: Double,y: Double) throws -> [Double] {
        let c = try XCTUnwrap(CGContext(data: nil,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,
                                       space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        let data = try XCTUnwrap(c.data?.assumingMemoryBound(to: UInt8.self))
        let i = (min(image.height-1,Int(Double(image.height)*y))*image.width+min(image.width-1,Int(Double(image.width)*x)))*4
        return (0..<4).map { Double(data[i+$0]) }
    }
}
