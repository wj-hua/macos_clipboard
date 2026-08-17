import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var viewModel: ClipboardViewModel
    let onClose: () -> Void
    let onWindowDragChanged: () -> Void
    let onWindowDragEnded: () -> Void

    @State private var windowDragExclusions: [CGRect] = []
    @State private var isDeleteConfirmationPresented = false
    @State private var draggedItemID: UUID?
    @State private var draggedTagID: UUID?
    @State private var isAddTagAlertPresented = false
    @State private var newTagName = ""
    @State private var tagToDelete: PasteTag?
    @State private var tagErrorMessage: String?
    @State private var isTextEditorComposing = false
    @State private var isUsageHelpPresented = false

    private let panelCornerRadius: CGFloat = 24

    static let panelWidth: CGFloat = 500
    static let listRowHeight: CGFloat = 42
    static let listRowSpacing: CGFloat = 6
    static let minimumListRows = 5
    static let maximumListRows = 10
    fileprivate static let panelCoordinateSpace = "ClipboardPanel"

    static let listHeaderHeight: CGFloat = 50
    private static let listFooterHeight: CGFloat = 60
    private static let editorPanelHeight: CGFloat = 420

    /// 面板高度预算。标签栏会随标签数量换行变高，列表行数必须让位，
    /// 否则面板会长到屏幕可视区域之外，底栏按钮点不到。
    /// 取 700 是为了在 1280x800 这类最小的 Mac 屏幕上也留有余量。
    static let maxPanelHeight: CGFloat = 700

    static var listRowSlotHeight: CGFloat {
        listRowHeight + listRowSpacing
    }

    /// 只有多于一个标签时才显示标签栏，高度计算与视图必须用同一个判断。
    static func tagBarHeight(for tags: [PasteTag]) -> CGFloat {
        tags.count > 1 ? TagBarMetrics.barHeight(for: tags) : 0
    }

    static func visibleListRows(for itemCount: Int, tagBarHeight: CGFloat = 0) -> Int {
        let desired = min(max(itemCount, minimumListRows), maximumListRows)
        let available = maxPanelHeight - listHeaderHeight - listFooterHeight - tagBarHeight
        let fitting = Int(floor(available / listRowSlotHeight))
        // 列表本身可以滚动，压缩行数只是少露几行；但不能压到比最小行数还少。
        return max(minimumListRows, min(desired, fitting))
    }

    static func panelHeight(
        for itemCount: Int,
        tags: [PasteTag] = [],
        mode: ClipboardViewModel.Mode
    ) -> CGFloat {
        switch mode {
        case .list:
            // 标签栏会按标签实际宽度换行，面板高度必须跟着行数一起长，
            // 否则多出来的行会被窗口边界裁掉。
            let barHeight = tagBarHeight(for: tags)
            return listHeaderHeight
                + barHeight
                + listFooterHeight
                + listRowSlotHeight * CGFloat(visibleListRows(for: itemCount, tagBarHeight: barHeight))
        case .editor:
            return editorPanelHeight
        }
    }

    private var panelHeight: CGFloat {
        Self.panelHeight(
            for: viewModel.items.count,
            tags: viewModel.tags,
            mode: viewModel.mode
        )
    }

    private var listAreaHeight: CGFloat {
        Self.listRowSlotHeight * CGFloat(
            Self.visibleListRows(
                for: viewModel.items.count,
                tagBarHeight: Self.tagBarHeight(for: viewModel.tags)
            )
        )
    }

    private func isWindowDragExcluded(_ location: CGPoint) -> Bool {
        windowDragExclusions.contains { $0.contains(location) }
    }

    var body: some View {
        ZStack {
            panelBackdrop

            Group {
                switch viewModel.mode {
                case .list:
                    listView
                case .editor:
                    editorView
                }
            }
        }
        .frame(width: Self.panelWidth, height: panelHeight)
        // The panel itself is the hit-test surface. Empty glass areas must still
        // receive the mouse event instead of letting it fall through to the app
        // underneath.
        .contentShape(Rectangle())
        .onPreferenceChange(WindowDragExclusionPreferenceKey.self) { exclusions in
            windowDragExclusions = exclusions
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.panelCoordinateSpace))
                .onChanged { value in
                    // 手势按下的位置一旦落在按钮、列表或文本编辑器上，就完全不上报，
                    // 让这些控件保留自己的点击与拖拽语义。
                    guard !isWindowDragExcluded(value.startLocation) else { return }

                    onWindowDragChanged()
                }
                .onEnded { _ in
                    onWindowDragEnded()
                }
        )
        // 命名坐标系要包住手势本身，手势和上报排除矩形的 GeometryReader 才会落在同一个
        // 空间里 —— 命名空间只对其后代可见。
        .coordinateSpace(name: Self.panelCoordinateSpace)
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.92),
                            ClipboardTheme.mint.opacity(0.30),
                            Color.white.opacity(0.56)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 28, y: 16)
        .sheet(isPresented: $viewModel.isShowingPermission) {
            AccessibilityPermissionView(viewModel: viewModel)
                .frame(width: 430, height: 280)
        }
        .alert("删除常用文本？", isPresented: $isDeleteConfirmationPresented) {
            Button("删除", role: .destructive) {
                viewModel.deleteSelectedItem()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法从应用中恢复这条文本。")
        }
        .alert(
            "无法粘贴",
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.alertMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
        .alert("新建标签", isPresented: $isAddTagAlertPresented) {
            TextField("标签名称", text: $newTagName)

            Button("添加") {
                let name = newTagName
                newTagName = ""
                if !viewModel.addTag(name: name) {
                    tagErrorMessage = "标签名称不能为空，且不能与现有标签重复。"
                }
            }

            Button("取消", role: .cancel) {
                newTagName = ""
            }
        } message: {
            Text("为常用文本创建一个分类标签。")
        }
        .alert(
            "无法添加标签",
            isPresented: Binding(
                get: { tagErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        tagErrorMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(tagErrorMessage ?? "")
        }
        .alert(
            "删除标签？",
            isPresented: Binding(
                get: { tagToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        tagToDelete = nil
                    }
                }
            )
        ) {
            Button("删除", role: .destructive) {
                if let tagID = tagToDelete?.id {
                    viewModel.deleteTag(id: tagID)
                }
                tagToDelete = nil
            }
            Button("取消", role: .cancel) {
                tagToDelete = nil
            }
        } message: {
            Text("该标签中的文本会移动到“默认”标签，不会被删除。")
        }
        // 面板保持浅色玻璃，不跟随深色系统主题变成黑底。
        .environment(\.colorScheme, .light)
    }

    private var panelBackdrop: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.78))

            Rectangle()
                .fill(.thinMaterial)
                .opacity(0.62)

            LinearGradient(
                colors: [
                    ClipboardTheme.mintSoft.opacity(0.80),
                    Color.white.opacity(0.28),
                    Color.white.opacity(0.18),
                    ClipboardTheme.seafoam.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(ClipboardTheme.mint.opacity(0.20))
                .frame(width: 230, height: 230)
                .blur(radius: 56)
                .offset(x: 185, y: -175)

            Circle()
                .fill(ClipboardTheme.seafoam.opacity(0.24))
                .frame(width: 210, height: 210)
                .blur(radius: 60)
                .offset(x: -190, y: 175)

            Color.white.opacity(0.12)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var listView: some View {
        VStack(spacing: 0) {
            header(title: "常用粘贴板", showsTagButton: true)

            if viewModel.tags.count > 1 {
                tagBar
            }

            if viewModel.items.isEmpty {
                emptyState
            } else {
                listContent
            }

            footer
        }
    }

    private var tagBar: some View {
        // 单行横向滚动会把标签裁掉，而列表模式下滚轮已被面板用于切换选中项，
        // 那条 ScrollView 实际滚不动，所以这里改为按行铺开、全部展示。
        VStack(alignment: .leading, spacing: TagBarMetrics.rowSpacing) {
            ForEach(Array(TagBarMetrics.rows(for: viewModel.tags).enumerated()), id: \.offset) { _, row in
                HStack(spacing: TagBarMetrics.itemSpacing) {
                    ForEach(row) { entry in
                        switch entry {
                        case .tag(let tag):
                            tagChip(for: tag)
                                .onDrop(
                                    of: [.text],
                                    delegate: TagDropDelegate(
                                        tagID: tag.id,
                                        draggedTagID: $draggedTagID,
                                        tags: viewModel.tags,
                                        moveTags: viewModel.moveTags
                                    )
                                )
                        case .addButton:
                            addTagButton
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(height: TagBarMetrics.rowHeight)
            }
        }
        .frame(height: TagBarMetrics.barHeight(for: viewModel.tags))
        .padding(.horizontal, TagBarMetrics.horizontalPadding)
        .background {
            Rectangle()
                .fill(Color.white.opacity(0.34))
                .overlay {
                    Rectangle()
                        .fill(.thinMaterial)
                        .opacity(0.30)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(ClipboardTheme.mint.opacity(0.14))
                        .frame(height: 1)
                }
        }
        // 整条标签栏都让给标签自己的长按拖动排序，窗口拖动不在这里接管。
        .excludedFromWindowDrag()
    }

    private var addTagButton: some View {
        Button {
            beginAddingTag()
        } label: {
            ZStack {
                Circle()
                    .fill(ClipboardTheme.mint.opacity(0.12))
                    .overlay {
                        Circle()
                            .stroke(ClipboardTheme.mint.opacity(0.22), lineWidth: 1)
                    }

                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(ClipboardTheme.mintDeep)
            .frame(width: TagBarMetrics.addButtonSize, height: TagBarMetrics.addButtonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("添加标签")
    }

    private func tagChip(for tag: PasteTag) -> some View {
        let isSelected = viewModel.selectedTagID == tag.id

        return HStack(spacing: 0) {
            Button {
                viewModel.selectTag(withID: tag.id)
            } label: {
                HStack(spacing: TagBarMetrics.chipIconSpacing) {
                    Image(systemName: TagBarMetrics.symbolName(for: tag))
                        .font(.system(size: TagBarMetrics.chipIconSize, weight: .semibold))

                    Text(tag.name)
                        .font(.system(size: TagBarMetrics.chipTextSize, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected ? ClipboardTheme.mintDeep : ClipboardTheme.ink.opacity(0.78))
                .padding(.leading, TagBarMetrics.chipLeadingPadding)
                .padding(.trailing, tag.isDefault ? TagBarMetrics.chipLeadingPadding : TagBarMetrics.chipTrailingPadding)
                .frame(height: TagBarMetrics.chipHeight)
                // 让整块胶囊区域可点，而不是只有图标和文字的实际像素。
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag {
                draggedTagID = tag.id
                return NSItemProvider(object: tag.id.uuidString as NSString)
            }

            if !tag.isDefault {
                Rectangle()
                    .fill(isSelected ? ClipboardTheme.mint.opacity(0.24) : ClipboardTheme.ink.opacity(0.12))
                    .frame(width: TagBarMetrics.chipDividerWidth, height: 16)

                Button {
                    tagToDelete = tag
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: TagBarMetrics.chipDeleteButtonWidth, height: TagBarMetrics.chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? ClipboardTheme.mintDeep.opacity(0.78) : .secondary)
                .help("删除标签")
            }
        }
        .background {
            Capsule()
                .fill(isSelected ? ClipboardTheme.mint.opacity(0.18) : Color.white.opacity(0.42))
                .overlay {
                    Capsule()
                        .stroke(
                            isSelected ? ClipboardTheme.mint.opacity(0.42) : ClipboardTheme.mint.opacity(0.16),
                            lineWidth: 1
                        )
                }
        }
        .contentShape(Capsule())
        .contextMenu {
            if tag.isDefault {
                Button("默认标签不可删除") {}
                    .disabled(true)
            } else {
                Button("删除标签", role: .destructive) {
                    tagToDelete = tag
                }
            }
        }
    }

    private func beginAddingTag() {
        newTagName = ""
        isAddTagAlertPresented = true
    }

    private var listContent: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    ClipboardRow(
                        item: item,
                        index: index,
                        isSelected: viewModel.selectedItemID == item.id,
                        preview: preview(for: item.text)
                    )
                    .id(item.id)
                    // 单击更新选中项，双击沿用回车的粘贴路径并关闭面板。
                    // 与 List 的原生拖动手势并行识别，避免点击手势拦截排序。
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            viewModel.selectedItemID = item.id
                        }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            if viewModel.pasteItem(withID: item.id) {
                                onClose()
                            }
                        }
                    )
                    .onDrag {
                        draggedItemID = item.id
                        return NSItemProvider(object: item.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: ClipboardDropDelegate(
                            itemID: item.id,
                            draggedItemID: $draggedItemID,
                            items: viewModel.items,
                            moveItems: viewModel.moveItems
                        )
                    )
                    .listRowInsets(
                        EdgeInsets(
                            top: Self.listRowSpacing / 2,
                            leading: 18,
                            bottom: Self.listRowSpacing / 2,
                            trailing: 18
                        )
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button("编辑") {
                            viewModel.selectedItemID = item.id
                            viewModel.beginEditingSelectedItem()
                        }
                        Button("删除", role: .destructive) {
                            viewModel.selectedItemID = item.id
                            isDeleteConfirmationPresented = true
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: viewModel.selectedItemID) { _, selectedItemID in
                guard let selectedItemID else { return }

                withAnimation(.snappy(duration: 0.24)) {
                    scrollProxy.scrollTo(selectedItemID, anchor: .center)
                }
            }
        }
        .frame(minHeight: listAreaHeight)
        .excludedFromWindowDrag()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            controlButton(title: "添加", systemImage: "plus", emphasis: true) {
                viewModel.beginAdding()
            }
            .keyboardShortcut("n", modifiers: [.command])

            controlButton(
                title: "编辑",
                systemImage: "square.and.pencil",
                isDisabled: viewModel.selectedItemID == nil
            ) {
                viewModel.beginEditingSelectedItem()
            }

            controlButton(
                title: "删除",
                systemImage: "trash.fill",
                isDisabled: viewModel.selectedItemID == nil
            ) {
                isDeleteConfirmationPresented = true
            }

            Spacer(minLength: 8)

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isUsageHelpPresented.toggle()
                }
            } label: {
                Label("使用说明", systemImage: "questionmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(ClipboardTheme.mintDeep)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background {
                        Capsule()
                            .fill(ClipboardTheme.mint.opacity(0.12))
                            .overlay {
                                Capsule()
                                    .stroke(ClipboardTheme.mint.opacity(0.24), lineWidth: 1)
                            }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onDisappear {
                isUsageHelpPresented = false
            }
            .help("查看使用说明")
            .accessibilityHint("显示常用粘贴板的操作说明")
            .excludedFromWindowDrag()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Rectangle()
                .fill(Color.white.opacity(0.52))
                .overlay {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.46)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(ClipboardTheme.mint.opacity(0.20))
                        .frame(height: 1)
                }
        }
        .overlay(alignment: .bottomTrailing) {
            if isUsageHelpPresented {
                usageHelpBubble
                    .padding(.trailing, 16)
                    .offset(y: -46)
                    .transition(
                        .opacity.combined(
                            with: .scale(scale: 0.96, anchor: .bottomTrailing)
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var usageHelpBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("使用说明", systemImage: "questionmark.circle.fill")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(ClipboardTheme.mintDeep)

            VStack(alignment: .leading, spacing: 7) {
                usageHelpRow(shortcut: "⌥ 空格", description: "显示或隐藏面板")
                usageHelpRow(shortcut: "单击", description: "选择常用文本")
                usageHelpRow(shortcut: "双击 / ↩", description: "粘贴所选文本")
                usageHelpRow(shortcut: "⌥ 1–9", description: "直接粘贴对应文本")
                usageHelpRow(shortcut: "拖动", description: "调整文本或标签顺序")
            }
        }
        .padding(14)
        .frame(width: 250, alignment: .leading)
        .foregroundStyle(ClipboardTheme.ink.opacity(0.82))
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.94))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.28)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ClipboardTheme.mint.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 16, y: 7)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.94))
                .offset(x: -48, y: 8)
        }
    }

    private func usageHelpRow(shortcut: String, description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(shortcut)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(ClipboardTheme.mintDeep.opacity(0.88))
                .frame(width: 62, alignment: .leading)

            Text(description)
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
    }

    private func controlButton(
        title: String,
        systemImage: String,
        emphasis: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(emphasis ? Color.white : ClipboardTheme.ink)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(emphasis ? ClipboardTheme.mint : Color.white.opacity(0.46))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    emphasis ? Color.white.opacity(0.48) : ClipboardTheme.mint.opacity(0.18),
                                    lineWidth: 1
                                )
                        }
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .excludedFromWindowDrag()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ClipboardTheme.mint.opacity(0.14))
                    .frame(width: 68, height: 68)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(ClipboardTheme.mintDeep)
            }

            VStack(spacing: 5) {
                Text("还没有常用文本")
                    .font(.system(size: 18, weight: .bold, design: .rounded))

                Text("把经常输入的内容存起来，随时一键粘贴")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.beginAdding()
            } label: {
                Label("添加第一条", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.borderedProminent)
            .excludedFromWindowDrag()

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: listAreaHeight)
    }

    private var editorView: some View {
        VStack(spacing: 0) {
            header(
                title: viewModel.isEditingExistingItem ? "编辑常用文本" : "添加常用文本",
                subtitle: "保存后可用快捷键快速粘贴",
                showsBackButton: true
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("文本内容")
                        .font(.system(size: 13, weight: .bold, design: .rounded))

                    Spacer()

                    Text("支持多行")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                ZStack(alignment: .topLeading) {
                    ClipboardTextEditor(
                        text: $viewModel.draftText,
                        isComposing: $isTextEditorComposing,
                        onSubmit: viewModel.saveDraft
                    )

                    if viewModel.draftText.isEmpty && !isTextEditorComposing {
                        Text("输入你想保存的常用文本…")
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundStyle(.tertiary)
                            // 与 macOS TextEditor 默认的文本容器内边距保持一致。
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.56))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.thinMaterial)
                                .opacity(0.44)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ClipboardTheme.mint.opacity(0.20), lineWidth: 1)
                        }
                }
                .excludedFromWindowDrag()

                HStack {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))

                    Text("回车保存，Shift + 回车或 Command + 回车换行")
                        .font(.system(size: 12, weight: .medium, design: .rounded))

                    Spacer()

                    Text("\(viewModel.draftText.count) 字")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 3)
            .onChange(of: viewModel.mode) { _, mode in
                if mode != .editor {
                    isTextEditorComposing = false
                }
            }

            HStack(spacing: 10) {
                Button("取消") {
                    viewModel.cancelEditing()
                }
                .buttonStyle(.bordered)
                .excludedFromWindowDrag()

                Spacer()

                Button {
                    viewModel.saveDraft()
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSaveDraft)
                .excludedFromWindowDrag()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
    }

    private func header(
        title: String? = nil,
        subtitle: String? = nil,
        showsBackButton: Bool = false,
        showsTagButton: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            if showsBackButton {
                Button {
                    viewModel.cancelEditing()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background {
                    Circle()
                        .fill(ClipboardTheme.mint.opacity(0.09))
                        .overlay {
                            Circle()
                                .stroke(ClipboardTheme.mint.opacity(0.18), lineWidth: 1)
                        }
                }
                .help("返回列表")
                .excludedFromWindowDrag()
            }

            if let title {
                if showsTagButton {
                    HStack(spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ClipboardTheme.mint.opacity(0.14))

                            Image(systemName: "doc.on.clipboard.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ClipboardTheme.mintDeep)
                        }
                        .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(title)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .lineLimit(1)

                            Text("\(viewModel.items.count) 条文本")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .lineLimit(1)

                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 5)

            if showsTagButton {
                if viewModel.tags.count <= 1 {
                    Button {
                        beginAddingTag()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tag.fill")
                            Text("标签")
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                        }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ClipboardTheme.mintDeep.opacity(0.82))
                    .background {
                        Capsule()
                            .fill(ClipboardTheme.mint.opacity(0.10))
                            .overlay {
                                Capsule()
                                    .stroke(ClipboardTheme.mint.opacity(0.20), lineWidth: 1)
                            }
                    }
                    .help("添加标签")
                    .excludedFromWindowDrag()
                }
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background {
                Circle()
                    .fill(ClipboardTheme.mint.opacity(0.09))
                    .overlay {
                        Circle()
                            .stroke(ClipboardTheme.mint.opacity(0.18), lineWidth: 1)
                    }
            }
            .help("关闭")
            .excludedFromWindowDrag()
        }
        .frame(minHeight: showsTagButton ? 32 : 42)
        .padding(.horizontal, showsTagButton ? 18 : 20)
        .padding(.vertical, showsTagButton ? 9 : 14)
    }

    private func preview(for text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "  ↵  ")
            .replacingOccurrences(of: "\r", with: "")
    }
}

