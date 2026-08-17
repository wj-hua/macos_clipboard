import SwiftUI
import XCTest

@testable import CommonClipboard

final class TagBarLayoutTests: XCTestCase {
    private func tag(_ name: String) -> PasteTag {
        PasteTag(name: name)
    }

    /// 换行排版依赖 `chipWidth` 的估算值。估算一旦偏小，标签就会重新被面板宽度裁掉，
    /// 所以这里拿真实 SwiftUI 布局出来的宽度做上界校验。
    func testChipWidthEstimateIsNeverSmallerThanRenderedWidth() {
        let tags = [
            PasteTag.defaultTag,
            tag("Git"),
            tag("英文版"),
            tag("经济日报"),
            tag("全部"),
            tag("A"),
            tag("English Translation"),
            tag("很长很长的一个标签名称"),
        ]

        for tag in tags {
            let rendered = renderedChipWidth(for: tag)
            let estimated = TagBarMetrics.chipWidth(for: tag)
            XCTAssertGreaterThanOrEqual(
                estimated,
                rendered,
                "标签「\(tag.name)」估算宽度 \(estimated) 小于实际渲染宽度 \(rendered)"
            )
        }
    }

    func testRowsNeverExceedContentWidth() {
        let tags = [PasteTag.defaultTag]
            + ["Git", "英文版", "经济日报", "全部", "工作", "学习", "临时", "Prompt 模板"].map(tag)

        for row in TagBarMetrics.rows(for: tags) {
            let width = row.reduce(CGFloat(0)) { partial, entry in
                let entryWidth: CGFloat
                switch entry {
                case .tag(let tag):
                    entryWidth = min(TagBarMetrics.chipWidth(for: tag), TagBarMetrics.contentWidth)
                case .addButton:
                    entryWidth = TagBarMetrics.addButtonSize
                }
                return partial + entryWidth
            }
            let spacing = TagBarMetrics.itemSpacing * CGFloat(row.count - 1)
            XCTAssertLessThanOrEqual(width + spacing, TagBarMetrics.contentWidth)
        }
    }

    func testAddButtonAlwaysFollowsLastTag() {
        let tags = [PasteTag.defaultTag] + ["Git", "英文版", "经济日报", "全部"].map(tag)
        let rows = TagBarMetrics.rows(for: tags)

        XCTAssertEqual(rows.last?.last?.id, TagBarEntry.addButton.id)
        let addButtonCount = rows.flatMap { $0 }.filter { $0.id == TagBarEntry.addButton.id }.count
        XCTAssertEqual(addButtonCount, 1)
    }

    func testBarHeightGrowsWithRowCount() {
        let singleRow = [PasteTag.defaultTag, tag("Git")]
        let manyTags = [PasteTag.defaultTag]
            + (1...12).map { tag("标签\($0)") }

        XCTAssertEqual(TagBarMetrics.rows(for: singleRow).count, 1)
        XCTAssertGreaterThan(TagBarMetrics.rows(for: manyTags).count, 1)
        XCTAssertGreaterThan(
            TagBarMetrics.barHeight(for: manyTags),
            TagBarMetrics.barHeight(for: singleRow)
        )
    }

    /// 面板高度必须包含标签栏的全部行，否则多出来的行会被窗口边界裁掉。
    func testPanelHeightIncludesEveryTagRow() {
        let manyTags = [PasteTag.defaultTag] + (1...12).map { tag("标签\($0)") }
        let singleRow = [PasteTag.defaultTag, tag("Git")]

        let tallPanel = ClipboardPanelView.panelHeight(for: 5, tags: manyTags, mode: .list)
        let shortPanel = ClipboardPanelView.panelHeight(for: 5, tags: singleRow, mode: .list)

        XCTAssertEqual(
            tallPanel - shortPanel,
            TagBarMetrics.barHeight(for: manyTags) - TagBarMetrics.barHeight(for: singleRow),
            accuracy: 0.5
        )
    }

