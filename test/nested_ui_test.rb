# encoding: UTF-8
require 'json'

module ZhiAxisNestedUITest
  extend self
  API = Zhi::AxisInspector
  CORE = API::Core
  ROOT = File.expand_path('..', __dir__)

  def assert(value, text)
    raise "TEST FAILED: #{text}" unless value
    @checks << text
  end

  def output(success, error = nil)
    File.write("#{ROOT}/docs/nested-ui-test-result.json", JSON.pretty_generate(success:success,
      checks:@checks,error:error,time:Time.now.to_s,pid:Process.pid,dom:@dom))
  end

  def run
    @checks = []
    @model = Sketchup.active_model
    assert(@model.path.tr('\\','/') == "#{ROOT}/test/fixture.skp", '只操作隔离样例')
    @model.active_path = nil
    @model.start_operation('嵌套UI场景准备',true)
    @parent = ZhiAxisTests.box(@model.entities,component:true)
    @parent.name = '旋转缩放共享父组件'
    @parent.transformation = Geom::Transformation.translation([300,120,40]) * Geom::Transformation.rotation(ORIGIN,Z_AXIS,0.4) * Geom::Transformation.scaling(2,0.7,1.2)
    @child = ZhiAxisTests.box(@parent.definition.entities,component:true)
    @child.name = '坐标编辑目标'
    @child.transformation = Geom::Transformation.translation([12,23,34]) * Geom::Transformation.rotation(ORIGIN,X_AXIS,0.2)
    @definition = @parent.definition
    @child_definition = @child.definition
    @twin = @model.entities.add_instance(@definition, Geom::Transformation.translation([-300,0,0]))
    @model.commit_operation
    @old_twin = ZhiAxisTests.geometry(@twin)
    @old_parent = ZhiAxisTests.geometry(@parent)
    @expected_world = CORE.mm(CORE.world_transform([@parent,@child]).origin)
    @expected_parent = CORE.mm(@child.transformation.origin)
    @model.active_path = [@parent]
    @model.selection.clear
    @model.selection.add(@child)
    API.open
    UI.start_timer(0.3,false) { inspect_dialog }
  rescue Exception => e
    output(false,e.full_message)
  end

  def inspect_dialog
    API.refresh
    dialog = API.instance_variable_get(:@dialog)
    original_preview = API.method(:preview)
    # CEF 初始化后新增 action_callback 不会加入当前页面桥接；通过既有 hover
    # 通道传一次测试遥测，马上恢复真实 preview。生产代码和 SketchUp 服务不替换。
    API.define_singleton_method(:preview) do |data|
      API.define_singleton_method(:preview, original_preview)
      ZhiAxisNestedUITest.receive_dom(data, dialog)
    end
    dialog.execute_script("sketchup.hover(JSON.stringify({world:['x','y','z'].map(k=>document.getElementById('world-'+k).value),parent:['x','y','z'].map(k=>document.getElementById('parent-'+k).value),buttons:document.querySelectorAll('.point-grid button').length,svg_points:document.querySelectorAll('#cube-points [role=button]').length,overflow:document.documentElement.scrollWidth>innerWidth,disabled:document.getElementById('parent-x').disabled}));")
  rescue Exception => e
    output(false,e.full_message)
  end

  def receive_dom(data, dialog)
      begin
        @dom = data
        assert(@dom['world'].map(&:to_f) == @expected_world, '嵌套编辑时世界坐标显示准确')
        assert(@dom['parent'].map(&:to_f) == @expected_parent, '嵌套编辑时父级坐标显示准确')
        assert(@dom['buttons'] == 15 && @dom['svg_points'] == 15, '15按钮与15图示点完整')
        assert(@dom['overflow'] == false, '面板无水平溢出')
        assert(@dom['disabled'] == false, '嵌套对象坐标可编辑')
        dialog.execute_script("document.getElementById('parent-x').value='100';document.getElementById('parent-y').value='200';document.getElementById('parent-z').value='300';document.getElementById('parent-form').requestSubmit();")
        UI.start_timer(0.4,false) { after_parent_move }
      rescue Exception => e
        output(false,e.full_message)
      end
  end

  def after_parent_move
    @moved = @model.selection.to_a.first
    assert(@model.active_path == [@parent], '移动后恢复原编辑路径')
    assert(@parent.definition != @definition && @twin.definition == @definition, '仅当前父级独立化')
    # 此处不为了检查而切换 active_path，否则测试本身会插入新的撤销记录。
    assert(ZhiAxisTests.geometry(@twin) == @old_twin, '共享父级另一副本未移动')
    assert(CORE.info(model:@model,path:[@parent,@moved])[:parent_origin] == [100.0,200.0,300.0], '父级坐标输入实际移动物体')
    assert(@moved.definition == @child_definition, '坐标移动保留子组件定义')
    Sketchup.send_action('editUndo:')
    UI.start_timer(0.4,false) { after_position_undo }
  rescue Exception => e
    output(false,e.full_message)
  end

  def after_position_undo
    @model.active_path = nil
    assert(@parent.definition == @definition, '一次撤销恢复共享父定义')
    assert(ZhiAxisTests.geometry(@parent) == @old_parent, '一次撤销恢复父级完整几何')
    @model.active_path = [@parent]
    @model.selection.clear
    @model.selection.add(@child)
    API.refresh
    API.instance_variable_get(:@dialog).execute_script("document.querySelector('#face-buttons [data-point=zp]').dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));")
    UI.start_timer(0.3,false) { check_hover }
  rescue Exception => e
    output(false,e.full_message)
  end

  def check_hover
    overlay = API.instance_variable_get(:@overlay)
    assert(overlay.point_key == 'zp' && overlay.geometry[2], '悬停回调更新真实视图预览')
    API.instance_variable_get(:@dialog).execute_script("document.querySelector('#face-buttons [data-point=zp]').click();")
    UI.start_timer(0.4,false) { after_axis }
  rescue Exception => e
    output(false,e.full_message)
  end

  def after_axis
    assert(@model.active_path == [@parent], '原位改轴后恢复嵌套编辑')
    assert(ZhiAxisTests.geometry(@parent) == @old_parent && ZhiAxisTests.geometry(@twin) == @old_twin, '嵌套CEF改轴全部世界几何不变')
    Sketchup.send_action('editUndo:')
    UI.start_timer(0.4,false) do
      begin
        assert(@parent.definition == @definition, '嵌套改轴单步撤销恢复共享关系')
        @model.active_path = [@parent]
        @model.selection.clear
        @model.selection.add(@child)
        API.refresh
        output(true)
        load File.join(__dir__, 'stepper_test.rb')
      rescue Exception => e
        output(false,e.full_message)
      end
    end
  rescue Exception => e
    output(false,e.full_message)
  end
end
ZhiAxisNestedUITest.run
