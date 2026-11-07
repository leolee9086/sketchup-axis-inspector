# 构建与测试

## 构建 RBZ

需要 PowerShell 7，无 npm 依赖。在仓库目录运行：

```powershell
pwsh -File scripts/build.ps1
```

输出为 `release/zhi-axis-inspector-1.2.0.rbz`。重复构建需显式加 `-Force`。包内仅包含源码、本地界面、图标、NOTICE 和完整 AGPL-3.0 许可证；测试文件不进入 RBZ。

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

## 收缩盒子回归与规模测试

安装 1.2.0 后另开一个独立测试窗口，以 `-RubyStartup <仓库>/test/shrink_startup.rb <仓库>/test/fixture.skp` 启动。该入口只使用已安装版本，依次输出 `docs/shrink-core-result.json` 和 `docs/shrink-ui-result.json`。

- 15 组核心：任意朝向的体／面／线、近对称形体及重复稳定；共享、镜像、非均匀缩放、剪切；嵌套、多选隔离与普通组共享；隐藏远端几何、锁定祖先；正反纹理 UV、孔洞、曲线、属性、实体 ID；非凸及离散内容、精细模式、关闭内部处理；空对象／参考点线；1000 个重复实例缓存复用。
- 31 项界面／事务检查：真实 CEF 开始与取消、默认值、单步撤销／重做、故障回滚、模型及选择过期、布局、嵌套编辑路径和共享定义保留。
- 原有 8 组核心、13 项基础界面、17 项嵌套和 17 项步进仍使用 `startup_test.rb` 验证，全部通过后自动接上收缩盒子的完整回归。

规模测试在同一个独立样例中加载 `test/shrink_benchmark.rb`，调用 `ZhiShrinkBenchmark.run(220)` 或 `run(450)`。分别创建约 24.2 万／101.3 万个真实线面实体，统计独立顶点、紧凑点缓存、分析和总耗时、最长分析批次及原生应用耗时；完成后用原生撤销移除测试几何。不要在测试撤销阶段手动编辑测试窗口。更大参数会创建更多真实实体，不宜直接在业务模型运行。

分析阶段使用 Fiber／计时器分批读取和搜索；最后原生 `transform_entities` 是一次不可安全中断的操作。进程内存同时包含模型、撤销栈、CEF 和其它插件，不能将点缓存字节数写成总内存。

## 公开资料范围

实际模型、绝对路径安装报告、进度笔记和测试运行输出均不提交。公开的是可复现测试代码，不是业务文件。
