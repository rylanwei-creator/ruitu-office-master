import SwiftUI

/// Coordinates refer to the displayed image, excluding aspect-fit letterboxing.
enum CleanupCanvasGeometry {
    static func imageRect(image: CGSize, canvas: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(canvas.width / image.width, canvas.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
    }
    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
}

struct CleanupCanvas: View {
    let image: CGImage
    @Binding var region: CleanupRegion?
    @Binding var sampleCenter: CGPoint?
    @Binding var pickingSample: Bool
    var editable = false
    var showSample = false
    @State private var draft: CleanupRegion?
    var body: some View {
        GeometryReader { geometry in
            let rect = CleanupCanvasGeometry.imageRect(image: CGSize(width: image.width, height: image.height), canvas: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.secondary.opacity(0.04)
                Canvas { context, _ in
                    let cell: CGFloat = 12
                    for row in 0...Int(rect.height / cell) {
                        for column in 0...Int(rect.width / cell) {
                            let tile = CGRect(x: rect.minX + CGFloat(column) * cell, y: rect.minY + CGFloat(row) * cell, width: cell, height: cell).intersection(rect)
                            context.fill(Path(tile), with: .color((row + column).isMultiple(of: 2) ? Color.white : Color.gray.opacity(0.18)))
                        }
                    }
                }
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                if editable, let box = draft ?? region { outline(box.rect, in: rect, color: .red, text: "处理区域") }
                if editable, showSample, let box = region, let sampleCenter {
                    let sample = CGRect(x: sampleCenter.x - box.rect.width / 2, y: sampleCenter.y - box.rect.height / 2, width: box.rect.width, height: box.rect.height)
                    outline(sample, in: rect, color: .green, text: "取样区域")
                }
            }
            .contentShape(Rectangle()).clipped()
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard editable, rect.contains(value.startLocation) else { return }
                if pickingSample {
                    sampleCenter = CleanupCanvasGeometry.normalized(value.location, in: rect)
                } else {
                    draft = CleanupRegion.selection(from: CleanupCanvasGeometry.normalized(value.startLocation, in: rect), to: CleanupCanvasGeometry.normalized(value.location, in: rect))
                }
            }.onEnded { value in
                guard editable, rect.contains(value.startLocation) else { draft = nil; return }
                if pickingSample {
                    sampleCenter = CleanupCanvasGeometry.normalized(value.location, in: rect); pickingSample = false
                } else if let draft { region = draft; sampleCenter = nil }
                draft = nil
            })
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(editable ? "编辑图像；拖动框选区域，设置取样时点击干净背景" : "图像预览")
    }
    private func outline(_ box: CGRect, in imageRect: CGRect, color: Color, text: String) -> some View {
        let rect = CGRect(x: imageRect.minX + box.minX * imageRect.width, y: imageRect.minY + box.minY * imageRect.height,
                          width: box.width * imageRect.width, height: box.height * imageRect.height)
        return Rectangle().fill(color.opacity(0.1)).overlay(Rectangle().stroke(color, lineWidth: 2))
            .overlay(alignment: .topLeading) { Text(text).font(.caption2).padding(3).background(color).foregroundStyle(.white) }
            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
    }
}

struct CleanupMessages: View {
    let error: String?
    let status: String?
    var body: some View {
        if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(AppColors.error).textSelection(.enabled) }
        if let status { Label(status, systemImage: "info.circle").foregroundStyle(AppColors.textSecondary).textSelection(.enabled) }
    }
}