/// 标签栏中的一格：标签胶囊，或行尾的「新建标签」按钮。
enum TagBarEntry: Identifiable {
    case tag(PasteTag)
    case addButton

    var id: String {
        switch self {
        case .tag(let tag):
            return tag.id.uuidString
        case .addButton:
            return "add-tag-button"
        }
    }
}

/// 标签栏的排版尺寸。视图与 `ClipboardPanelView.panelHeight` 共用这里的换行结果，
/// 面板高度才能和实际行数保持一致。
enum TagBarMetrics {
    static let chipHeight: CGFloat = 30
    static let chipIconSize: CGFloat = 10
    static let chipTextSize: CGFloat = 12
    static let chipIconSpacing: CGFloat = 5
    static let chipLeadingPadding: CGFloat = 10
    static let chipTrailingPadding: CGFloat = 7
    static let chipDividerWidth: CGFloat = 1
    static let chipDeleteButtonWidth: CGFloat = 25

    static let addButtonSize: CGFloat = 30
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 6
    static let itemSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 9

    static func symbolName(for tag: PasteTag) -> String {
        tag.isDefault ? "tray.fill" : "tag.fill"
    }

    /// 一行可用的宽度。
    static var contentWidth: CGFloat {
        ClipboardPanelView.panelWidth - horizontalPadding * 2
    }

