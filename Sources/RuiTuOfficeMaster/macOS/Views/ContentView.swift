#if os(macOS)
import SwiftUI

/// 主布局 — 侧边栏 + 内容区（所有页面保活，切换不丢失状态）
struct ContentView: View {
    @State private var selectedNav: NavItem = .home

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedNav: $selectedNav)
                .navigationSplitViewColumnWidth(220)
        } detail: {
            ZStack {
                HomeView(selectedNav: $selectedNav)
                    .pageVisible(selectedNav == .home)

                FileOrganizerView()
                    .pageVisible(selectedNav == .fileOrganizer)

                FileRenameView()
                    .pageVisible(selectedNav == .fileRename)

                ImageProcessingView()
                    .pageVisible(selectedNav == .imageProcessing)

                ImageCleanupView(tool: .cutout)
                    .pageVisible(selectedNav == .cutout)

                ImageCleanupView(tool: .watermark)
                    .pageVisible(selectedNav == .imageWatermark)

                IDPhotoView()
                    .pageVisible(selectedNav == .idPhoto)

                PDFToolsView()
                    .pageVisible(selectedNav == .pdfTools)

                FormatConversionView()
                    .pageVisible(selectedNav == .formatConversion)

                VideoCompressionView()
                    .pageVisible(selectedNav == .videoCompression)

                MediaConversionView()
                    .pageVisible(selectedNav == .mediaConversion)

                OCRView()
                    .pageVisible(selectedNav == .ocr)

                TaskCenterView()
                    .pageVisible(selectedNav == .tasks)

                HistoryView()
                    .pageVisible(selectedNav == .history)

                SettingsView()
                    .pageVisible(selectedNav == .settings)
            }
        }
    }
}

// MARK: - 页面可见性控制

private extension View {
    /// 控制页面在 ZStack 中的可见性与交互性
    func pageVisible(_ visible: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
    }
}

#endif
