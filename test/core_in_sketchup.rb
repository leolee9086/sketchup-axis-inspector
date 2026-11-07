# encoding: UTF-8
require 'json'

module ZhiAxisTests
  extend self
  Core = Zhi::AxisInspector::Core
  Error = Zhi::AxisInspector::AxisError

  def assert(value, message)
    raise "TEST FAILED: #{message}" unless value
  end

  def near(a, b)
    Geom::Point3d.new(a).distance(Geom::Point3d.new(b)).to_f < 1.0e-6
  end

  def box(entities, component: false)
    group = entities.add_group
    face = group.entities.add_face([10,20,30], [50,20,30], [50,80,30], [10,80,30])
    face.reverse! if face.normal.z < 0
    face.pushpull(90)
    component ? group.to_component : group
  end

  def geometry(instance, parent = Geom::Transformation.new)
    t = parent * instance.transformation
    points = []
    instance.definition.entities.each do |e|
      if e.is_a?(Sketchup::Edge)
        points << e.start.position.transform(t).to_a << e.end.position.transform(t).to_a
      elsif Core.container?(e)
        points.concat(geometry(e, t))
      end
    end
    points.map { |p| p.map { |v| v.round(6) } }.sort
  end

  def world_axis(path)
    Core.world_transform(path).origin
  end

  def test(label)
    @model.start_operation('独立样例测试', true)
    begin
      yield
      @checks << label
    ensure
      @model.active_path = nil if @model.active_path
      @model.abort_operation
    end
  end

  def run(model)
    @model = model
    @checks = []
    roots = model.entities.map(&:persistent_id).sort
    test('全部15点：局部坐标和原位几何') do
      Core::POINTS.each do |key, _name, _fraction|
        object = box(model.entities)
        object.transformation = Geom::Transformation.translation([230,-70,150]) * Geom::Transformation.rotation(ORIGIN, Z_AXIS, 0.65) * Geom::Transformation.scaling(-1.2, 0.7, 2.0)
        old = geometry(object)
        expected = Core.point_for(object.definition.bounds, key).transform(object.transformation)
        result = Core.move(model, [object], key, transaction: false)
        assert(near(result[:path].last.transformation.origin, expected), "#{key}轴点")
        assert(geometry(object) == old, "#{key}原位几何")
      end
    end
    test('共享组件默认独立化、其他实例轴点与几何保持') do
      a = box(model.entities, component: true)
      b = model.entities.add_instance(a.definition, Geom::Transformation.translation([100,0,0]))
      original = a.definition
      old_a, old_b = geometry(a), geometry(b)
      old_b_transform = b.transformation
      a.set_attribute('test', 'data', ['value', 2])
      a.name = '保留名称'
      pid = a.persistent_id
      Core.move(model, [a], 'center', transaction: false)
      assert(a.definition != original && b.definition == original, '独立化范围')
      assert(geometry(a) == old_a && geometry(b) == old_b, '其他副本几何')
      assert(Core.same_transform?(old_b_transform, b.transformation), '其他副本轴点')
      assert(a.persistent_id == pid && a.name == '保留名称' && a.get_attribute('test','data') == ['value', 2], '实例元数据')
    end
    test('联动改轴：镜像缩放的所有实例仍保持原位') do
      a = box(model.entities, component: true)
      b = model.entities.add_instance(a.definition, Geom::Transformation.translation([300,10,20]) * Geom::Transformation.scaling(-2,0.5,3))
      old = [geometry(a), geometry(b)]
      definition = a.definition
      result = Core.move(model, [a], 'zp', scope: :linked, transaction: false)
      assert(result[:affected] == 2 && a.definition == definition && b.definition == definition, '保留定义关联')
      assert(old == [geometry(a), geometry(b)], '两实例原位')
    end
    test('嵌套共享父路径逐层独立化') do
      parent = box(model.entities, component: true)
      child = box(parent.definition.entities, component: true)
      twin = model.entities.add_instance(parent.definition, Geom::Transformation.translation([500,0,0]))
      original = parent.definition
      before = [geometry(parent), geometry(twin)]
      result = Core.move(model, [parent, child], 'c7', transaction: false)
      assert(result[:path].first == parent && parent.definition != original && twin.definition == original, '父级独立化')
      assert(before == [geometry(parent), geometry(twin)], '嵌套保持原位')
      assert(result[:path].last != child, '克隆路径重新定位')
      all = model.definitions.flat_map { |d| d.entities.to_a }
      assert(all.none? { |e| e.attribute_dictionaries&.any? { |d| d.name.start_with?('_zhi_axis_') } }, '临时标识清理')
    end
    test('世界坐标移动：旋转非均匀缩放父层级、仅当前副本') do
      parent = box(model.entities, component: true)
      parent.transformation = Geom::Transformation.translation([600,200,-50]) * Geom::Transformation.rotation(ORIGIN, Z_AXIS, 0.7) * Geom::Transformation.scaling(-1.5,2,0.8)
      child = box(parent.definition.entities, component: true)
      child.transformation = Geom::Transformation.translation([30,40,50]) * Geom::Transformation.rotation(ORIGIN, X_AXIS, 0.2)
      twin = model.entities.add_instance(parent.definition, Geom::Transformation.new)
      child_definition = child.definition
      old_twin = geometry(twin)
      old_world = Core.world_transform([parent,child])
      target = [1000, -2345, 500]
      result = Core.position(model, [parent,child], target.map(&:to_s), transaction: false)
      moved = result[:path].last
      now = Core.world_transform(result[:path])
      assert(near(now.origin, target.map { |n| n / 25.4 }), '世界轴点准确')
      assert(Core.basis(now).zip(Core.basis(old_world)).all? { |a,b| (a-b).length.to_f < 1e-8 }, '朝向尺寸保留')
      assert(geometry(twin) == old_twin, '父组件副本不移动')
      assert(moved.definition == child_definition, '移动位置不破坏目标定义关联')
    end
    test('父级坐标移动及毫米/显式单位解析') do
      parent = box(model.entities, component: true)
      parent.transformation = Geom::Transformation.rotation(ORIGIN,Z_AXIS,1.2)
      child = box(parent.definition.entities)
      Core.position(model, [parent,child], ['100','20cm','0.3m'], space: :parent, transaction: false)
      assert(near(child.transformation.origin,[100/25.4,200/25.4,300/25.4]), '父级轴点准确')
      assert((Core.parse_coordinate('1in')-1).abs < 1e-8, '英寸输入')
      begin
        Core.parse_coordinate('not a number')
        raise '非法输入未被拒绝'
      rescue Error
      end
    end
    test('锁定/空对象/非法点位拒绝且无写入') do
      object = box(model.entities)
      old = geometry(object)
      object.locked = true
      begin
        Core.move(model,[object],'center',transaction:false)
        raise '锁定未被拒绝'
      rescue Error
      end
      object.locked = false
      begin
        Core.move(model,[object],'invalid',transaction:false)
        raise '非法点未被拒绝'
      rescue Error
      end
      empty = model.entities.add_group
      begin
        Core.move(model,[empty],'center',transaction:false)
        raise '空对象未被拒绝'
      rescue Error
      end
      assert(geometry(object) == old, '无写入')
    end
    test('信息字段：世界/父级坐标、尺寸、体积') do
      parent = box(model.entities, component: true)
      parent.transformation = Geom::Transformation.translation([100,200,300]) * Geom::Transformation.scaling(2,3,4)
      child = box(parent.definition.entities)
      child.transformation = Geom::Transformation.translation([10,20,30])
      info = Core.info(model: model,path:[parent,child])
      assert(info[:world_origin] == [120,260,420].map { |n| n * 25.4 }, '世界坐标信息')
      assert(info[:parent_origin] == [254.0,508.0,762.0], '父级坐标信息')
      assert(info[:dimensions] == [80,180,360].map { |n| n * 25.4 }, '轴向尺寸')
      assert(info[:points].length == 15 && info[:solid] && info[:volume_m3] > 0, '信息完整')
    end
    assert(model.entities.map(&:persistent_id).sort == roots, '外层回滚恢复样例')
    {success: true, checks: @checks, original_scene_unchanged: true}
  rescue Exception => error
    {success: false, checks: @checks, error: error.full_message}
  end
end
