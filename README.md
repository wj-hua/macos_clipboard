# 常用粘贴板

一个原生 macOS 菜单栏常用文本工具，最低支持 macOS 26。

计划开发的功能与优先级见 [开发路线图](ROADMAP.md)。

## 使用方式

1. 用 Xcode 打开 `CommonClipboard.xcodeproj` 并运行 `CommonClipboard` scheme。
2. 应用启动后会出现在菜单栏，不显示 Dock 图标。
3. 在任意其他应用中按 `Option + 空格` 打开浮动面板。
4. 面板打开后可直接输入关键词搜索；支持搜索当前标签或全部标签，也可按 `Command + F` 聚焦搜索框。使用上下方向键或纵向滚轮选择文本，使用左右方向键或侧向滚轮切换标签（也支持 `Shift + 滚轮`）；按 `Command + C` 只复制选中项，不会自动粘贴。按 `Option + 1` 到 `Option + 9` 可直接将对应搜索结果粘贴到当前输入框，按回车粘贴当前选中项。齿轮菜单可将双击行为设为“自动粘贴”或“仅复制”。搜索时按一次 `Esc` 清空关键词，再按一次关闭面板。
5. 文本列表上方可按标签筛选常用文本；默认只有“默认”标签时会隐藏标签栏，可通过标题区的标签按钮添加新标签。拥有多个标签后，标签栏支持添加、删除和拖拽排序；删除标签时其中的文本会转移到“默认”标签。
6. 通过菜单栏图标或面板底部按钮添加、编辑、删除文本，也可以拖拽调整文本顺序。
7. 点击面板以外的位置会自动收起面板；点击面板内的空白处不会收起，也不会穿透到下方应用。
8. 在面板的空白处（标题栏、底栏留白等非按钮区域）直接拖动，即可移动面板位置；按钮、文本列表和文本编辑器保留各自的点击与拖拽行为，标签栏依旧是长按拖动排序。

首次使用回车或 `Option + 1` 到 `Option + 9` 粘贴时，系统会要求在“系统设置 > 隐私与安全性 > 辅助功能”中允许“常用粘贴板”控制电脑。开启权限后再次操作即可完成自动粘贴。

## 命令行构建与测试

```bash
xcodebuild -project CommonClipboard.xcodeproj \
  -scheme CommonClipboard \
  -configuration Debug \
  -sdk macosx \
  build

xcodebuild -project CommonClipboard.xcodeproj \
  -scheme CommonClipboard \
  -configuration Debug \
  -sdk macosx \
  test
```

运行和测试都不要使用 `CODE_SIGNING_ALLOWED=NO`，否则可能会把同一个 DerivedData 目录里的 App 产物覆盖成无签名版本，导致辅助功能权限失效。测试 target 已经配置为不需要签名。

文本数据保存在：

`~/Library/Application Support/com.mino.CommonClipboard/items.json`

首次升级到标签版本时，应用会自动将旧格式中的所有文本迁移到“默认”标签。
