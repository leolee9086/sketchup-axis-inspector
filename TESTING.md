# 构建与测试

## 构建 RBZ

需要 PowerShell 7，无 npm 依赖。在仓库目录运行：

```powershell
pwsh -File scripts/build.ps1
```

输出为 `release/zhi-axis-inspector-1.1.0.rbz`。重复构建需显式加 `-Force`。包内仅包含源码、本地界面、图标、NOTICE 和完整 AGPL-3.0 许可证；测试文件不进入 RBZ。

## 真实 SketchUp 回归

SketchUp Ruby API 不能用普通系统 Ruby 模拟。测试使用实际模型、HtmlDialog CEF、Overlay、原生撤销／重做。

- 先构建并安装待测 RBZ。
- 启动一个**独立空白 SketchUp 窗口**。从 Ruby 控制台加载本仓库的 `test/create_fixture.rb`（路径改为自己的绝对路径）。此脚本拒绝非空模型，拒绝覆盖已有样例。
- 关闭该测试窗口，再使用 SketchUp 的 `-RubyStartup` 加载 `test/startup_test.rb`，同时打开刚生成的 `test/fixture.skp`。

Windows 示例（路径需按本机修改）：

```powershell
& 'C:/Program Files/SketchUp/SketchUp 2024/SketchUp.exe' `
  -RubyStartup 'C:/projects/sketchup-axis-inspector/test/startup_test.rb' `
  'C:/projects/sketchup-axis-inspector/test/fixture.skp'
```

测试严格核对文件路径，只在仓库内的测试样例运行。报告写入忽略版本控制的 `docs/`，包含核心、基础界面、嵌套界面和步进四份 JSON。测试完成后关闭窗口，不保存试验变更。

开发阶段可使用 `test/development_bootstrap.rb` 加载工作树；发布验收必须使用 `test/startup_test.rb`，确认真正安装版本冷启动加载。

## 覆盖范围

- 15 点原位改轴：旋转、镜像、非均匀缩放、共享定义与嵌套父路径。
- 世界／父级坐标与尺寸、显式单位、元数据、临时标识清理、锁定／非法对象拒绝。
- CEF 实际按钮、表单与 Ruby 回调；Overlay 预览、选择刷新、过期请求拒绝。
- 原生单步撤销、重做、故障注入整体回滚。
- 世界／父级 XYZ 的 12 个箭头、5 类预设、32 mm 和 18 mm 预设、自定义单位、键盘步进。
- 未修改坐标精度、共享副本不变、零步长拒绝、草稿保留、锁定禁用及无水平溢出。

## 公开资料范围

实际模型、绝对路径安装报告、进度笔记和测试运行输出均不提交。公开的是可复现测试代码，不是业务文件。