    /// 估算胶囊宽度。这里只能偏大不能偏小：算窄了标签就会被挤出面板宽度，
    /// 算宽了最多是行尾多留一点空白。
    static func chipWidth(for tag: PasteTag) -> CGFloat {
        let textWidth = (tag.name as NSString).size(withAttributes: [.font: chipFont]).width
        var width = chipLeadingPadding
            + symbolWidth(for: tag)
            + chipIconSpacing
            + textWidth
            + (tag.isDefault ? chipLeadingPadding : chipTrailingPadding)

        if !tag.isDefault {
            width += chipDividerWidth + chipDeleteButtonWidth
        }

        return ceil(width) + 2
    }

    /// 按可用宽度把标签铺成若干行，「新建标签」按钮永远跟在最后一个标签后面。
    static func rows(for tags: [PasteTag]) -> [[TagBarEntry]] {
        let available = contentWidth
        var rows: [[TagBarEntry]] = []
        var currentRow: [TagBarEntry] = []
        var currentWidth: CGFloat = 0

        func append(_ entry: TagBarEntry, width: CGFloat) {
            if currentRow.isEmpty {
                currentRow = [entry]
                currentWidth = width
                return
            }

            let widthWithEntry = currentWidth + itemSpacing + width
            if widthWithEntry > available {
                rows.append(currentRow)
                currentRow = [entry]
                currentWidth = width
            } else {
                currentRow.append(entry)
                currentWidth = widthWithEntry
            }
        }

        for tag in tags {
            // 单个标签比整行还宽时只能截断，但仍要占满一行，不能溢出面板。
            append(.tag(tag), width: min(chipWidth(for: tag), available))
        }
        append(.addButton, width: addButtonSize)

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }

