# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module Zhi
  module AxisInspector
    unless const_defined?(:EXTENSION)
      EXTENSION = SketchupExtension.new('对象信息与轴点', 'zhi_axis_inspector/main')
      EXTENSION.description = '查看组/组件信息、编辑坐标与步进、15点原位改轴；通用收缩盒子，保持几何原位。'
      EXTENSION.version = '1.2.0'
      EXTENSION.creator = '织 / leolee9086'
      EXTENSION.copyright = '2026 织 / leolee9086'
      register = Sketchup.method(:register_extension)
      # 兼容本机已核实的扩展管理器，仅注册本扩展，不修改其他扩展或全局入口。
      if register.owner.name == 'PiziSketchup' && register.super_method && register.super_method.source_location.nil?
        register.super_method.call(EXTENSION, true)
      else
        register.call(EXTENSION, true)
      end
    end
  end
end
