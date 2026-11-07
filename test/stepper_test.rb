# encoding: UTF-8
# 真实 CEF 箭头/键盘 -> Ruby -> SketchUp 变换与原生撤销，不使用假模型。
require 'json'
module ZhiAxisStepperTest
  extend self
  API = Zhi::AxisInspector
  CORE = API::Core
  ROOT = File.expand_path('..', __dir__)

  def assert(value, text)
    raise "TEST FAILED: #{text}" unless value
    @checks << text
  end

  def output(success, error = nil)
    File.write("#{ROOT}/docs/stepper-test-result.json", JSON.pretty_generate(success:success,
      version:API::VERSION,checks:@checks,error:error,time:Time.now.to_s,pid:Process.pid))
  end

  def current_path
    @tracked_path
  end

  def origin
    CORE.world_transform(current_path).origin
  end

  def point_close(a,b)
    a.distance(b).to_f < 1e-6
  end

  def js(code)
    API.instance_variable_get(:@dialog).execute_script(code)
  end

  def click(space,axis,direction)
    js("document.querySelector('##{space}-form [data-axis=#{axis}][data-nudge=\"#{direction}\"]').click();")
  end

  # 仅通过现有 hover 通道收一帧 DOM 测试数据，立刻恢复真实预览方法。
  def dom(expression, &block)
    previous = API.method(:preview)
    API.define_singleton_method(:preview) do |data|
      API.define_singleton_method(:preview, previous)
      begin
        block.call(data)
      rescue Exception => error
        ZhiAxisStepperTest.output(false,error.full_message)
      end
    end
    js("sketchup.hover(JSON.stringify(#{expression}));")
  end

  def later(&block)
    UI.start_timer(0.25,false) do
      begin
        block.call
      rescue Exception => error
        output(false,error.full_message)
      end
    end
  end

  def run
    @checks = []
    @model = Sketchup.active_model
    assert(@model.path.tr('\\','/') == "#{ROOT}/test/fixture.skp", '仅在独立样例测试')
    @model.active_path = nil
    @model.start_operation('步进测试准备',true)
    @parent = ZhiAxisTests.box(@model.entities,component:true)
    @parent.transformation = Geom::Transformation.translation([100,200,300]) * Geom::Transformation.rotation(ORIGIN,Z_AXIS,0.7) * Geom::Transformation.scaling(-1.2,0.8,2)
    @child = ZhiAxisTests.box(@parent.definition.entities,component:true)
    @child.transformation = Geom::Transformation.translation([1.123456789,2.987654321,3.456789123])
    @twin = @model.entities.add_instance(@parent.definition,Geom::Transformation.new)
    @parent_t = @parent.transformation
    @twin_before = ZhiAxisTests.geometry(@twin)
    @world_before = CORE.world_transform([@parent,@child]).origin
    @model.commit_operation
    @model.active_path = [@parent]
    @model.selection.clear
    @model.selection.add(@child)
    API.open
    API.refresh
    later { check_controls }
  rescue Exception => error
    output(false,error.full_message)
  end

  def check_controls
    dom("{arrows:document.querySelectorAll('[data-nudge]').length,series:Array.from(document.getElementById('step-series').options).map(x=>x.value),overflow:document.documentElement.scrollWidth>innerWidth}") do |data|
      assert(data['arrows']==12,'世界与父级XYZ共12个箭头')
      assert(data['series']==['fine','building','cabinet32','board','tile'],'5类常用尺寸系列')
      assert(!data['overflow'],'新增控件无水平溢出')
      js("document.getElementById('step-series').value='cabinet32';document.getElementById('step-series').dispatchEvent(new Event('change'));document.querySelector('[data-step=\"32\"]').click();")
      later { click('world','x',1); later { after_up } }
    end
  end

  def after_up
    @tracked_path = API.instance_variable_get(:@capture).fetch(:path).dup
    expected = @world_before.offset(X_AXIS,32.0/25.4)
    assert(point_close(origin,expected),'32模数世界X增加准确')
    assert(ZhiAxisTests.geometry(@twin)==@twin_before,'共享父级另一副本不受步进影响')
    dom("{step:document.getElementById('step-value').value}") do |data|
      assert(data['step']=='32','模型刷新保留步长')
      click('world','x',-1)
      later { after_down }
    end
  end

  def after_down
    assert(point_close(origin,@world_before),'世界X减少精确还原，无跨轴舍入漂移')
    @before_parent = origin
    js("document.getElementById('step-series').value='board';document.getElementById('step-series').dispatchEvent(new Event('change'));document.querySelector('[data-step=\"18\"]').click();")
    later { click('parent','y',1); later { after_parent } }
  end

  def after_parent
    delta = Geom::Vector3d.new(0,18.0/25.4,0).transform(@parent_t)
    @after_parent = @before_parent + delta
    assert(point_close(origin,@after_parent),'父级Y步进遵循父级旋转镜像缩放')
    Sketchup.send_action('editUndo:')
    later do
      assert(point_close(origin,@before_parent),'一次撤销还原步进')
      Sketchup.send_action('editRedo:')
      later do
        assert(point_close(origin,@after_parent),'一次重做恢复步进')
        @model.active_path = @tracked_path[0...-1]
        @model.selection.clear
        @model.selection.add(@tracked_path.last)
        API.refresh
        js("document.getElementById('step-value').value='2.5cm';document.getElementById('step-value').dispatchEvent(new Event('input'));document.getElementById('world-z').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));")
        later { after_custom }
      end
    end
  end

  def after_custom
    expected = @after_parent.offset(Z_AXIS,-25.0/25.4)
    assert(point_close(origin,expected),'自定义单位步长与键盘向下移动')
    @unchanged = origin
    js("document.getElementById('step-value').value='0';")
    click('world','x',1)
    later do
      assert(point_close(origin,@unchanged),'零步长不移动')
      dom("{error:document.getElementById('status').textContent,busy:document.body.classList.contains('busy')}") do |data|
        assert(data['error'].include?('大于零') && !data['busy'],'非法步长显示错误且解除忙碌状态')
        js("document.getElementById('step-value').value='10';document.getElementById('world-x').value='999';document.getElementById('world-x').dispatchEvent(new Event('input',{bubbles:true}));")
        click('world','z',1)
        later { after_draft }
      end
    end
  end

  def after_draft
    assert(point_close(origin,@unchanged),'未应用坐标草稿时箭头不提交或覆盖草稿')
    dom("{message:document.getElementById('status').textContent,draft:document.getElementById('world-x').value}") do |data|
      assert(data['message'].include?('尚未应用') && data['draft']=='999','草稿提示与输入保留')
      js("document.getElementById('world-x').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));")
      @model.start_operation('测试锁定',true)
      current_path.last.locked = true
      @model.commit_operation
      API.refresh
      later do
        dom("{disabled:Array.from(document.querySelectorAll('[data-nudge]')).every(x=>x.disabled)}") do |data|
          assert(data['disabled'],'锁定对象禁用全部箭头')
          @model.start_operation('解除测试锁定',true)
          current_path.last.locked = false
          @model.commit_operation
          API.refresh
          output(true)
          API.instance_variable_get(:@dialog)&.close
          load File.join(__dir__,'shrink_startup.rb')
        end
      end
    end
  end
end
ZhiAxisStepperTest.run