    static func barHeight(for tags: [PasteTag]) -> CGFloat {
        let rowCount = max(rows(for: tags).count, 1)
        return CGFloat(rowCount) * rowHeight
            + CGFloat(rowCount - 1) * rowSpacing
            + verticalPadding * 2
    }

    private static let chipFont: NSFont = {
        let base = NSFont.systemFont(ofSize: chipTextSize, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: chipTextSize) else {
            return base
        }
        return rounded
    }()

    private static let defaultSymbolWidth = measuredSymbolWidth(named: "tray.fill")
    private static let tagSymbolWidth = measuredSymbolWidth(named: "tag.fill")

    private static func symbolWidth(for tag: PasteTag) -> CGFloat {
        tag.isDefault ? defaultSymbolWidth : tagSymbolWidth
    }

    private static func measuredSymbolWidth(named name: String) -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(pointSize: chipIconSize, weight: .semibold)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return chipIconSize + 4
        }
        return ceil(image.size.width)
    }
}

/// 面板内不参与「长按拖动窗口」的区域，由控件自己按实际布局上报，
/// 避免把按钮位置写成常量后随布局漂移。
private struct WindowDragExclusionPreferenceKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func excludedFromWindowDrag() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: WindowDragExclusionPreferenceKey.self,
                        value: [proxy.frame(in: .named(ClipboardPanelView.panelCoordinateSpace))]
                    )
            }
        }
    }
}

