# encoding: UTF-8
require 'json'
module ZhiShrinkUITests
  extend self
  ROOT=File.expand_path('..',__dir__)
  API=Zhi::AxisInspector
  UIAPI=API::ShrinkUI
  def assert(value,message); raise "TEST FAILED: #{message}" unless value; @checks << message; end
  def report(error=nil)
    File.write("#{ROOT}/docs/shrink-ui-result.json",JSON.pretty_generate(success:error.nil?,checks:@checks,error:error&.full_message,pid:Process.pid,time:Time.now.to_s))
  end
  def later(&block)
    UI.start_timer(0.15,false) do
      begin; block.call; rescue Exception=>error; report(error); end
    end
  end
  def run
    @model=Sketchup.active_model; @checks=[]
    raise 'Only fixture' unless @model.path.tr('\\','/')=="#{ROOT}/test/fixture.skp"
    @model.active_path=nil if @model.active_path
    @model.start_operation('准备收缩UI测试',true)
    @object=ZhiShrinkTests.shape(@model.entities).to_component
    @twin=@model.entities.add_instance(@object.definition,Geom::Transformation.translation([500,0,0])*Geom::Transformation.scaling(-2,0.6,3))
    @model.commit_operation
    @original=@object.transformation; @definition=@object.definition
    @before=[ZhiShrinkTests.geometry(@object),ZhiShrinkTests.geometry(@twin)]
    @model.selection.clear; @model.selection.add(@object)
    UIAPI.open
    later { ready }
  rescue Exception=>error
    report(error)
  end
  # CEF 只在页面载入时注入已注册回调。借现有 start 通道读 DOM，
  # 收到数据即恢复方法；实际开始、取消和模型 API 均运行正式实现。
  def dom(expression,&block)
    previous=UIAPI.method(:start)
    UIAPI.define_singleton_method(:start) do |data|
      UIAPI.define_singleton_method(:start,previous)
      begin; block.call(data); rescue Exception=>error; ZhiShrinkUITests.report(error); end
    end
    @dialog.execute_script("window.sketchup.shrink_start(JSON.stringify(#{expression}))")
  end
  def ready
    unless UIAPI.instance_variable_get(:@ready)
      later { ready }; return
    end
    @dialog=UIAPI.instance_variable_get(:@dialog)
    assert(@dialog.visible?,'收缩HtmlDialog真实加载')
    dom("{scope:document.getElementById('scope').value,nested:document.getElementById('nested').checked,quality:document.getElementById('quality').value}") do |state|
      assert(state['scope']=='linked','默认修改所有相关定义')
      assert(state['nested']==true,'默认考虑内部轴向')
      assert(state['quality']=='fast','默认快速计算')
      @dialog.execute_script("document.getElementById('options').requestSubmit()")
      later { wait_done { after_apply } }
    end
  end
  def wait_done(&block)
    if UIAPI.instance_variable_get(:@job)
      later { wait_done(&block) }; return
    end
    job=UIAPI.instance_variable_get(:@last_job)
    raise 'UI job did not start' unless job
    raise job.error if job.error
    block.call
  end
  def after_apply
    assert(!API::Core.same_transform?(@object.transformation,@original),'CEF开始按钮→Ruby真实收缩')
    assert(@object.definition==@definition && @twin.definition==@definition,'默认联动保留共享')
    assert(ZhiShrinkTests.unchanged(@before[0],ZhiShrinkTests.geometry(@object)) && ZhiShrinkTests.unchanged(@before[1],ZhiShrinkTests.geometry(@twin)),'UI全部实例世界几何保持')
    assert(@model.selection.to_a==[@object],'恢复所选对象')
    Sketchup.send_action('editUndo:')
    later { after_undo }
  end
  def after_undo
    assert(API::Core.same_transform?(@object.transformation,@original),'收缩单步撤销轴点轴向')
    assert(ZhiShrinkTests.unchanged(@before[0],ZhiShrinkTests.geometry(@object)),'撤销后世界几何一致')
    Sketchup.send_action('editRedo:')
    later { after_redo }
  end
  def after_redo
    assert(!API::Core.same_transform?(@object.transformation,@original),'收缩单步重做')
    assert(ZhiShrinkTests.unchanged(@before[1],ZhiShrinkTests.geometry(@twin)),'重做后共享实例原位')
    # 只替换校验点注入失败，事务、几何和撤销均为真实 SketchUp。
    Sketchup.send_action('editUndo:')
    later { failure_and_cancel }
  end
  def failure_and_cancel
    analysis=API::Shrink::Analysis.new(API::Shrink.capture(@model)).run
    original=API::Core.method(:same_transform?)
    failed=false
    begin
      API::Core.define_singleton_method(:same_transform?) { |_a,_b| false }
      API::Shrink.apply(analysis)
    rescue API::AxisError
      failed=true
    ensure
      API::Core.define_singleton_method(:same_transform?,original)
    end
    assert(failed && API::Core.same_transform?(@object.transformation,@original),'故障注入完整事务回滚')
    assert(ZhiShrinkTests.unchanged(@before[0],ZhiShrinkTests.geometry(@object)),'回滚恢复全部几何')
    capture=API::Shrink.capture(@model)
    job=UIAPI::Job.new(capture,{quality: :fine,nested:true,scope: :linked}) { |*_| }
    job.cancelled=true; job.tick
    assert(job.error.is_a?(API::Shrink::Cancelled),'计算可取消')
    assert(API::Core.same_transform?(@object.transformation,@original),'取消不修改模型')
    stale=UIAPI::Job.new(capture,{quality: :fine,nested:true,scope: :linked}) { |*_| }
    @model.start_operation('测试期间模型修改',true); @object.name='变化'; @model.commit_operation
    stale.tick
    assert(stale.error.is_a?(API::AxisError),'模型变化使计算失效')
    assert(API::Core.same_transform?(@object.transformation,@original),'失效计算不应用旧结果')
    selection=UIAPI::Job.new(API::Shrink.capture(@model),{quality: :fast,nested:true,scope: :linked}) { |*_| }
    @model.selection.clear; selection.tick
    assert(selection.error.is_a?(API::AxisError),'选择变化拒绝旧结果')
    @model.selection.add(@object)
    @dialog.execute_script("document.getElementById('quality').value='fine';document.getElementById('options').requestSubmit();window.sketchup.shrink_cancel()")
    later { check_cancel_button }
  end
  def check_cancel_button
    if UIAPI.instance_variable_get(:@job)
      later { check_cancel_button }; return
    end
    assert(UIAPI.instance_variable_get(:@last_job).error.is_a?(API::Shrink::Cancelled),'CEF取消回调生效')
    assert(API::Core.same_transform?(@object.transformation,@original),'界面取消原位且无改轴')
    dom("{overflow:document.documentElement.scrollWidth>window.innerWidth,startEnabled:!document.getElementById('start').disabled,cancelHidden:document.getElementById('progress').hidden}") do |data|
      assert(data['overflow']==false,'收缩界面无水平溢出')
      assert(data['startEnabled'],'结束后可再次执行')
      assert(data['cancelHidden'],'结束后隐藏取消按钮')
      nested_run
    end
  end
  def nested_run
    @dialog.close
    @model.active_path=nil if @model.active_path
    @model.start_operation('准备嵌套收缩测试',true)
    @parent=@model.entities.add_group.to_component
    @parent.transformation=Geom::Transformation.translation([100,200,300])*Geom::Transformation.rotation(ORIGIN,[3,1,2],0.51)*Geom::Transformation.scaling(-2,0.7,3)
    @nested=ZhiShrinkTests.shape(@parent.definition.entities).to_component
    @nested_t=@nested.transformation
    @nested_bounds=API::Shrink.bounds_array(@nested.definition.bounds)
    @parent_twin=@model.entities.add_instance(@parent.definition,Geom::Transformation.translation([-300,500,0]))
    @nested_definition=@nested.definition
    @model.commit_operation
    @model.active_path=[@parent];@model.selection.clear;@model.selection.add(@nested)
    analysis=API::Shrink::Analysis.new(API::Shrink.capture(@model)).run
    API::Shrink.apply(analysis)
    assert(@model.active_path==[@parent] && @model.selection.to_a==[@nested],'嵌套收缩恢复编辑路径与选择')
    assert(@nested.definition==@nested_definition && @parent.definition==@parent_twin.definition,'嵌套联动保留父子定义')
    Sketchup.send_action('editUndo:')
    later { nested_undo }
  end
  def nested_undo
    assert(@model.active_path==[@parent],'嵌套单步撤销恢复编辑路径')
    bounds=API::Shrink.bounds_array(@nested.definition.bounds)
    assert(bounds.flatten.zip(@nested_bounds.flatten).all? { |a,b| (a-b).abs<1e-6 },'嵌套单步撤销恢复原外框')
    local=@model.edit_transform.inverse*@nested.transformation
    assert(API::Core.same_transform?(local,@nested_t),'嵌套撤销恢复实例变换')
    Sketchup.send_action('editRedo:')
    later do
      assert(@model.active_path==[@parent],'嵌套单步重做恢复编辑路径')
      now=API::Shrink.bounds_array(@nested.definition.bounds)
      assert(API::Shrink::Math3.better?(now,@nested_bounds,API::Shrink.epsilon(@nested_bounds)),'嵌套重做恢复紧密外框')
      @model.active_path=nil
      report
    end
  end
end
ZhiShrinkUITests.run
