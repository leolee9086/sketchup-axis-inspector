# encoding: UTF-8
# 在单独新建的空白 SketchUp 窗口内运行；绝不清空已有模型。
require 'sketchup.rb'
model = Sketchup.active_model
raise '请在独立空白模型中创建测试样例。' unless model.path.empty? && model.entities.empty? && model.active_path.nil?
file = File.expand_path('fixture.skp', __dir__)
raise '测试样例已存在，不覆盖。' if File.exist?(file)
raise '保存测试样例失败。' unless model.save(file)
puts "已创建测试样例：#{file}"