private struct ClipboardTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ClipboardNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.compositionStateDidChange = { [weak coordinator = context.coordinator] isComposing in
            DispatchQueue.main.async {
                coordinator?.updateCompositionState(isComposing)
            }
        }
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClipboardNSTextView,
              !textView.isComposing,
              textView.string != text else {
            return
        }

        let selectedRange = textView.selectedRange()
        textView.string = text
        let safeLocation = min(selectedRange.location, (text as NSString).length)
        textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ClipboardTextEditor

        init(parent: ClipboardTextEditor) {
            self.parent = parent
        }

        func updateCompositionState(_ isComposing: Bool) {
            guard parent.isComposing != isComposing else { return }

            parent.isComposing = isComposing
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  parent.text != textView.string else {
                return
            }

            parent.text = textView.string
        }
    }
}

private final class ClipboardNSTextView: NSTextView {
    var compositionStateDidChange: ((Bool) -> Void)?
    var onSubmit: (() -> Void)?
    private(set) var isComposing = false

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        isComposing = hasMarkedTextContent(string)
        compositionStateDidChange?(isComposing)
    }

    override func unmarkText() {
        super.unmarkText()
        isComposing = false
        compositionStateDidChange?(false)
    }

    private func hasMarkedTextContent(_ text: Any) -> Bool {
        if let text = text as? String {
            return !text.isEmpty
        }

        if let text = text as? NSAttributedString {
            return text.length > 0
        }

        if let text = text as? NSString {
            return text.length > 0
        }

        return true
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return
        }

        insertText(text, replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == UInt16(kVK_Return)
            || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        guard isReturnKey else {
            super.keyDown(with: event)
            return
        }

        // Let the input method commit its marked text before handling Return.
        guard !isComposing else {
            super.keyDown(with: event)
            return
        }

        let textInputModifiers = event.modifierFlags.intersection([
            .shift,
            .control,
            .option,
            .command
        ])
        if textInputModifiers.isEmpty {
            onSubmit?()
        } else if textInputModifiers.contains(.shift) || textInputModifiers.contains(.command) {
            insertText("\n", replacementRange: selectedRange())
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturnKey = event.keyCode == UInt16(kVK_Return)
            || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        let textInputModifiers = event.modifierFlags.intersection([
            .shift,
            .control,
            .option,
            .command
        ])
        if isReturnKey, !isComposing {
            if textInputModifiers.isEmpty {
                onSubmit?()
                return true
            }

            if textInputModifiers.contains(.shift) || textInputModifiers.contains(.command) {
                insertText("\n", replacementRange: selectedRange())
                return true
            }
        }

        guard event.modifierFlags.contains(.command),
              let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch characters {
        case "c":
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private struct ClipboardRow: View {
    let item: PasteItem
    let index: Int
    let isSelected: Bool
    let preview: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(
                    isSelected ? ClipboardTheme.mintDeep.opacity(0.68) : ClipboardTheme.ink.opacity(0.30)
                )
                .frame(width: 12)

            Text(String(format: "%02d", index + 1))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(
                    isSelected ? ClipboardTheme.mintDeep.opacity(0.82) : ClipboardTheme.ink.opacity(0.56)
                )
                .frame(width: 28, height: 24)
                .background {
                    Capsule()
                        .fill(
                            isSelected
                                ? ClipboardTheme.mint.opacity(0.16)
                                : Color.black.opacity(0.045)
                        )
                }

            Text(preview)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? ClipboardTheme.mintDeep : ClipboardTheme.ink)
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11)
        .frame(height: ClipboardPanelView.listRowHeight)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ClipboardTheme.mint.opacity(0.18))
                    .glassEffect(
                        .regular.tint(ClipboardTheme.mint.opacity(0.24)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.32))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.82),
                                    ClipboardTheme.mint.opacity(0.64),
                                    ClipboardTheme.mintDeep.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(ClipboardTheme.mint.opacity(0.16)),
                    lineWidth: isSelected ? 1 : 0.8
                )
        }
        .shadow(
            color: isSelected ? ClipboardTheme.mint.opacity(0.26) : .clear,
            radius: isSelected ? 8 : 0,
            y: isSelected ? 2 : 0
        )
        .animation(.snappy(duration: 0.24), value: isSelected)
    }
}

