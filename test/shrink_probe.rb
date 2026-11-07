# encoding: UTF-8
require 'sketchup.rb'
require 'json'
# 独立调查入口；始终回滚，不保存 fixture。
UI.start_timer(3, false) do
  model = Sketchup.active_model
  root = File.expand_path('..', __dir__)
  report = { pid: Process.pid, time: Time.now.to_s }
  operation = false
  begin
    raise 'Only fixture' unless model.path.tr('\\', '/') == "#{root}/test/fixture.skp"
    model.start_operation('收缩盒子边界调查', true)
    operation = true
    parent = model.entities.add_group
    child = parent.entities.add_group
    child.entities.add_face([0,0,0], [100,0,0], [100,10,0], [0,10,0]).pushpull(5)
    child.transformation = Geom::Transformation.rotation(ORIGIN, Z_AXIS, 35.degrees)
    bb = ->(b) { [b.min.to_a, b.max.to_a] }
    report[:nested] = { child: bb.call(child.bounds), parent: bb.call(parent.definition.bounds) }
    parent.transformation = Geom::Transformation.rotation(ORIGIN, X_AXIS, 21.degrees)
    tr = Geom::Transformation.rotation(ORIGIN, Y_AXIS, 17.degrees)
    parent.definition.entities.transform_entities(tr.inverse, parent.definition.entities.to_a)
    parent.transformation = parent.transformation * tr
    parent.definition.invalidate_bounds
    report[:reaxis] = { parent: bb.call(parent.definition.bounds), child: bb.call(child.bounds) }
    group = model.entities.add_group
    group.entities.add_cpoint([0,0,0]); group.entities.add_cpoint([5,3,2])
    report[:points] = bb.call(group.definition.bounds)
    group.entities.add_cline([0,0,0], [1000,1000,1000])
    group.definition.invalidate_bounds
    report[:guide] = bb.call(group.definition.bounds)
    report[:success] = true
  rescue Exception => e
    report[:success] = false; report[:error] = e.full_message
  ensure
    model.abort_operation if operation
    File.write("#{root}/docs/shrink-probe.json", JSON.pretty_generate(report))
  end
end