    /// 标签栏变高时列表要让位，否则面板会长到屏幕可视区域之外，底栏按钮点不到。
    func testTallTagBarShrinksTheListToKeepThePanelWithinItsBudget() {
        let manyTags = [PasteTag.defaultTag] + (1...20).map { tag("标签\($0)") }
        let fullList = ClipboardPanelView.maximumListRows

        XCTAssertGreaterThan(TagBarMetrics.rows(for: manyTags).count, 3, "用例需要一个足够高的标签栏")
        XCTAssertLessThan(
            ClipboardPanelView.visibleListRows(
                for: fullList,
                tagBarHeight: TagBarMetrics.barHeight(for: manyTags)
            ),
            fullList,
            "标签栏挤占空间时列表行数应该减少"
        )
        XCTAssertLessThanOrEqual(
            ClipboardPanelView.panelHeight(for: fullList, tags: manyTags, mode: .list),
            ClipboardPanelView.maxPanelHeight,
            "面板高度不能超出预算"
        )
    }

    /// 标签多到连最小列表都塞不下时高度仍会超预算（由 `PanelController` 兜底摆回屏幕内），
    /// 但面板的增长必须明显慢于标签栏本身，说明列表确实在让位。
    func testPanelGrowsSlowerThanTheTagBar() {
        let manyTags = [PasteTag.defaultTag] + (1...40).map { tag("标签\($0)") }
        let singleRow = [PasteTag.defaultTag, tag("Git")]
        let fullList = ClipboardPanelView.maximumListRows

        let panelGrowth = ClipboardPanelView.panelHeight(for: fullList, tags: manyTags, mode: .list)
            - ClipboardPanelView.panelHeight(for: fullList, tags: singleRow, mode: .list)
        let barGrowth = TagBarMetrics.barHeight(for: manyTags) - TagBarMetrics.barHeight(for: singleRow)

        XCTAssertLessThan(panelGrowth, barGrowth)
        XCTAssertEqual(
            ClipboardPanelView.visibleListRows(
                for: fullList,
                tagBarHeight: TagBarMetrics.barHeight(for: manyTags)
            ),
            ClipboardPanelView.minimumListRows,
            "压缩到最小行数为止，不能再少"
        )
    }

    /// 反向对照：标签栏只有一行时不该白白砍掉列表行。
    func testShortTagBarKeepsTheFullList() {
        let tags = [PasteTag.defaultTag, tag("Git")]

        XCTAssertEqual(TagBarMetrics.rows(for: tags).count, 1)
        XCTAssertEqual(
            ClipboardPanelView.visibleListRows(
                for: ClipboardPanelView.maximumListRows,
                tagBarHeight: TagBarMetrics.barHeight(for: tags)
            ),
            ClipboardPanelView.maximumListRows
        )
    }

    func testPanelHeightIgnoresTagBarWhenOnlyDefaultTagExists() {
        let withTagBar = ClipboardPanelView.panelHeight(for: 5, tags: [PasteTag.defaultTag, tag("Git")], mode: .list)
        let withoutTagBar = ClipboardPanelView.panelHeight(for: 5, tags: [PasteTag.defaultTag], mode: .list)

        XCTAssertLessThan(withoutTagBar, withTagBar)
    }

    /// 用真实 SwiftUI 布局量一个和 `tagChip` 结构一致的胶囊。
    private func renderedChipWidth(for tag: PasteTag) -> CGFloat {
        let chip = HStack(spacing: 0) {
            HStack(spacing: TagBarMetrics.chipIconSpacing) {
                Image(systemName: TagBarMetrics.symbolName(for: tag))
                    .font(.system(size: TagBarMetrics.chipIconSize, weight: .semibold))

                Text(tag.name)
                    .font(.system(size: TagBarMetrics.chipTextSize, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.leading, TagBarMetrics.chipLeadingPadding)
            .padding(
                .trailing,
                tag.isDefault ? TagBarMetrics.chipLeadingPadding : TagBarMetrics.chipTrailingPadding
            )
            .frame(height: TagBarMetrics.chipHeight)

            if !tag.isDefault {
                Rectangle()
                    .frame(width: TagBarMetrics.chipDividerWidth, height: 16)

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: TagBarMetrics.chipDeleteButtonWidth, height: TagBarMetrics.chipHeight)
            }
        }

        let hostingView = NSHostingView(rootView: chip)
        return hostingView.fittingSize.width
    }
}
