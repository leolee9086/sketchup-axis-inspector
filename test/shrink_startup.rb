# encoding: UTF-8
require 'sketchup.rb'
require 'json'
# 独立冷启动入口，仅运行已安装版本；没有源码兜底加载。
raise '插件没有正常加载' unless defined?(Zhi::AxisInspector::EXTENSION) && Zhi::AxisInspector::EXTENSION.loaded?
raise '需要安装 1.2.0' unless Zhi::AxisInspector::VERSION=='1.2.0' && defined?(Zhi::AxisInspector::ShrinkUI)
UI.start_timer(3,false) do
  root=File.expand_path('..',__dir__)
  model=Sketchup.active_model
  begin
    raise 'Only fixture' unless model.path.tr('\\','/')=="#{root}/test/fixture.skp"
    model.active_path=nil if model.active_path
    load File.join(__dir__,'shrink_in_sketchup.rb')
    result=ZhiShrinkTests.run(model)
    File.write("#{root}/docs/shrink-core-result.json",JSON.pretty_generate(result))
    if result[:success]
      load File.join(__dir__,'shrink_ui_test.rb')
    end
  rescue Exception=>error
    File.write("#{root}/docs/shrink-startup-error.json",JSON.pretty_generate(success:false,error:error.full_message,pid:Process.pid,time:Time.now.to_s))
  end
end
