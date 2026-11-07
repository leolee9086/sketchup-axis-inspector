# encoding: UTF-8
# SPDX-License-Identifier: AGPL-3.0-only
require_relative 'shrink_math'

module Zhi
  module AxisInspector
    module Shrink
      extend self
      Math3 = ShrinkMath
      class Cancelled < AxisError; end

      def bounds_array(bounds)
        bounds.empty? ? nil : [bounds.min.to_a.map(&:to_f),bounds.max.to_a.map(&:to_f)]
      end
      def epsilon(bounds)
        [Math3.sizes(bounds).max*1.0e-10,1.0e-7].max
      end
      def capture(model)
        objects=model.selection.to_a
        raise AxisError,'请选择一个或多个组／组件。' if objects.empty? || objects.any? { |e| !Core.container?(e) }
        parent=model.active_path || []
        paths=objects.map { |e| parent+[e] }
        paths.each { |path| Core.valid_path!(model,path) }
        {model:model, paths:paths, parent:parent.dup, selection:objects.dup}
      end
      def matrix(axes,origin=[0,0,0])
        Geom::Transformation.axes(Geom::Point3d.new(origin),*axes.map { |a| Geom::Vector3d.new(a) })
      end
      def changed?(shift)
        !Core.same_transform?(shift,Geom::Transformation.new)
      end

      # 只读计算器。pulse 可在 Fiber 中让出 UI 线程；不在分析期间打开事务。
      class Analysis
        attr_reader :capture,:nodes,:plans,:results,:stats,:options
        def initialize(capture,quality: :fast,nested:true,scope: :linked,&pulse)
          raise AxisError,'未知计算质量。' unless Math3::QUALITY.key?(quality)
          raise AxisError,'未知共享定义范围。' unless [:linked,:unique].include?(scope)
          @capture=capture; @options={quality:quality,nested:nested,scope:scope}
          @pulse=pulse || ->(_message) {}
          @nodes={}; @order=[]; @stats={vertices:0,definitions:0,bytes:0}; @plans={}; @results=[]
          @roots=capture[:paths].map { |p| p.last.definition }.uniq
          @lock_cache={}
          @started_at=Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        def pulse(message); @pulse.call(message); end
        def release_geometry
          @nodes.each_value { |node| node[:cloud]=nil; node[:directions]=nil }
        end
        def locked_ancestor?(definition,seen={})
          return @lock_cache[definition] if @lock_cache.key?(definition)
          return false if seen[definition]
          seen[definition]=true
          value=definition.instances.any? do |e|
            next false unless e.valid?
            parent=e.parent
            parent=parent.parent if parent.is_a?(Sketchup::Entities)
            e.locked? || (parent.is_a?(Sketchup::ComponentDefinition) && locked_ancestor?(parent,seen.dup))
          end
          @lock_cache[definition]=value
        end
        def blocked_reason(definition)
          return '空对象' if definition.bounds.empty?
          return '共享路径中有锁定上级' if @options[:scope]==:linked && locked_ancestor?(definition)
          instances=definition.instances.select(&:valid?)
          return '包含锁定实例' if instances.any?(&:locked?)
          return '包含粘接关系' if instances.any? { |e| e.respond_to?(:glued_to) && e.glued_to }
          behavior=definition.behavior
          return '开洞或面向相机的组件需要保留原轴向' if behavior.cuts_opening? || behavior.always_face_camera?
          return '包含锁定子对象' if definition.entities.any? { |e| e.respond_to?(:locked?) && e.locked? }
          instances.each { |e| Core.invertible!(e.transformation) }
          nil
        rescue AxisError => e
          e.message
        end
        def direction(bucket,vector,weight)
          a=Math3.unit(vector); return unless a
          index=a.index { |v| v.abs>1e-8 }
          a=a.map { |v| -v } if a[index]<0
          key=a.map { |v| (v*100).round }
          if bucket[key]
            bucket[key][1]+=weight
          elsif bucket.length<128
            bucket[key]=[a,weight]
          else
            # 有界 heavy-hitter 表，方向数量不会随曲面三角片数量增长。
            low=bucket.min_by { |_k,v| v[1] }
            bucket.delete(low[0]); bucket[key]=[a,low[1][1]+weight]
          end
        end
        def scan(definition,visiting={})
          raise AxisError,'检测到循环组件定义。' if visiting[definition]
          return @nodes[definition] if @nodes.key?(definition)
          visiting[definition]=true
          baseline=Shrink.bounds_array(definition.bounds)
          node={definition:definition,baseline:baseline,children:[],directions:{},reason:blocked_reason(definition),
            cloud:Math3::Cloud.new(Math3::QUALITY.fetch(@options[:quality])[:sample])}
          @nodes[definition]=node
          # 每个顶点只从它的第一条关联边读取，免去百万级顶点 ID 哈希表。
          definition.entities.each_with_index do |entity,index|
            if Core.container?(entity)
              node[:children] << [entity,entity.transformation]
              # 即使关闭内部改轴，也需知道完整依赖关系：另一个所选对象可能
              # 与深层子实例共享定义，外层方案必须计入它的实际新外框。
              scan(entity.definition,visiting)
            elsif entity.is_a?(Sketchup::Edge)
              entity.vertices.each { |v| node[:cloud].add(v.position.to_a.map(&:to_f)) if v.edges.first==entity }
              direction(node[:directions],(entity.end.position-entity.start.position).to_a,entity.length.to_f) if index%3==0
            elsif entity.is_a?(Sketchup::Face)
              direction(node[:directions],entity.normal.to_a,1.0) if index%17==0
            elsif entity.is_a?(Sketchup::ConstructionPoint)
              node[:cloud].add(entity.position.to_a.map(&:to_f))
            elsif entity.is_a?(Sketchup::ConstructionLine)
              if entity.start && entity.end
                node[:cloud].add(entity.start.to_a.map(&:to_f)); node[:cloud].add(entity.end.to_a.map(&:to_f))
              else
                node[:reason]='包含无限参考线，不能定义有限外框'
              end
            else
              # 文字、尺寸等实体的 bounds 可能依赖相机／标注偏移；保留其原生范围，
              # 应用时再检查实际结果，不能悄悄把它们从拟合范围里去掉。
              b=Shrink.bounds_array(entity.bounds) if entity.respond_to?(:bounds)
              Math3.corners(b).each { |p| node[:cloud].add(p) } if b
            end
            pulse('读取几何') if index%256==0
          end
          @stats[:vertices]+=node[:cloud].count; @stats[:bytes]+=node[:cloud].data.bytesize
          @stats[:definitions]+=1
          @order << definition; visiting.delete(definition); node
        end
        def child_points(node,plans)
          points=Math3::Cloud.new(Math3::QUALITY.fetch(@options[:quality])[:sample])
          node[:children].each_with_index do |(child,transform),index|
            plan=plans[child.definition]
            bounds=plan ? plan[:bounds] : Shrink.bounds_array(child.definition.bounds)
            next unless bounds
            t=plan ? transform*plan[:shift] : transform
            Math3.corners(bounds).each { |p| points.add(Geom::Point3d.new(p).transform(t).to_a) }
            pulse('核定嵌套外框') if index%64==0
          end
          @stats[:largest_nested_cache_bytes]=[@stats.fetch(:largest_nested_cache_bytes,0),points.data.bytesize].max
          points
        end
        def fit(node,plans)
          baseline=node[:baseline]
          return {shift:Geom::Transformation.new,bounds:baseline,reason:node[:reason]} if !baseline || node[:reason]
          extra=child_points(node,plans)
          # 子实例外框也紧凑缓存，只取有限样本搜索；最终核定包含全部盒角。
          sample=node[:cloud].sample+extra.sample
          return {shift:Geom::Transformation.new,bounds:baseline,reason:'没有可拟合的几何'} if sample.empty?
          directions=node[:directions].values.sort_by { |_,w| -w }.map(&:first)
          eps=Shrink.epsilon(baseline)
          frames=Math3.candidates(sample,directions,@options[:quality],eps,-> { pulse('搜索轴向') })
          evaluated=Math3.exact(node[:cloud],extra,frames,-> { pulse('全量核定边界') })
          current=evaluated.first
          # exact 的首项恒为当前轴向；即使子级发生变化，当前方案仍作为基线。
          evaluated.each { |entry| current=entry if Math3.better?(entry[1],current[1],eps) }
          axes,box=current
          original=evaluated.find { |a,_| Math3.key(a)==Math3.key(Math3::IDENTITY) }[1]
          unless Math3.better?(box,original,eps,1e-5)
            return {shift:Geom::Transformation.new,bounds:original,reason:'当前轴向已较紧，未找到明显改善'}
          end
          rotation=Shrink.matrix(axes)
          origin=Geom::Point3d.new(box[0]).transform(rotation).to_a
          shift=Shrink.matrix(axes,origin)
          {shift:shift,bounds:[[0.0]*3,Math3.sizes(box)],reason:nil}
        end
        def unchanged_plan(node,plans)
          baseline=node[:baseline]
          return {shift:Geom::Transformation.new,bounds:baseline,reason:node[:reason]} unless baseline
          children_changed=node[:children].any? do |child,_|
            plan=plans[child.definition]
            plan && (Shrink.changed?(plan[:shift]) || plan[:bounds]!=@nodes[child.definition][:baseline])
          end
          box=if children_changed
            extra=child_points(node,plans)
            Math3.exact(node[:cloud],extra,[Math3::IDENTITY],-> { pulse('核定共享依赖外框') }).first[1]
          else
            baseline
          end
          {shift:Geom::Transformation.new,bounds:box,reason:node[:reason]}
        end
        def root_ok?(plans)
          @roots.all? do |definition|
            before=@nodes[definition][:baseline]; after=plans[definition][:bounds]
            !before || Math3.no_worse?(after,before,Shrink.epsilon(before))
          end
        end
        def run
          @capture[:paths].each do |path|
            raise AxisError,'对象或上级已锁定。' if path.any?(&:locked?)
            Core.invertible!(Core.world_transform(path))
            scan(path.last.definition)
          end
          # 一个容器被保留原状时，其子框也必须冻结，否则预测的父边界会过期。
          freeze_children=lambda do |node,seen|
            node[:children].each do |child,_|
              d=child.definition; next if seen[d] || !@nodes[d]
              seen[d]=true; nested=@nodes[d]
              nested[:reason] ||= '上级包含不能改轴的内容，保留内部轴向'
              freeze_children.call(nested,seen)
            end
          end
          @nodes.values.select { |node| node[:reason] }.each { |node| freeze_children.call(node,{}) }
          # 方案 A：子级先拟合，再拟合所选外层。方案 B：保持所有子级原轴，
          # 只拟合所选定义。A 不能让任何所选外框变差；否则使用经过全量验证的 B。
          recursive={}
          @order.each do |d|
            node=@nodes[d]
            recursive[d]=if @options[:nested] || @roots.include?(d)
              fit(node,recursive)
            else
              unchanged_plan(node,recursive)
            end
          end
          direct={}
          @order.each do |d|
            node=@nodes[d]
            direct[d]=if @roots.include?(d)
              node[:children].empty? ? recursive[d] : fit(node,direct)
            else
              unchanged_plan(node,direct)
            end
          end
          use_recursive=root_ok?(recursive) && @roots.all? do |d|
            base=direct[d][:bounds]; candidate=recursive[d][:bounds]
            !base || Math3.no_worse?(candidate,base,Shrink.epsilon(base))
          end
          @plans=use_recursive ? recursive : direct
          unless root_ok?(@plans)
            @plans={}
            @roots.each { |d| @plans[d]={shift:Geom::Transformation.new,bounds:@nodes[d][:baseline],reason:'嵌套范围没有整体改善'} }
          end
          @roots.each do |d|
            before=@nodes[d][:baseline]; plan=@plans[d]
            after=plan[:bounds]; eps=before && Shrink.epsilon(before)
            improved=before && after && Math3.better?(after,before,eps,1e-5)
            bscore=before && Math3.score(before,eps); ascore=after && Math3.score(after,eps)
            @results << {definition:d,name:d.name,before:before,after:after,improved:!!improved,
              measure:bscore && bscore[0],ratio:bscore && ascore[0]==bscore[0] ? ascore[1]/bscore[1] : nil,
              reason:improved ? nil : (plan[:reason] || '当前搜索未找到更紧的整体外框')}
          end
          # 没有任何选中对象改善时，不为了子级收益改变模型。
          @plans={} unless @results.any? { |r| r[:improved] }
          @stats[:analysis_seconds]=(Process.clock_gettime(Process::CLOCK_MONOTONIC)-@started_at).round(4)
          self
        end
      end

      def reaxis(definition,shift)
        return unless changed?(shift)
        inverse=shift.inverse
        instances=definition.instances.select(&:valid?).map { |e| [e,e.transformation] }
        # G'=A^-1 G, I'=I A；完整矩阵补偿保留镜像、剪切、非均匀缩放。
        # 使用一次原生 transform_entities，避免分片变换破坏共享顶点拓扑。
        definition.entities.transform_entities(inverse,definition.entities.to_a)
        instances.each { |e,t| e.transformation=t*shift }
        definition.invalidate_bounds
        instances.each do |e,t|
          raise AxisError,'实例补偿校验失败，操作已回滚。' unless Core.same_transform?(t,e.transformation*inverse)
        end
      end

      # 在外层事务内隔离所选子树，按原定义复用克隆，保留所选区域内部共享关系。
      # 临时属性只负责跨 make_unique 重定位，结束前清除，失败由事务回滚。
      def isolate(analysis,dictionary)
        model=analysis.capture[:model]; tagged=[]; clones=Hash.new { |h,k| h[k]=[] }
        originals=analysis.nodes.keys.to_h { |d| [d.guid,d] }
        roots=analysis.capture[:paths].map { |p| [p.last.persistent_id.to_s,p.last.definition] }
        parent_tokens=analysis.capture[:parent].map { |e| e.persistent_id.to_s }
        mark=->(e) do
          e.set_attribute(dictionary,'token',e.persistent_id.to_s)
          e.set_attribute(dictionary,'definition',e.definition.guid)
          tagged << e
        end
        analysis.nodes.each_key { |d| d.entities.each { |e| mark.call(e) if Core.container?(e) } }
        analysis.capture[:paths].flatten.uniq.each { |e| mark.call(e) }
        entities=model.entities; parent=[]
        # 多选共享同一父路径，父路径只能隔离一次，不能逐个目标重复打 step 标签。
        parent_tokens.each do |token|
          e=entities.find { |item| item.get_attribute(dictionary,'token')==token }
          raise AxisError,'隔离父路径后找不到原对象。' unless e && Core.container?(e)
          e.make_unique if e.definition.instances.count(&:valid?)>1
          parent << e; tagged << e; entities=e.definition.entities
        end
        needs_clone={}
        analysis.plans.each do |source,plan|
          needs_clone[source]=changed?(plan[:shift]) || analysis.nodes[source][:children].any? { |child,_| needs_clone[child.definition] }
        end
        visit=lambda do |instance,source|
          if !clones[source].empty? && instance.is_a?(Sketchup::ComponentInstance)
            instance.definition=clones[source].first
          else
            instance.make_unique if instance.definition.instances.count(&:valid?)>1
            clone=instance.definition; clones[source] << clone
            clone.entities.each do |child|
              next unless Core.container?(child)
              original=originals[child.get_attribute(dictionary,'definition')]
              visit.call(child,original) if original && needs_clone[original]
            end
          end
          tagged << instance
        end
        paths=roots.map do |token,source|
          e=entities.find { |item| item.get_attribute(dictionary,'token')==token }
          raise AxisError,'隔离后找不到所选对象。' unless e && Core.container?(e)
          if needs_clone[source]
            visit.call(e,source)
          else
            clones[source] << e.definition
          end
          parent+[e]
        end
        cleanup=(originals.values+clones.values.flatten+parent.map(&:definition)).uniq
        cleanup.each { |d| d.entities.each { |e| e.delete_attribute(dictionary) if e.attribute_dictionary(dictionary) } }
        tagged.each { |e| e.delete_attribute(dictionary) if e.valid? && e.attribute_dictionary(dictionary) }
        [clones,paths]
      end

      def apply(analysis,transaction:true)
        model=analysis.capture[:model]
        raise AxisError,'模型已切换。' unless Sketchup.active_model==model
        paths=analysis.capture[:paths]
        paths.each { |p| Core.valid_path!(model,p) }
        return {changed:false,results:analysis.results,stats:analysis.stats} if analysis.plans.empty?
        operation=false
        begin
          if transaction
            model.start_operation('收缩盒子',true); operation=true
          end
          model.active_path=nil if model.active_path
          mapping=analysis.nodes.keys.to_h { |d| [d,[d]] }
          if analysis.options[:scope]==:unique
            mapping,paths=isolate(analysis,"_zhi_shrink_#{SecureRandom.hex(12)}")
          end
          # 计划的插入顺序就是自底向上的依赖顺序；每个定义只改一次。
          analysis.plans.each do |original,plan|
            next unless plan[:bounds]
            Array(mapping[original]).uniq.each do |definition|
              reason=analysis.blocked_reason(definition)
              raise AxisError,reason if reason && changed?(plan[:shift])
              reaxis(definition,plan[:shift])
            end
          end
          # SketchUp 的原生包围框是最终判据，包括文字、图片等实体的真实行为。
          analysis.results.each do |r|
            next unless r[:before]
            Array(mapping[r[:definition]]).each do |d|
              d.invalidate_bounds; actual=bounds_array(d.bounds)
              raise AxisError,'原生外框没有符合整体收紧要求，已恢复原状。' unless actual && Math3.no_worse?(actual,r[:before],epsilon(r[:before]))
              if r[:improved] && !Math3.better?(actual,r[:before],epsilon(r[:before]),1e-5)
                raise AxisError,'原生外框未获得预期改善，已恢复原状。'
              end
              r[:after]=actual
            end
          end
          # 进入共享普通组可能触发 SketchUp 自动独立化；停止在它外面保留联动关系。
          parent=paths.first[0...-1]
          stop=parent.index { |e| e.is_a?(Sketchup::Group) && e.definition.instances.count(&:valid?)>1 }
          if stop
            model.active_path=stop.zero? ? nil : parent[0...stop]
            model.selection.clear; model.selection.add(parent[stop])
          else
            model.active_path=parent.empty? ? nil : parent
            model.selection.clear
            remaining=paths.map(&:last).select(&:valid?)
            model.selection.add(remaining) unless remaining.empty?
          end
          model.commit_operation if operation
          operation=false
          {changed:true,results:analysis.results,stats:analysis.stats,paths:paths}
        rescue Exception
          model.abort_operation if operation
          raise
        end
      end
    end
  end
end
