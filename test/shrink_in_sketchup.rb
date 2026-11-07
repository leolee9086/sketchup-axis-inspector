# encoding: UTF-8
require 'json'
module ZhiShrinkTests
  extend self
  S=Zhi::AxisInspector::Shrink
  M=S::Math3
  C=Zhi::AxisInspector::Core
  def assert(value,message); raise "TEST FAILED: #{message}" unless value; end
  def shape(entities,kind=:box)
    group=entities.add_group
    case kind
    when :box
      f=group.entities.add_face([0,0,0],[100,0,0],[100,13,0],[0,13,0]); f.pushpull(7)
    when :plane
      group.entities.add_face([0,0,0],[100,0,0],[100,13,0],[0,13,0])
    when :line
      group.entities.add_line([0,0,0],[100,0,0])
    end
    rotation=Geom::Transformation.rotation([17,-3,12],[1,2,3],0.61)
    group.entities.transform_entities(rotation,group.entities.to_a)
    group
  end
  def geometry(object,parent=Geom::Transformation.new,result={})
    t=parent*object.transformation
    object.definition.entities.each do |e|
      if C.container?(e)
        geometry(e,t,result)
      elsif e.is_a?(Sketchup::Edge)
        e.vertices.each { |v| result[[object.persistent_id,v.persistent_id]]=v.position.transform(t) }
      end
    end
    result
  end
  def unchanged(before,after)
    before.keys.sort==after.keys.sort && before.all? { |key,p| p.distance(after[key]).to_f<1e-6 }
  end
  def analyze(model,objects,**options)
    model.selection.clear; model.selection.add(objects)
    S::Analysis.new(S.capture(model),**options).run
  end
  def case_test(label)
    @model.start_operation('收缩盒子独立测试',true)
    begin
      yield
      @checks << label
    ensure
      @model.active_path=nil if @model.active_path
      @model.abort_operation
    end
  end
  def run(model)
    @model=model; @checks=[]
    [:box,:plane,:line].each do |kind|
      case_test("任意朝向 #{kind}：拟合／原位／重复执行") do
        a=shape(model.entities,kind)
        original=geometry(a); before=S.bounds_array(a.definition.bounds)
        analysis=analyze(model,[a]); result=S.apply(analysis,transaction:false)
        assert(result[:changed],"#{kind} 应改善")
        assert(unchanged(original,geometry(a)),"#{kind} 世界几何")
        sizes=M.sizes(S.bounds_array(a.definition.bounds)).sort
        expected={box:[7,13,100],plane:[0,13,100],line:[0,0,100]}.fetch(kind)
        assert(sizes.zip(expected).all? { |x,y| (x-y).abs<0.05 },"#{kind} 紧密外框 #{sizes}")
        again=analyze(model,[a]); assert(!S.apply(again,transaction:false)[:changed],"#{kind} 重复稳定")
      end
    end
    case_test('共享组件／镜像／非均匀缩放／剪切均保持世界几何') do
      a=shape(model.entities).to_component
      b=model.entities.add_instance(a.definition,Geom::Transformation.translation([500,200,100])*Geom::Transformation.scaling(-2,0.5,3))
      shear=Geom::Transformation.new([1,0.2,0,0,0.3,1,0.1,0,0,0,1,0,200,-100,50,1])
      c=model.entities.add_instance(a.definition,shear)
      previous=[a,b,c].map { |e| geometry(e) }; definition=a.definition
      result=S.apply(analyze(model,[a]),transaction:false)
      assert(result[:changed],'共享组件改轴')
      assert([a,b,c].all? { |e| e.definition==definition },'定义共享保留')
      assert([a,b,c].each_with_index.all? { |e,i| unchanged(previous[i],geometry(e)) },'全部实例原位')
    end
    case_test('嵌套原生外框与同时选中共享定义') do
      outer=model.entities.add_group
      child=shape(outer.entities).to_component
      child.transformation=Geom::Transformation.rotation(ORIGIN,[3,1,-2],0.4)
      other=model.entities.add_instance(child.definition,Geom::Transformation.translation([500,0,0]))
      before=[geometry(outer),geometry(other)]
      analysis=analyze(model,[outer,other]); result=S.apply(analysis,transaction:false)
      assert(result[:changed],'嵌套收缩')
      assert(unchanged(before[0],geometry(outer)) && unchanged(before[1],geometry(other)),'嵌套世界几何')
      result[:results].each { |r| assert(M.no_worse?(r[:after],r[:before],S.epsilon(r[:before])),'每个所选原生外框不变差') }
    end
    case_test('隐藏远端线面仍参与最终边界') do
      a=shape(model.entities)
      edge=a.entities.add_line([5000,7000,-300],[5001,7002,-302]); edge.hidden=true
      previous=geometry(a)
      S.apply(analyze(model,[a]),transaction:false)
      assert(unchanged(previous,geometry(a)),'隐藏远端保留')
      a.entities.grep(Sketchup::Edge).each { |e| e.vertices.each { |v| assert(a.definition.bounds.contains?(v.position),'全几何包围') } }
    end
    case_test('锁定实例阻止联动改轴且不写模型') do
      a=shape(model.entities).to_component
      b=model.entities.add_instance(a.definition,Geom::Transformation.new); b.locked=true
      t=a.transformation; analysis=analyze(model,[a])
      assert(!S.apply(analysis,transaction:false)[:changed] && C.same_transform?(a.transformation,t),'锁定同定义不改')
    end
    case_test('仅所选实例：共享父路径多选与内部共享定义') do
      parent=model.entities.add_group.to_component
      a=shape(parent.definition.entities).to_component
      b=parent.definition.entities.add_instance(a.definition,Geom::Transformation.translation([300,0,0]))
      twin=model.entities.add_instance(parent.definition,Geom::Transformation.translation([500,0,0]))
      previous=geometry(twin); original_parent=parent.definition; original_child=a.definition
      model.active_path=[parent]
      model.selection.clear; model.selection.add([a,b])
      analysis=S::Analysis.new(S.capture(model),scope: :unique).run
      result=S.apply(analysis,transaction:false)
      assert(result[:changed],'独立化收缩')
      assert(parent.definition!=original_parent && twin.definition==original_parent,'仅所选父级隔离')
      assert(unchanged(previous,geometry(twin)),'其它父级副本原位')
      selected=result[:paths].map(&:last)
      assert(selected.all? { |e| e.definition!=original_child } && selected.map(&:definition).uniq.length==1,'所选区域保留组件关联')
      model.active_path=nil
      assert(model.definitions.all? { |d| d.entities.all? { |e| !e.attribute_dictionaries || e.attribute_dictionaries.none? { |v| v.name.start_with?('_zhi_shrink_') } } },'独立化标识清理')
    end
    case_test('普通组共享定义：联动不触发自动独立化') do
      a=shape(model.entities); original=a.definition
      b=model.entities.add_instance(original,Geom::Transformation.translation([300,0,0]))
      previous=[geometry(a),geometry(b)]
      result=S.apply(analyze(model,[a]),transaction:false)
      assert(result[:changed] && a.definition==original && b.definition==original,'组定义共享保持')
      assert(unchanged(previous[0],geometry(a)) && unchanged(previous[1],geometry(b)),'共享组原位')
    end
    case_test('锁定祖先中的共享副本不能被间接改轴') do
      parent=model.entities.add_group
      a=shape(parent.entities).to_component
      b=model.entities.add_instance(a.definition,Geom::Transformation.new)
      parent.locked=true
      result=S.apply(analyze(model,[b]),transaction:false)
      assert(!result[:changed],'锁定祖先保护')
    end
    case_test('纹理正反UV、孔洞、曲线、属性和实体ID保留') do
      require 'base64'
      texture=File.expand_path('../docs/uv-test.png',__dir__)
      File.binwrite(texture,Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))
      a=model.entities.add_group
      f=a.entities.add_face([0,0,0],[100,0,0],[100,30,0],[0,30,0])
      hole=a.entities.add_face([5,5,0],[10,5,0],[10,10,0],[5,10,0]);hole.erase!
      curve=a.entities.add_curve([0,0,3],[50,5,3],[100,0,3]).first.curve
      material=model.materials.add('收缩UV');material.texture=texture
      f.material=material;f.back_material=material;f.set_attribute('test','preserve','yes')
      mapping=[Geom::Point3d.new(0,0,0),Geom::Point3d.new(0.2,0.3,0),Geom::Point3d.new(100,0,0),Geom::Point3d.new(1.7,0.5,0),Geom::Point3d.new(0,30,0),Geom::Point3d.new(0.4,2.1,0)]
      f.position_material(material,mapping,true);f.position_material(material,mapping,false)
      a.entities.transform_entities(Geom::Transformation.rotation([10,3,-8],[1,-3,2],0.71),a.entities.to_a)
      a.transformation=Geom::Transformation.translation([100,200,300])*Geom::Transformation.scaling(-2,0.3,3)
      uv=lambda do
        helper=f.get_UVHelper(true,true,Sketchup.create_texture_writer)
        f.vertices.map do |v|
          front=helper.get_front_UVQ(v.position);back=helper.get_back_UVQ(v.position)
          [v.persistent_id,[front.x/front.z,front.y/front.z,back.x/back.z,back.y/back.z]]
        end.to_h
      end
      before_uv=uv.call;before=geometry(a);ids=a.definition.entities.map(&:persistent_id).sort
      S.apply(analyze(model,[a]),transaction:false)
      assert(unchanged(before,geometry(a)),'UV用例世界几何')
      assert(before_uv.all? { |id,values| values.zip(uv.call[id]).all? { |x,y| (x-y).abs<1e-6 } },'正反纹理UV')
      assert(f.loops.length==2 && f.material==material && f.back_material==material,'孔洞正反材质')
      assert(curve.valid? && curve.edges.length==2 && f.get_attribute('test','preserve')=='yes','曲线与属性')
      assert(ids==a.definition.entities.map(&:persistent_id).sort,'原始实体ID')
    end
    case_test('非凸离散内容、精细模式、关闭内部处理') do
      a=model.entities.add_group
      a.entities.add_face([0,0,0],[100,0,0],[100,8,0],[8,8,0],[8,70,0],[0,70,0])
      a.entities.add_line([17,21,9],[42,11,20])
      a.entities.transform_entities(Geom::Transformation.rotation(ORIGIN,[2,3,5],0.67),a.entities.to_a)
      child=shape(a.entities).to_component; child_before=child.definition.entities.map(&:persistent_id)
      original=geometry(a);analysis=analyze(model,[a],nested:false,quality: :fine)
      result=S.apply(analysis,transaction:false)
      assert(unchanged(original,geometry(a)),'非凸内容原位')
      assert(analysis.plans.all? { |d,p| d==a.definition || !S.changed?(p[:shift]) } && child_before==child.definition.entities.map(&:persistent_id),'关闭内部处理')
      assert(result[:results].all? { |r| M.no_worse?(r[:after],r[:before],S.epsilon(r[:before])) },'非凸原生框不增大')
    end
    case_test('点、有限参考线、空对象和近对称形体') do
      empty=model.entities.add_group
      a=model.entities.add_group
      a.entities.add_cpoint([0,0,0]);a.entities.add_cpoint([100,20,10]);a.entities.add_cline([0,0,0],[100,20,10])
      result=S.apply(analyze(model,[empty,a]),transaction:false)
      assert(result[:results].length==2,'混选空对象结果')
      assert(a.definition.entities.length==3,'参考几何保留')
      cube=model.entities.add_group
      cube.entities.add_face([0,0,0],[10,0,0],[10,10,0],[0,10,0]).pushpull(10)
      cube.entities.transform_entities(Geom::Transformation.rotation(ORIGIN,[1,3,2],0.49),cube.entities.to_a)
      S.apply(analyze(model,[cube]),transaction:false)
      t=cube.transformation
      result=S.apply(analyze(model,[cube]),transaction:false)
      assert(!result[:changed] && C.same_transform?(cube.transformation,t),'对称形体重复稳定')
    end
    case_test('重复组件复用定义缓存') do
      parent=model.entities.add_group
      source=shape(parent.entities).to_component
      999.times { |i| parent.entities.add_instance(source.definition,Geom::Transformation.translation([(i%20)*130,(i/20)*30,0])) }
      analysis=analyze(model,[parent])
      assert(analysis.stats[:definitions]==2 && analysis.stats[:vertices]==8,'一千实例只扫描八顶点')
      assert(analysis.stats[:largest_nested_cache_bytes]==1000*8*24,'子框紧凑缓存')
      assert(analysis.results.all? { |r| M.no_worse?(r[:after],r[:before],S.epsilon(r[:before])) },'重复实例整体外框')
    end
    case_test('关闭内部改轴时追踪深层共享的另一所选定义') do
      outer=model.entities.add_group
      middle=outer.entities.add_group
      child=shape(middle.entities).to_component
      other=model.entities.add_instance(child.definition,Geom::Transformation.translation([500,300,0]))
      original=geometry(outer);middle_t=middle.transformation
      analysis=analyze(model,[other,outer],nested:false)
      result=S.apply(analysis,transaction:false)
      assert(unchanged(original,geometry(outer)),'深层共享选择原位')
      assert(result[:results].all? { |r| M.no_worse?(r[:after],r[:before],S.epsilon(r[:before])) },'深层依赖外框核定')
      assert(!S.changed?(analysis.plans[middle.definition][:shift]),'中间层保留原轴')
    end
    {success:true,checks:@checks,pid:Process.pid,time:Time.now.to_s}
  rescue Exception => error
    {success:false,checks:@checks,error:error.full_message,pid:Process.pid,time:Time.now.to_s}
  end
end
