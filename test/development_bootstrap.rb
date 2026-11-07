# encoding: UTF-8
# 开发回归入口：只在 fixture.skp 中使用源码；正式冷启动验收用 startup_test.rb。
raise '需要先安装扩展' unless defined?(Zhi::AxisInspector::EXTENSION)
Zhi::AxisInspector.send(:remove_const, :VERSION) if Zhi::AxisInspector.const_defined?(:VERSION)
load File.expand_path('../src/zhi_axis_inspector/core.rb', __dir__)
load File.expand_path('../src/zhi_axis_inspector/main.rb', __dir__)
load File.join(__dir__, 'startup_test.rb')
