# encoding: UTF-8
require 'sketchup.rb'
require 'securerandom'

module Zhi
  module AxisInspector
    VERSION = '1.1.0' unless const_defined?(:VERSION)
    class AxisError < StandardError; end

    module Core
      extend self
      # SketchUp 包围框编号：X 为位 0、Y 为位 1、Z 为位 2。
      POINTS = [
        ['c0', '角点 · X− Y− Z−', [0, 0, 0]],
        ['c1', '角点 · X+ Y− Z−', [1, 0, 0]],
        ['c2', '角点 · X− Y+ Z−', [0, 1, 0]],
        ['c3', '角点 · X+ Y+ Z−', [1, 1, 0]],
        ['c4', '角点 · X− Y− Z+', [0, 0, 1]],
        ['c5', '角点 · X+ Y− Z+', [1, 0, 1]],
        ['c6', '角点 · X− Y+ Z+', [0, 1, 1]],
        ['c7', '角点 · X+ Y+ Z+', [1, 1, 1]],
        ['xm', 'X− 面心', [0, 0.5, 0.5]], ['xp', 'X+ 面心', [1, 0.5, 0.5]],
        ['ym', 'Y− 面心', [0.5, 0, 0.5]], ['yp', 'Y+ 面心', [0.5, 1, 0.5]],
        ['zm', 'Z− 面心（底面）', [0.5, 0.5, 0]], ['zp', 'Z+ 面心（顶面）', [0.5, 0.5, 1]],
        ['center', '包围框中心', [0.5, 0.5, 0.5]]
      ].freeze
      BOX_EDGES = [[0,1],[1,3],[3,2],[2,0],[4,5],[5,7],[7,6],[6,4],[0,4],[1,5],[2,6],[3,7]].freeze

      def container?(entity)
        entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      end

      def parent_entities(entity)
        parent = entity.parent
        parent.is_a?(Sketchup::Entities) ? parent : parent.entities
      end

      def name(entity)
        return entity.name unless entity.name.empty?
        return entity.definition.name unless entity.definition.name.empty?
        entity.is_a?(Sketchup::Group) ? '未命名组' : '未命名组件'
      end

      def world_transform(path)
        path.inject(Geom::Transformation.new) { |t, instance| t * instance.transformation }
      end

      def valid_path!(model, path)
        raise AxisError, '当前模型已切换，请重新选择。' unless Sketchup.active_model == model
        raise AxisError, '请选中一个组或组件。' if path.empty?
        path.inject(model.entities) do |entities, entity|
          unless entity.valid? && container?(entity) && parent_entities(entity) == entities
            raise AxisError, '对象或所属层级已改变，请重新选择。'
          end
          entity.definition.entities
        end
      end

      def capture(model)
        selected = model.selection.to_a
        raise AxisError, '请选择一个组或组件；多选时暂不移动轴点。' unless selected.length == 1 && container?(selected.first)
        path = (model.active_path || []) + selected
        valid_path!(model, path)
        { model: model, path: path }
      end

      def same_selection?(capture)
        m = capture[:model]
        Sketchup.active_model == m && ((m.active_path || []) + m.selection.to_a) == capture[:path]
      end

      # SketchUp 的 Transformation#xaxis/yaxis/zaxis 返回单位方向，不含缩放。
      # 真正的基向量须由变换后的单位点减原点得到；非均匀缩放、镜像和剪切均适用。
      def basis(t)
        origin = ORIGIN.transform(t)
        [Geom::Point3d.new(1,0,0), Geom::Point3d.new(0,1,0), Geom::Point3d.new(0,0,1)].map { |p| p.transform(t) - origin }
      end

      def invertible!(t)
        axes = basis(t)
        volume = axes.inject(1.0) { |v, a| v * a.length.to_f }
        raise AxisError, '对象包含零缩放或不可逆变换，不能移动轴点。' if volume.zero? || axes[0].cross(axes[1]).dot(axes[2]).abs / volume < 1.0e-12
        t.inverse
      end

      def point_for(bounds, key)
        point = POINTS.find { |item| item[0] == key }
        raise AxisError, '未知的包围框点位。' unless point
        raise AxisError, '空对象没有可用的包围框。' if bounds.empty?
        lo = bounds.min.to_a
        hi = bounds.max.to_a
        Geom::Point3d.new(point[2].each_with_index.map { |f, i| lo[i] + (hi[i] - lo[i]) * f })
      end

      def mm(point)
        point.to_a.map { |v| (v.to_f * 25.4).round(4) }
      end

      def shared_path(path)
        path.select { |e| e.definition.instances.count(&:valid?) > 1 }
      end

      def parent_coordinate_transform(model, path)
        parent_path = path[0...-1]
        if model.active_path && model.active_path == parent_path
          model.edit_transform
        else
          world_transform(parent_path)
        end
      end

      def validate_move!(model, path, scope)
        raise AxisError, '未知的实例处理方式。' unless [:unique, :linked].include?(scope)
        valid_path!(model, path)
        raise AxisError, '对象或上级已锁定，请先解锁。' if path.any?(&:locked?)
        invertible!(world_transform(path))
        target = path.last
        raise AxisError, '空对象没有可用的包围框。' if target.definition.bounds.empty?
        affected = scope == :linked ? target.definition.instances.select(&:valid?) : [target]
        if affected.any?(&:locked?)
          raise AxisError, '同定义实例中有锁定对象，不能联动修改轴点。'
        end
        if affected.any? { |e| e.respond_to?(:glued_to) && e.glued_to }
          raise AxisError, '对象含有粘接关系，请先解除粘接再修改轴点。'
        end
        if target.definition.behavior.cuts_opening?
          raise AxisError, '开洞组件的轴定义参与切口计算，本版不修改其轴点。'
        end
        if target.definition.entities.any? { |e| container?(e) && e.locked? }
          raise AxisError, '内部包含锁定对象，请先解锁后再修改轴点。'
        end
        affected.each { |e| invertible!(e.transformation) }
        true
      end

      def info(capture)
        model, path = capture.values_at(:model, :path)
        valid_path!(model, path)
        target = path.last
        definition = target.definition
        bounds = definition.bounds
        world = world_transform(path)
        world_basis = basis(world)
        scale = world_basis.map { |v| v.length.to_f }
        corners = bounds.empty? ? [] : 8.times.map { |i| bounds.corner(i).transform(world) }
        world_box = Geom::BoundingBox.new
        corners.each { |p| world_box.add(p) }
        sizes = bounds.empty? ? nil : [bounds.width, bounds.height, bounds.depth].map(&:to_f)
        blocked = nil
        begin
          validate_move!(model, path, :unique)
        rescue AxisError => e
          blocked = e.message
        end
        solid = target.manifold?
        volume = solid ? target.volume.to_f : nil
        # volume 已包含目标实例变换；这里只补上父层级的行列式。
        parent_t = world_transform(path[0...-1])
        parent_basis = basis(parent_t)
        volume *= parent_basis[0].cross(parent_basis[1]).dot(parent_basis[2]).abs if volume
        axes = world_basis.map { |v| v.length.to_f.zero? ? nil : v.normalize.to_a.map { |n| n.round(6) } }
        {
          name: name(target), instance_name: target.name, definition_name: definition.name,
          description: definition.description, type: target.is_a?(Sketchup::Group) ? '组' : '组件',
          pid: target.persistent_id.to_s, path: path.map { |e| name(e) }.join(' / '),
          tag: target.layer.name, material: target.material ? target.material.display_name : '默认 / 继承上级',
          locked: target.locked?, hidden: target.hidden?, solid: solid,
          volume_m3: volume && (volume * 0.000016387064).round(6),
          entity_count: definition.entities.length, instance_count: definition.instances.count(&:valid?),
          shared_ancestors: shared_path(path[0...-1]).map { |e| name(e) },
          # 编辑组件期间 SketchUp 暂时把活动路径变换压入内部实例，目标的
          # transformation 此时可能是世界变换。父级坐标必须用 edit_transform 逆算。
          world_origin: mm(world.origin), parent_origin: mm(world.origin.transform(parent_coordinate_transform(model, path).inverse)),
          dimensions: sizes && sizes.each_with_index.map { |n, i| (n * scale[i] * 25.4).round(4) },
          definition_dimensions: sizes && sizes.map { |n| (n * 25.4).round(4) },
          world_dimensions: world_box.empty? ? nil : [world_box.width, world_box.height, world_box.depth].map { |n| (n.to_f * 25.4).round(4) },
          scale: scale.map { |n| n.round(6) }, axes: axes,
          mirrored: world_basis[0].cross(world_basis[1]).dot(world_basis[2]) < 0,
          points: bounds.empty? ? [] : POINTS.map { |key, label, fraction| { id: key, label: label, fraction: fraction, local: mm(point_for(bounds, key)), world: mm(point_for(bounds, key).transform(world)) } },
          local_min: bounds.empty? ? nil : mm(bounds.min), local_max: bounds.empty? ? nil : mm(bounds.max),
          movable: blocked.nil?, blocked_reason: blocked,
          dynamic: !definition.attribute_dictionary('dynamic_attributes').nil? || !target.attribute_dictionary('dynamic_attributes').nil?
        }
      end

      # 面板统一显示毫米。无单位输入按毫米解释；带 mm/cm/m/in/ft 等单位时
      # 直接识别常见单位，其他写法交给 SketchUp 长度解析器；不使用 eval。
      def parse_coordinate(text)
        value = text.to_s.strip
        numeric = /\A([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*(mm|cm|m|in|ft)?\z/i.match(value)
        if numeric
          # 中文 SketchUp 的 parse_length 不识别英文 in；简单单位显式换算。
          factors = { nil => 1.0 / 25.4, 'mm' => 1.0 / 25.4, 'cm' => 10.0 / 25.4,
            'm' => 1000.0 / 25.4, 'in' => 1.0, 'ft' => 12.0 }
          number = Float(numeric[1]) * factors.fetch(numeric[2]&.downcase)
        else
          parsed = Sketchup.parse_length(value)
          raise AxisError, "无法识别坐标：#{value}" unless parsed
          number = parsed.to_f
        end
        raise AxisError, '坐标必须是有限数值。' unless number.finite?
        number
      end

      def validate_position!(model, path)
        valid_path!(model, path)
        raise AxisError, '对象或上级已锁定，请先解锁。' if path.any?(&:locked?)
        invertible!(world_transform(path[0...-1]))
        target = path.last
        if target.respond_to?(:glued_to) && target.glued_to
          raise AxisError, '请先解除组件的粘接关系。'
        end
      end

      def validate_nudge!(axis, direction, step, space)
        raise AxisError, '未知的移动坐标轴。' unless ['x', 'y', 'z'].include?(axis)
        raise AxisError, '移动方向必须为增加或减少。' unless [-1, 1].include?(direction)
        raise AxisError, '未知的坐标空间。' unless [:world, :parent].include?(space)
        length = parse_coordinate(step)
        raise AxisError, '步长必须大于零。' unless length > 0
        length
      end

      # 从真实变换取全精度坐标，不能拿面板四舍五入的数值再加减，否则
      # 多次点击会让另两个轴也发生细小漂移。步长是相对位移，不是网格吸附。
      def nudge(model, path, axis, direction, step, space: :world, transaction: true)
        raise AxisError, '步进移动需要先退出编辑上下文。' if model.active_path
        length = validate_nudge!(axis, direction, step, space)
        validate_position!(model, path)
        origin = space == :world ? world_transform(path).origin : path.last.transformation.origin
        coordinates = origin.to_a
        coordinates[['x', 'y', 'z'].index(axis)] += direction * length
        position(model, path, coordinates.map { |n| n * 25.4 }, space: space, transaction: transaction)
      end

      # 编辑坐标移动整个对象，与下方的“原位改轴”不同。
      # 只隔离共享父路径；仅移动实例不需要破坏目标本身的组件关联。
      def position(model, path, coordinates, space: :world, transaction: true)
        raise AxisError, '坐标移动需要先退出编辑上下文。' if model.active_path
        raise AxisError, '未知的坐标空间。' unless [:world, :parent].include?(space)
        raise AxisError, '需要完整的 X、Y、Z 坐标。' unless coordinates.is_a?(Array) && coordinates.length == 3
        validate_position!(model, path)
        desired = Geom::Point3d.new(coordinates.map { |value| parse_coordinate(value) })
        parent_t = world_transform(path[0...-1])
        desired_parent = space == :world ? desired.transform(parent_t.inverse) : desired
        original = path.last.transformation
        return { path: path, changed: false } if original.origin.distance(desired_parent).to_f < 1.0e-9
        dictionary = "_zhi_axis_#{SecureRandom.hex(12)}"
        tagged = path.dup
        operation = false
        begin
          if transaction
            model.start_operation('按轴点坐标移动对象', true)
            operation = true
          end
          # 最后一层仅用于重定位，不做 make_unique。
          path = isolate_path(model, path, dictionary, tagged, isolate_target: false)
          target = path.last
          translation = Geom::Transformation.translation(desired_parent - original.origin)
          target.transformation = translation * original
          raise AxisError, '坐标移动校验失败，操作已回滚。' unless same_transform?(translation * original, target.transformation)
          tagged.uniq.each { |e| e.delete_attribute(dictionary) if e.valid? && e.attribute_dictionary(dictionary) }
          if operation
            model.commit_operation
            operation = false
          end
          { path: path, changed: true }
        rescue Exception
          model.abort_operation if operation
          raise
        end
      end

      # 独立化父实例后内部 Ruby 对象会被替换。用事务内临时标识精确重定位，
      # 既不通过名称猜对象，也不误操作其他副本。
      def isolate_path(model, path, dictionary, tagged, isolate_target: true)
        path.each_with_index { |entity, i| entity.set_attribute(dictionary, 'step', i) }
        entities = model.entities
        path.each_index.map do |i|
          entity = entities.find { |e| e.get_attribute(dictionary, 'step') == i }
          raise AxisError, '独立化后找不到原实例，操作已回滚。' unless entity && container?(entity)
          tagged << entity
          if (isolate_target || i < path.length - 1) && entity.definition.instances.count(&:valid?) > 1
            entity.make_unique
            entity.definition.entities.each { |child| tagged << child unless child.get_attribute(dictionary, 'step').nil? }
          end
          entities = entity.definition.entities
          entity
        end
      end

      def same_transform?(a, b)
        [ORIGIN, Geom::Point3d.new(1,0,0), Geom::Point3d.new(0,1,0), Geom::Point3d.new(0,0,1)].all? do |p|
          p.transform(a).distance(p.transform(b)).to_f < 1.0e-6
        end
      end

      # 所有写操作都在根编辑环境完成，避免 transform_entities 在活动编辑路径内
      # 混用世界坐标。调用方负责退出并恢复编辑路径；transaction:false 要求调用方
      # 已打开完整操作（窗口入口把编辑路径切换也包在同一次操作中，测试则整体回滚）。
      def move(model, path, key, scope: :unique, transaction: true)
        raise AxisError, '移动内核需要先退出编辑上下文。' if model.active_path
        validate_move!(model, path, scope)
        delta = point_for(path.last.definition.bounds, key)
        return { path: path, changed: false, affected: 0 } if delta.distance(ORIGIN).to_f < 1.0e-9
        dictionary = "_zhi_axis_#{SecureRandom.hex(12)}"
        tagged = path.dup
        operation = false
        begin
          if transaction
            model.start_operation('移动对象轴点', true)
            operation = true
          end
          path = isolate_path(model, path, dictionary, tagged) if scope == :unique
          target = path.last
          definition = target.definition
          affected = definition.instances.select(&:valid?)
          before = affected.map { |e| [e, e.transformation] }
          shift = Geom::Transformation.translation(delta.to_a)
          inverse = shift.inverse
          # G' = T(-p)G，I' = I T(p)，所以 I'G' = IG，世界外观不变。
          # 直接平移原实体，不 explode/rebuild，保留拓扑、材质和内部属性。
          definition.entities.transform_entities(inverse, definition.entities.to_a)
          before.each { |entity, transform| entity.transformation = transform * shift }
          definition.invalidate_bounds
          before.each do |entity, transform|
            raise AxisError, '原位补偿校验失败，操作已回滚。' unless same_transform?(transform, entity.transformation * inverse)
          end
          tagged.uniq.each { |e| e.delete_attribute(dictionary) if e.valid? && e.attribute_dictionary(dictionary) }
          if operation
            model.commit_operation
            operation = false
          end
          { path: path, changed: true, affected: affected.length }
        rescue Exception
          model.abort_operation if operation
          raise
        end
      end
    end
  end
end
