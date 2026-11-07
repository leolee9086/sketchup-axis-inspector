# encoding: UTF-8
require 'json'
module ZhiShrinkBenchmark
  extend self
  ROOT=File.expand_path('..',__dir__)
  def report(data)
    File.write("#{ROOT}/docs/shrink-benchmark.json",JSON.pretty_generate(data.merge(pid:Process.pid,time:Time.now.to_s)))
  end
  def run(size=220)
    @model=Sketchup.active_model
    raise 'Only fixture' unless @model.path.tr('\\','/')=="#{ROOT}/test/fixture.skp"
    @model.start_operation('准备密集几何基准',true)
    @object=@model.entities.add_group
    mesh=Geom::PolygonMesh.new((size+1)**2,size*size*2)
    transform=Geom::Transformation.rotation([17,33,25],[1,2,3],0.61)
    (0..size).each do |y|
      (0..size).each do |x|
        # 有厚度的弯曲三角网格，避免仅用一个理想平面冒充通用密集几何。
        p=Geom::Point3d.new(x.to_f,y*0.4,Math.sin(x*0.03)*2+Math.cos(y*0.05))
        mesh.add_point(p.transform(transform))
      end
    end
    size.times do |y|
      size.times do |x|
        a=y*(size+1)+x+1; b=a+1; c=a+size+1; d=c+1
        mesh.add_polygon(a,b,d); mesh.add_polygon(a,d,c)
      end
    end
    @object.entities.fill_from_mesh(mesh,true,Geom::PolygonMesh::AUTO_SOFTEN|Geom::PolygonMesh::SMOOTH_SOFT_EDGES)
    @model.commit_operation
    @model.selection.clear; @model.selection.add(@object)
    @data={size:size,entities:@object.definition.entities.length,faces:size*size*2,expected_vertices:(size+1)**2,phase:'analysis',ticks:0,max_tick_ms:0.0}
    @started=Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @job=Zhi::AxisInspector::ShrinkUI::Job.new(Zhi::AxisInspector::Shrink.capture(@model),{quality: :fast,nested:true,scope: :linked}) { |_message,_cancel| }
    report(@data)
    tick
  rescue Exception=>error
    @model.abort_operation if @model
    report(success:false,error:error.full_message)
  end
  def tick
    UI.start_timer(0.01,false) do
      begin
        start=Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @job.tick
        ms=(Process.clock_gettime(Process::CLOCK_MONOTONIC)-start)*1000
        @data[:max_tick_ms]=[@data[:max_tick_ms],ms].max; @data[:ticks]+=1
        @data[:max_analysis_tick_ms]=[@data.fetch(:max_analysis_tick_ms,0.0),ms].max unless @job.done
        if @job.done
          raise @job.error if @job.error
          @data.merge!(success:true,phase:'done',total_seconds:Process.clock_gettime(Process::CLOCK_MONOTONIC)-@started,stats:@job.result[:stats],changed:@job.result[:changed])
          report(@data)
          Sketchup.send_action('editUndo:')
          UI.start_timer(0.1,false) { Sketchup.send_action('editUndo:') }
        else
          report(@data) if @data[:ticks]%100==0
          tick
        end
      rescue Exception=>error
        report(@data.merge(success:false,error:error.full_message))
      end
    end
  end
end