private struct ClipboardDropDelegate: DropDelegate {
    let itemID: UUID
    @Binding var draggedItemID: UUID?
    let items: [PasteItem]
    let moveItems: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedItemID,
              draggedItemID != itemID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedItemID }),
              let targetIndex = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        // 拖过目标行时放到目标行后面；从下往上拖时则放到目标行前面。
        let destination = targetIndex > fromIndex ? targetIndex + 1 : targetIndex
        moveItems(IndexSet(integer: fromIndex), destination)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}

private struct TagDropDelegate: DropDelegate {
    let tagID: UUID
    @Binding var draggedTagID: UUID?
    let tags: [PasteTag]
    let moveTags: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedTagID,
              draggedTagID != tagID,
              let fromIndex = tags.firstIndex(where: { $0.id == draggedTagID }),
              let targetIndex = tags.firstIndex(where: { $0.id == tagID }) else {
            return
        }

        let destination = targetIndex > fromIndex ? targetIndex + 1 : targetIndex
        moveTags(IndexSet(integer: fromIndex), destination)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTagID = nil
        return true
    }
}

private struct AccessibilityPermissionView: View {
    @ObservedObject var viewModel: ClipboardViewModel

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.14))
                    .frame(width: 58, height: 58)
                    .glassEffect(in: Circle())

                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 6) {
                Text("需要辅助功能权限")
                    .font(.system(size: 17, weight: .bold, design: .rounded))

                Text("为了把常用文本自动粘贴到当前应用，请在系统设置的“隐私与安全性 > 辅助功能”中允许当前版本的常用粘贴板控制电脑。")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("稍后") {
                    viewModel.dismissPermissionNotice()
                }

                Button("我已授权，重新检查") {
                    viewModel.refreshAccessibilityPermission()
                }

                Button("打开系统设置") {
                    viewModel.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .background(.regularMaterial)
        .task {
            // 用户通常会先点“打开系统设置”，授权后再回到这里。
            // 轮询可以在授权生效后自动关闭弹窗，不需要额外点击“重新检查”。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                viewModel.refreshAccessibilityPermission()
            }
        }
    }
}

private enum ClipboardTheme {
    static let mint = Color(red: 0.16, green: 0.68, blue: 0.53)
    static let mintDeep = Color(red: 0.04, green: 0.34, blue: 0.25)
    static let mintSoft = Color(red: 0.78, green: 0.95, blue: 0.88)
    static let seafoam = Color(red: 0.63, green: 0.88, blue: 0.79)
    static let ink = Color(red: 0.12, green: 0.17, blue: 0.15)
}
