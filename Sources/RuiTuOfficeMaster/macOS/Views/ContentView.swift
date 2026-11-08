#if os(macOS)
import SwiftUI

/// 主布局 — 侧边栏 + 内容区（所有页面保活，切换不丢失状态）
struct ContentView: View {
    @State private var selectedNav: NavItem = .home
    @State private var showingAI = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var ai = RToolAIViewModel(responder: RitoAIConfiguration.shared.makeProvider(), historyStore: .local())

    private var sidebarSelection: Binding<NavItem> {
        Binding(get: { selectedNav }, set: { item in
            selectedNav = item
            showingAI = false
        })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ZStack {
                SidebarView(selectedNav: sidebarSelection, onSelectTool: { showingAI = false })
                    .pageVisible(!showingAI)
                RitoAIHistoryView(model: ai, returnToTools: { showingAI = false })
                    .pageVisible(showingAI)
            }
                .navigationSplitViewColumnWidth(220)
                .safeAreaInset(edge: .top, spacing: 0) {
                    RitoModeSwitch(showingAI: $showingAI)
                        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
                        .background(AppColors.sidebarBackground)
                }
        } detail: {
            ZStack {
                ZStack {
                    HomeView(selectedNav: $selectedNav)
                        .pageVisible(selectedNav == .home)

                    FileOrganizerView()
                        .pageVisible(selectedNav == .fileOrganizer)

                    FileRenameView()
                        .pageVisible(selectedNav == .fileRename)

                    ImageProcessingView()
                        .pageVisible(selectedNav == .imageProcessing)

                    CollageView()
                        .pageVisible(selectedNav == .collage)

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
                .pageVisible(!showingAI)

                RToolAIView(model: ai, isVisible: showingAI)
                .pageVisible(showingAI)
            }
        }
        .onChange(of: RitoAIConfiguration.shared.revision) { _, _ in ai.updateResponder(RitoAIConfiguration.shared.makeProvider()) }
        .onChange(of: showingAI) { _, visible in
            if !visible { ai.stop(); Task { await RitoLocalEngine.shared.unload() } }
        }
        .toolbar {
            if columnVisibility == .detailOnly {
                ToolbarItem(placement: .navigation) {
                    RitoModeSwitch(showingAI: $showingAI).frame(width: 176)
                }
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
