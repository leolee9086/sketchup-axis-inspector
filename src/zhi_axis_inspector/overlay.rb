# encoding: UTF-8
module Zhi
  module AxisInspector
    # Overlay 不取代当前工具；打开面板后仍可以正常选择、平移、轨道观察。
    # 所有 draw 回调只绘图，绝不从渲染回调修改模型。
    class AxisOverlay < Sketchup::Overlay
      attr_accessor :capture, :point_key

      def initialize
        super('zhi.axis_inspector.preview', '对象信息与轴点预览', description: '显示对象局部包围框、原轴点及候选轴点')
      end

      def geometry
        return nil unless @capture
        path = @capture[:path]
        return nil unless Sketchup.active_model == @capture[:model] && path.all?(&:valid?)
        bounds = path.last.definition.bounds
        return nil if bounds.empty?
        world = Core.world_transform(path)
        points = 8.times.map { |i| bounds.corner(i).transform(world) }
        target = @point_key && Core.point_for(bounds, @point_key).transform(world)
        [world, points, target]
      end

      def draw(view)
        data = geometry
        return unless data
        world, corners, target = data
        view.line_width = 2
        view.line_stipple = '-'
        view.drawing_color = Sketchup::Color.new(68, 145, 190)
        view.draw(GL_LINES, Core::BOX_EDGES.flat_map { |a, b| [corners[a], corners[b]] })
        view.line_stipple = ''
        origin = world.origin
        length = view.pixels_to_model(48, origin)
        [world.xaxis, world.yaxis, world.zaxis].each_with_index do |axis, i|
          next if axis.length.to_f.zero?
          tip = origin.offset(axis, length)
          view.drawing_color = [Sketchup::Color.new(225, 80, 81), Sketchup::Color.new(65, 160, 99), Sketchup::Color.new(70, 125, 235)][i]
          view.draw(GL_LINES, [origin, tip])
          view.draw_text(view.screen_coords(tip), ['X', 'Y', 'Z'][i])
        end
        view.draw_points([origin], 9, 2, Sketchup::Color.new(250, 176, 65))
        if target
          view.drawing_color = Sketchup::Color.new(242, 135, 35)
          view.line_stipple = '.'
          view.draw(GL_LINES, [origin, target])
          view.line_stipple = ''
          view.draw_points([target], 14, 3, Sketchup::Color.new(242, 135, 35))
          screen = view.screen_coords(target)
          view.draw_text(Geom::Point3d.new(screen.x + 12, screen.y + 10, 0), '目标轴点', color: Sketchup::Color.new(180, 85, 15))
        end
      rescue StandardError => error
        # 异常只报告一次并清空预览，避免每帧刷日志。
        @capture = nil
        warn("[对象信息与轴点] 预览失败：#{error.message}")
      end

      def getExtents
        bounds = Geom::BoundingBox.new
        data = geometry
        if data
          bounds.add(data[0].origin)
          data[1].each { |p| bounds.add(p) }
          bounds.add(data[2]) if data[2]
        end
        bounds
      end
    end
  end
end
