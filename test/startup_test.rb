# encoding: UTF-8
require 'sketchup.rb'
require 'json'
# 最终测试只使用已经安装并自动加载的扩展，不加载开发源码作兜底。
raise '扩展没有随 SketchUp 启动加载' unless defined?(Zhi::AxisInspector::EXTENSION) && Zhi::AxisInspector::EXTENSION.loaded?
load File.join(__dir__, 'core_in_sketchup.rb')

module ZhiAxisStartupTest
  extend self
  ROOT = File.expand_path('..', __dir__)
  def assert(value, text)
    raise "TEST FAILED: #{text}" unless value
  end
  def report(name, data)
    require 'fileutils'
    FileUtils.mkdir_p("#{ROOT}/docs")
    File.write("#{ROOT}/docs/#{name}.json",JSON.pretty_generate(data.merge(time:Time.now.to_s,pid:Process.pid)))
  end
  def run
    @model = Sketchup.active_model
    assert(@model.path.tr('\\','/') == "#{ROOT}/test/fixture.skp", '只操作独立测试文件')
    result = ZhiAxisTests.run(@model)
    report('core-test-result',result)
    return unless result[:success]
    @model.start_operation('准备交互测试',true)
    @object = ZhiAxisTests.box(@model.entities,component:true)
    @object.name = '轴点测试 · 示例组件'
    @object.transformation = Geom::Transformation.translation([100,50,20])
    @model.commit_operation
    @before = ZhiAxisTests.geometry(@object)
    @before_t = @object.transformation
    @model.selection.clear
    @model.selection.add(@object)
    Zhi::AxisInspector.open
    UI.start_timer(1.0,false) { dialog_ready }
  rescue Exception => e
    report('integration-test-result',{success:false,stage:'run',error:e.full_message})
  end
  def dialog_ready
    api = Zhi::AxisInspector
    assert(api.instance_variable_get(:@ready),'HtmlDialog 实际完成 ready 回调')
    assert(api.instance_variable_get(:@overlay).valid?,'真实 Overlay 注册')
    dialog = api.instance_variable_get(:@dialog)
    # 通过实际 CEF 的 DOM 点击 → JS → Ruby 回调，不伪造 SketchUp 服务。
    dialog.execute_script("document.querySelector('#face-buttons [data-point=center]').click()")
    UI.start_timer(0.6,false) { after_axis }
  rescue Exception => e
    report('integration-test-result',{success:false,stage:'dialog_ready',error:e.full_message})
  end
  def after_axis
    assert(ZhiAxisTests.geometry(@object)==@before,'真实UI改轴后世界几何不变')
    assert(!Zhi::AxisInspector::Core.same_transform?(@object.transformation,@before_t),'真实UI改轴已改变轴点')
    Sketchup.send_action('editUndo:')
    UI.start_timer(0.4,false) { after_undo }
  rescue Exception => e
    report('integration-test-result',{success:false,stage:'after_axis',error:e.full_message})
  end
  def after_undo
    assert(Zhi::AxisInspector::Core.same_transform?(@object.transformation,@before_t),'单步撤销轴点')
    assert(ZhiAxisTests.geometry(@object)==@before,'单步撤销几何')
    Sketchup.send_action('editRedo:')
    UI.start_timer(0.4,false) { after_redo }
  rescue Exception => e
    report('integration-test-result',{success:false,stage:'after_undo',error:e.full_message})
  end
  def after_redo
    assert(!Zhi::AxisInspector::Core.same_transform?(@object.transformation,@before_t),'单步重做轴点')
    assert(ZhiAxisTests.geometry(@object)==@before,'单步重做几何')
    @axis_t = @object.transformation
    dialog = Zhi::AxisInspector.instance_variable_get(:@dialog)
    dialog.execute_script("document.getElementById('world-x').value='1234';document.getElementById('world-y').value='2345';document.getElementById('world-z').value='3456';document.getElementById('world-form').requestSubmit();")
    UI.start_timer(0.5,false) { after_position }
  rescue Exception => e
    report('integration-test-result',{success:false,stage:'after_redo',error:e.full_message})
  end
  def after_position
    assert(ZhiAxisTests.near(@object.transformation.origin,[1234,2345,3456].map{|n|n/25.4}),'世界坐标真实UI移动')
    assert(@object.transformation.xaxis.parallel?(@axis_t.xaxis),'坐标编辑不转轴')
    Sketchup.send_action('editUndo:')
    UI.start_timer(0.4,false) { finish }
  rescue Exception => e
    report('integration-test-result',{success:false,stage:'after_position',error:e.full_message})
  end
  def finish
    api = Zhi::AxisInspector
    assert(api::Core.same_transform?(@object.transformation,@axis_t),'坐标移动单步撤销')
    assert(ZhiAxisTests.geometry(@object)==@before,'坐标撤销后几何')
    @model.selection.clear
    UI.start_timer(0.3,false) do
      begin
        assert(api.instance_variable_get(:@capture).nil?,'选择清空后实时刷新')
        @model.selection.add(@object)
        api.refresh
        snapshot = api.instance_variable_get(:@capture)
        revision = api.instance_variable_get(:@revision)
        rejected = false
        begin
          api.fresh!('revision'=>revision-1)
        rescue api::AxisError
          rejected = true
        end
        assert(rejected,'过期UI请求拒绝')
        # 故障注入测试真实 abort：不允许部分几何留在模型中。
        check = api::Core.method(:same_transform?)
        rejected = false
        begin
          api::Core.define_singleton_method(:same_transform?){|_a,_b|false}
          api::Core.move(@model, snapshot[:path],'c7')
        rescue api::AxisError
          rejected = true
        ensure
          api::Core.define_singleton_method(:same_transform?,check)
        end
        assert(rejected && ZhiAxisTests.geometry(@object)==@before,'失败整体回滚')
        api.show_toolbar
        assert(api.instance_variable_get(:@toolbar).visible?,'工具栏可见')
        api.refresh
        report('integration-test-result',{success:true,checks:['已安装扩展冷启动','真实HtmlDialog ready','Overlay注册','CEF按钮→Ruby改轴','世界几何原位','单步撤销','单步重做','CEF表单→世界坐标移动','坐标移动撤销','选择实时刷新','过期请求拒绝','故障整体回滚','工具栏可见']})
        load "#{ROOT}/test/nested_ui_test.rb"
      rescue Exception => e
        report('integration-test-result',{success:false,stage:'finish',error:e.full_message})
      end
    end
  rescue Exception => e
    report('integration-test-result',{success:false,stage:'finish_outer',error:e.full_message})
  end
end
UI.start_timer(3.0,false) { ZhiAxisStartupTest.run }
