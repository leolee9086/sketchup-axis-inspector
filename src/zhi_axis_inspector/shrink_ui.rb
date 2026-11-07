# encoding: UTF-8
# SPDX-License-Identifier: AGPL-3.0-only
require_relative 'shrink'
module Zhi
  module AxisInspector
    module ShrinkUI
      extend self
      class Guard < Sketchup::ModelObserver
        def initialize(job); @job=job; end
        def onTransactionCommit(*); @job.stale=true; end
        def onTransactionUndo(*); @job.stale=true; end
        def onTransactionRedo(*); @job.stale=true; end
        def onTransactionAbort(*); @job.stale=true; end
        def onActivePathChanged(*); @job.stale=true; end
      end
      class Job
        attr_accessor :stale,:cancelled
        attr_reader :capture,:analysis,:result,:error,:done
        def initialize(capture,options,&notify)
          @capture=capture; @options=options; @notify=notify
          @stale=@cancelled=@done=false; @applying=false
          @guard=Guard.new(self); capture[:model].add_observer(@guard)
          @fiber=Fiber.new do
            @analysis=Shrink::Analysis.new(capture,**options) { |message| pulse(message) }
            @analysis.run
            validate!
            detach
            @applying=true
            @notify.call('正在应用，完成后可一步撤销。',false)
            @result=Shrink.apply(@analysis)
            @done=true
          end
        end
        def validate!
          raise Shrink::Cancelled,'已取消，模型未改变。' if @cancelled
          raise AxisError,'计算期间模型发生变化，请重新执行收缩盒子。' if @stale
          model=@capture[:model]
          same=Sketchup.active_model==model && (model.active_path || [])==@capture[:parent] && model.selection.to_a.sort_by(&:persistent_id)==@capture[:selection].sort_by(&:persistent_id)
          raise AxisError,'选择或编辑层级已改变，请重新执行收缩盒子。' unless same
        end
        def pulse(message)
          validate!
          now=Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return if now<@deadline
          stats=@analysis && @analysis.stats
          detail=stats ? "#{message} · 已读 #{stats[:definitions]} 个定义 / #{stats[:vertices]} 个顶点" : message
          @notify.call(detail,true)
          Fiber.yield
        end
        def tick
          return if @done
          @deadline=Process.clock_gettime(Process::CLOCK_MONOTONIC)+0.025
          @fiber.resume
          @done=true unless @fiber.alive?
        rescue Exception => error
          @error=error; @done=true
        ensure
          if @done
            detach
            @analysis.release_geometry if @analysis
            @fiber=nil
          end
        end
        def detach
          @capture[:model].remove_observer(@guard) if @guard
          @guard=nil
        end
      end
      def send_state(data)
        @dialog.execute_script("window.ShrinkPanel.receive(#{JSON.generate(data)})") if @dialog && @ready
      end
      def selection_state
        capture=Shrink.capture(Sketchup.active_model)
        {valid:true,count:capture[:selection].length,names:capture[:selection].map { |e| Core.name(e) }.first(8)}
      rescue AxisError => error
        {valid:false,count:0,message:error.message}
      end
      def open
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          send_state(selection_state.merge(phase:'idle')) unless @job
          return
        end
        @ready=false
        @dialog=UI::HtmlDialog.new(dialog_title:'收缩盒子',preferences_key:'ZhiShrinkBox',scrollable:true,
          resizable:true,width:490,height:620,min_width:420,min_height:420,style:UI::HtmlDialog::STYLE_DIALOG)
        @dialog.add_action_callback('shrink_ready') { |_ctx| @ready=true; send_state(selection_state.merge(phase:'idle')) }
        @dialog.add_action_callback('shrink_refresh') { |_ctx| send_state(selection_state.merge(phase:'idle')) unless @job }
        @dialog.add_action_callback('shrink_start') { |_ctx,json| start(JSON.parse(json)) }
        @dialog.add_action_callback('shrink_cancel') { |_ctx| @job.cancelled=true if @job }
        @dialog.set_on_closed do
          @job.cancelled=true if @job
          @ready=false; @dialog=nil
        end
        @dialog.set_file(File.join(__dir__,'ui','shrink.html'))
        @dialog.show
      end
      def start(request)
        return if @job
        options={quality:request.fetch('quality').to_sym,nested:request.fetch('nested'),scope:request.fetch('scope').to_sym}
        raise AxisError,'内部容器选项无效。' unless [true,false].include?(options[:nested])
        capture=Shrink.capture(Sketchup.active_model)
        @job=Job.new(capture,options) do |message,cancellable|
          Sketchup.status_text="收缩盒子：#{message}"
          send_state(phase:'running',message:message,cancellable:cancellable)
        end
        send_state(phase:'running',message:'正在读取所选对象…',cancellable:true)
        schedule
      rescue StandardError => error
        send_state(phase:'error',message:error.message)
      end
      def schedule
        @timer=UI.start_timer(0.01,false) do
          @timer=nil
          job=@job
          if job
            job.tick
            if job.done
              @last_job=job; @job=nil
              if job.error
                warn("[收缩盒子] #{job.error.full_message}") unless job.error.is_a?(AxisError)
                send_state(phase:job.error.is_a?(Shrink::Cancelled) ? 'cancelled' : 'error',message:job.error.message)
              else
                rows=job.result[:results].map do |r|
                  metric={0=>'点',1=>'长度',2=>'面积',3=>'体积'}[r[:measure]]
                  label=if r[:improved]
                    r[:ratio] ? "外框#{metric}减少 #{((1-r[:ratio])*100).round(2)}%" : '外框已贴合有效几何维度'
                  else
                    r[:reason]
                  end
                  {name:r[:name].empty? ? '未命名对象' : r[:name],message:label}
                end
                send_state(phase:'done',message:job.result[:changed] ? '已完成，物体保持原位。Ctrl+Z 可一步撤销。' : '没有找到明显改善，模型未改变。',rows:rows,stats:job.result[:stats])
              end
              AxisInspector.schedule_refresh
              Sketchup.status_text='收缩盒子计算结束。'
            else
              schedule
            end
          end
        end
      end
    end
  end
end
