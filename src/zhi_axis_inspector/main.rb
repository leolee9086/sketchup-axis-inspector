# encoding: UTF-8
require 'sketchup.rb'
require 'json'
require_relative 'core'
require_relative 'overlay'

module Zhi
  module AxisInspector
    extend self

    class SelectionWatcher < Sketchup::SelectionObserver
      def onSelectionBulkChange(*); AxisInspector.schedule_refresh; end
      def onSelectionAdded(*); AxisInspector.schedule_refresh; end
      def onSelectionRemoved(*); AxisInspector.schedule_refresh; end
      def onSelectionCleared(*); AxisInspector.schedule_refresh; end
    end
    class ModelWatcher < Sketchup::ModelObserver
      def onTransactionCommit(*); AxisInspector.schedule_refresh; end
      def onTransactionUndo(*); AxisInspector.schedule_refresh; end
      def onTransactionRedo(*); AxisInspector.schedule_refresh; end
      def onTransactionAbort(*); AxisInspector.schedule_refresh; end
      def onActivePathChanged(*); AxisInspector.schedule_refresh; end
    end
    class AppWatcher < Sketchup::AppObserver
      def onActivateModel(*); AxisInspector.schedule_refresh; end
      def onNewModel(*); AxisInspector.schedule_refresh; end
      def onOpenModel(*); AxisInspector.schedule_refresh; end
    end

    def open
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        refresh
        return
      end
      @ready = false
      @dialog = UI::HtmlDialog.new(dialog_title: '对象信息与轴点', preferences_key: 'ZhiAxisInspector',
        scrollable: true, resizable: true, width: 610, height: 920, min_width: 510, min_height: 520,
        style: UI::HtmlDialog::STYLE_DIALOG)
      @dialog.add_action_callback('ready') { |_ctx| @ready = true; refresh }
      @dialog.add_action_callback('refresh') { |_ctx| refresh }
      @dialog.add_action_callback('hover') { |_ctx, json| preview(JSON.parse(json)) }
      @dialog.add_action_callback('move_axis') { |_ctx, json| apply_request('axis', JSON.parse(json)) }
      @dialog.add_action_callback('move_position') { |_ctx, json| apply_request('position', JSON.parse(json)) }
      @dialog.add_action_callback('nudge_position') { |_ctx, json| apply_request('nudge', JSON.parse(json)) }
      @dialog.add_action_callback('overlay') do |_ctx, enabled|
        @preview_enabled = !!enabled
        @overlay.enabled = @preview_enabled if @overlay
        @model.active_view.invalidate if @model
      end
      @dialog.set_on_closed { detach; @ready = false; @dialog = nil }
      @dialog.set_file(File.join(__dir__, 'ui', 'panel.html'))
      @dialog.show
    end

    def detach
      if @model
        @model.selection.remove_observer(@selection_watcher) if @selection_watcher
        @model.remove_observer(@model_watcher) if @model_watcher
        @model.overlays.remove(@overlay) if @overlay && @overlay.valid?
        @model.active_view.invalidate
      end
      Sketchup.remove_observer(@app_watcher) if @app_watcher
      @model = @overlay = @app_watcher = nil
      @capture = nil
    end

    def attach(model)
      return if @model == model
      detach
      @model = model
      @selection_watcher = SelectionWatcher.new
      @model_watcher = ModelWatcher.new
      @app_watcher = AppWatcher.new
      model.selection.add_observer(@selection_watcher)
      model.add_observer(@model_watcher)
      Sketchup.add_observer(@app_watcher)
      @overlay = AxisOverlay.new
      model.overlays.add(@overlay)
      @preview_enabled = true if @preview_enabled.nil?
      @overlay.enabled = @preview_enabled
    end

    def schedule_refresh
      return unless @dialog && @ready
      return if @refresh_pending || @busy
      @refresh_pending = true
      @refresh_timer = UI.start_timer(0.06, false) do
        @refresh_timer = nil
        @refresh_pending = false
        refresh if @dialog && @ready && !@busy
      end
    end

    def send_to_panel(method, data)
      return unless @dialog && @ready
      @dialog.execute_script("window.AxisPanel.#{method}(#{JSON.generate(data)})")
    end

    def signature(capture)
      capture[:path].map do |e|
        b = e.definition.bounds
        [e.persistent_id, e.definition.guid, e.transformation.to_a, e.locked?, b.empty? ? nil : [b.min.to_a, b.max.to_a]]
      end
    end

    def refresh
      return unless @dialog && @ready
      if @refresh_timer
        UI.stop_timer(@refresh_timer)
        @refresh_timer = nil
        @refresh_pending = false
      end
      attach(Sketchup.active_model)
      @revision = (@revision || 0) + 1
      @overlay.point_key = nil
      begin
        @capture = Core.capture(@model)
        data = Core.info(@capture)
        @signature = signature(@capture)
        position_error = nil
        begin
          Core.validate_position!(@model, @capture[:path])
        rescue AxisError => error
          position_error = error.message
        end
        @overlay.capture = @capture
        send_to_panel('receive', data.merge(revision: @revision, selected: true,
          position_movable: position_error.nil?, position_error: position_error))
      rescue AxisError => error
        @capture = nil
        @overlay.capture = nil
        send_to_panel('receive', { selected: false, revision: @revision, message: error.message, count: @model.selection.length })
      end
      @model.active_view.invalidate
    rescue StandardError => error
      warn("[对象信息与轴点] 刷新失败：#{error.full_message}")
      send_to_panel('receive', { selected: false, revision: @revision, message: "读取失败：#{error.message}" })
    end

    def fresh!(request)
      raise AxisError, '选择已经改变，请等待面板刷新后重试。' unless @capture && request['revision'] == @revision && Core.same_selection?(@capture)
      Core.valid_path!(@model, @capture[:path])
      raise AxisError, '对象刚刚发生变化，请刷新后重试。' unless signature(@capture) == @signature
      @capture
    end

    def preview(request)
      return unless @overlay
      if request['id'].nil?
        @overlay.point_key = nil
      else
        fresh!(request)
        Core.point_for(@capture[:path].last.definition.bounds, request['id'])
        @overlay.point_key = request['id']
      end
      @model.active_view.invalidate
    rescue AxisError
      @overlay.point_key = nil if @overlay
    end

    # 点击请求带快照版本，始终操作被看见的对象；不会把过期按钮应用到后来选中的对象。
    def apply_request(kind, request)
      return if @busy
      @busy = true
      capture = fresh!(request)
      model = capture[:model]
      original_path = capture[:path].dup
      restored_path = original_path
      scope = request['scope'] == 'linked' ? :linked : :unique
      if kind == 'axis'
        Core.validate_move!(model, original_path, scope)
        if scope == :linked && (Core.shared_path(original_path).any?)
          answer = UI.messagebox('将修改共享定义及全部对应实例的轴点，所有物体仍保持原位。是否继续？', MB_YESNO)
          unless answer == IDYES
            send_to_panel('result', { ok: true, message: '已取消，模型未改变。' })
            return
          end
          fresh!(request)
        end
      else
        Core.validate_position!(model, original_path)
        if kind == 'nudge'
          Core.validate_nudge!(request.fetch('axis'), request.fetch('direction'), request.fetch('step'), request.fetch('space').to_sym)
        end
      end
      operation = false
      begin
        # active_path= 自身会创建坐标切换事务。必须把“退出→修改→恢复”全部
        # 包在同一次操作里，SketchUp 才能透明合并为一个撤销步骤。
        model.start_operation(kind == 'axis' ? '移动对象轴点' : '按轴点坐标移动对象', true)
        operation = true
        model.active_path = nil if model.active_path
        result = if kind == 'axis'
          Core.move(model, original_path, request.fetch('id'), scope: scope, transaction: false)
        elsif kind == 'nudge'
          Core.nudge(model, original_path, request.fetch('axis'), request.fetch('direction'), request.fetch('step'), space: request.fetch('space').to_sym, transaction: false)
        else
          Core.position(model, original_path, request.fetch('values'), space: request.fetch('space').to_sym, transaction: false)
        end
        restored_path = result[:path]
        parent = restored_path[0...-1]
        model.active_path = parent.empty? ? nil : parent
        model.selection.clear
        model.selection.add(restored_path.last)
        model.commit_operation
        operation = false
      rescue Exception
        model.abort_operation if operation
        # 回滚时原路径恢复有效；恢复现场不能重新提交被撤销的修改。
        if original_path.all?(&:valid?)
          parent = original_path[0...-1]
          desired_path = parent.empty? ? nil : parent
          model.active_path = desired_path unless model.active_path == desired_path
          model.selection.clear
          model.selection.add(original_path.last)
        end
        raise
      end
      refresh
      label = if kind == 'axis'
        '轴点已移动，物体保持原位。'
      elsif kind == 'nudge'
        space_label = request['space'] == 'world' ? '世界' : '父级'
        sign = request['direction'] == 1 ? '+' : '−'
        "已沿#{space_label} #{request['axis'].upcase} #{sign} 移动 #{request['step']}。"
      else
        '物体已按轴点坐标移动。'
      end
      send_to_panel('result', { ok: true, message: result[:changed] ? "#{label} Ctrl+Z 可撤销。" : '已经位于目标坐标，无需移动。' })
    rescue StandardError => error
      warn("[对象信息与轴点] 操作失败：#{error.full_message}") unless error.is_a?(AxisError)
      refresh
      send_to_panel('result', { ok: false, message: error.message })
    ensure
      @busy = false
    end

    def show_toolbar
      @toolbar.show
      return if @toolbar.visible?
      show = @toolbar.method(:show)
      return unless show.source_location&.first.to_s.match?(%r{/(piziku|YUN_v[^/]+)/}i)
      # 已核实的本机管理器保留原生方法，只对本工具栏调用；不修改全局方法。
      native = ObjectSpace.each_object(UnboundMethod).find { |m| m.owner == UI::Toolbar && m.name == :show && m.source_location.nil? }
      native ? native.bind(@toolbar).call : warn('[对象信息与轴点] 请在“视图→工具栏”显示工具栏。')
    end

    unless @ui_registered
      @command = UI::Command.new('对象信息与轴点') { AxisInspector.open }
      @command.tooltip = '查看对象信息、编辑世界/父级坐标、快捷移动轴点'
      @command.status_bar_text = '坐标编辑移动整个对象；包围框点位只改变轴点。'
      @command.small_icon = @command.large_icon = File.join(__dir__, 'icons', 'axis.svg')
      UI.menu('Extensions').add_item(@command)
      UI.add_context_menu_handler do |menu|
        selected = Sketchup.active_model.selection.to_a
        menu.add_item(@command) if selected.length == 1 && Core.container?(selected.first)
      end
      @toolbar = UI::Toolbar.new('对象信息与轴点')
      @toolbar.add_item(@command)
      previous = @toolbar.get_last_state
      @toolbar.restore
      first = !Sketchup.read_default('ZhiAxisInspector', 'toolbar_initialized', false)
      show_toolbar if first || previous == TB_VISIBLE
      Sketchup.write_default('ZhiAxisInspector', 'toolbar_initialized', true) if first
      @ui_registered = true
    end
  end
end
