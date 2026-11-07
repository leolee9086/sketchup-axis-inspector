# encoding: UTF-8
# SPDX-License-Identifier: AGPL-3.0-only
module Zhi
  module AxisInspector
    # 与 SketchUp 无关的数值部分。坐标使用英寸；候选阶段抽样，最终边界全量计算。
    module ShrinkMath
      extend self
      IDENTITY = [[1.0,0.0,0.0],[0.0,1.0,0.0],[0.0,0.0,1.0]].freeze
      QUALITY = {
        fast: { sample: 768, directions: 12, random: 16, finalists: 4, starts: 2 },
        fine: { sample: 2048, directions: 20, random: 48, finalists: 8, starts: 4 }
      }.freeze
      def dot(a,b); a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; end
      def cross(a,b); [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]; end
      def sub(a,b); [a[0]-b[0],a[1]-b[1],a[2]-b[2]]; end
      def unit(a)
        n = Math.sqrt(dot(a,a))
        n > 1.0e-14 ? a.map { |v| v/n } : nil
      end
      def frame(x,y)
        x = unit(x)
        return unless x
        z = unit(cross(x,y))
        return unless z
        canonical([x, cross(z,x), z])
      end
      # 盒子的 24 种等价右手坐标中，选择最接近当前轴的方向，防止轴名随意交换。
      def canonical(axes)
        best = nil; score = -Float::INFINITY
        [0,1,2].permutation do |order|
          [-1.0,1.0].each do |sx|
            [-1.0,1.0].each do |sy|
              x = axes[order[0]].map { |v| v*sx }
              y = axes[order[1]].map { |v| v*sy }
              z = cross(x,y)
              s = x[0]+y[1]+z[2]
              if s > score
                best = [x,y,z]; score = s
              end
            end
          end
        end
        best
      end
      def key(axes); axes.flatten.map { |v| (v*1.0e7).round }; end
      def extents(points, axes)
        lo = [Float::INFINITY]*3; hi = [-Float::INFINITY]*3
        points.each do |p|
          3.times do |i|
            v = dot(p,axes[i]); lo[i] = v if v < lo[i]; hi[i] = v if v > hi[i]
          end
        end
        [lo,hi]
      end
      def sizes(bounds); 3.times.map { |i| [bounds[1][i]-bounds[0][i],0.0].max }; end
      def score(bounds, epsilon)
        dimensions = sizes(bounds).select { |d| d > epsilon }
        [dimensions.length, dimensions.inject(1.0) { |a,v| a*v }]
      end
      def better?(a,b,epsilon,relative=1.0e-7)
        sa,sb = score(a,epsilon),score(b,epsilon)
        sa[0] < sb[0] || (sa[0] == sb[0] && sa[1] < sb[1]*(1.0-relative))
      end
      def no_worse?(a,b,epsilon)
        sa,sb = score(a,epsilon),score(b,epsilon)
        sa[0] < sb[0] || (sa[0] == sb[0] && sa[1] <= sb[1]*(1.0+1.0e-6))
      end
      def corners(bounds)
        8.times.map { |i| [bounds[(i&1)][0],bounds[(i>>1)&1][1],bounds[(i>>2)&1][2]] }
      end
      # 对称矩阵 Jacobi 特征分解；主轴仅是候选，不能代替包围盒搜索。
      def principal(points)
        origin = points.first
        mean = [0.0]*3; a = Array.new(3) { [0.0]*3 }
        points.each_with_index do |p,n|
          q = sub(p,origin); delta = sub(q,mean)
          3.times { |i| mean[i] += delta[i]/(n+1) }
          tail = sub(q,mean)
          3.times { |i| 3.times { |j| a[i][j] += delta[i]*tail[j] } }
        end
        v = IDENTITY.map(&:dup)
        32.times do
          p,q = [[0,1],[0,2],[1,2]].max_by { |i,j| a[i][j].abs }
          break if a[p][q].abs < [a[0][0].abs+a[1][1].abs+a[2][2].abs,1.0].max*1.0e-14
          theta = 0.5*Math.atan2(2*a[p][q],a[q][q]-a[p][p])
          c,s = Math.cos(theta),Math.sin(theta)
          app,aqq,apq = a[p][p],a[q][q],a[p][q]
          a[p][p] = c*c*app-2*s*c*apq+s*s*aqq
          a[q][q] = s*s*app+2*s*c*apq+c*c*aqq
          a[p][q] = a[q][p] = 0.0
          3.times do |k|
            unless k==p || k==q
              akp,akq = a[k][p],a[k][q]
              a[k][p] = a[p][k] = c*akp-s*akq
              a[k][q] = a[q][k] = s*akp+c*akq
            end
            vp,vq = v[k][p],v[k][q]
            v[k][p] = c*vp-s*vq; v[k][q] = s*vp+c*vq
          end
        end
        order = [0,1,2].sort_by { |i| -a[i][i] }
        axes = order.map { |i| 3.times.map { |j| v[j][i] } }
        [frame(axes[0],axes[1]), axes]
      end
      def hull2(points)
        points = points.uniq.sort
        return points if points.length < 3
        cross2 = ->(o,a,b) { (a[0]-o[0])*(b[1]-o[1])-(a[1]-o[1])*(b[0]-o[0]) }
        halves = [points,points.reverse].map do |sequence|
          h=[]
          sequence.each do |p|
            h.pop while h.length>=2 && cross2.call(h[-2],h[-1],p)<=0
            h << p
          end
          h[0...-1]
        end
        halves.flatten(1)
      end
      def rotate(axes,index,angle)
        a,b=(index+1)%3,(index+2)%3
        c,s=Math.cos(angle),Math.sin(angle)
        result=axes.map(&:dup)
        result[a]=3.times.map { |j| axes[a][j]*c+axes[b][j]*s }
        result[b]=3.times.map { |j| axes[b][j]*c-axes[a][j]*s }
        canonical(result)
      end
      def candidates(points,directions,quality,epsilon,pulse)
        config=QUALITY.fetch(quality)
        candidates={}; add=->(axes) { candidates[key(axes)]=axes if axes }
        add.call(IDENTITY)
        pca,raw=principal(points); add.call(pca)
        dirs=directions.first(config[:directions])+raw+IDENTITY
        dirs.each do |x|
          # 共线情况也得到确定的垂直轴，不固定任何世界竖向。
          helper=IDENTITY.min_by { |a| dot(a,x).abs }
          add.call(frame(x,helper))
        end
        dirs.combination(2) { |x,y| add.call(frame(x,y)) }
        # 在主平面投影的凸包边方向上取候选；也用于普通三维对象的投影搜索。
        raw.each do |normal|
          x=unit(cross(normal,IDENTITY.min_by { |a| dot(a,normal).abs }))
          y=cross(normal,x)
          hull=hull2(points.map { |p| [dot(p,x),dot(p,y)] })
          stride=[hull.length/64,1].max
          hull.each_with_index do |p,i|
            next unless i%stride==0
            q=hull[(i+1)%hull.length]; d=[q[0]-p[0],q[1]-p[1]]
            edge=3.times.map { |j| x[j]*d[0]+y[j]*d[1] }
            add.call(frame(edge,cross(normal,edge)))
          end
        end
        random=Random.new(72351)
        config[:random].times do
          x=Array.new(3){random.rand*2-1}; y=Array.new(3){random.rand*2-1}
          add.call(frame(x,y))
        end
        ranked=candidates.values.map do |axes|
          result=[axes,extents(points,axes)]; pulse.call; result
        end.sort_by { |axes,bounds| [*score(bounds,epsilon),-axes.each_with_index.sum { |axis,i| axis[i] }] }
        ranked.first(config[:starts]).each do |axes,bounds|
          [10.0,3.0,1.0,0.25,0.05].each do |degrees|
            3.times do
              improved=false
              3.times do |i|
                [-1,1].each do |sign|
                  candidate=rotate(axes,i,degrees*Math::PI/180*sign)
                  box=extents(points,candidate)
                  if better?(box,bounds,epsilon)
                    axes,bounds=candidate,box; improved=true
                  end
                  pulse.call
                end
              end
              break unless improved
            end
          end
          ranked << [axes,bounds]
        end
        ranked.sort_by! { |axes,bounds| [*score(bounds,epsilon),-axes.each_with_index.sum { |axis,i| axis[i] }] }
        seen={}; result=[]
        ranked.each do |axes,_|
          k=key(axes); next if seen[k]
          seen[k]=true; result << axes
          break if result.length>=config[:finalists]
        end
        result.reject! { |a| key(a)==key(IDENTITY) }
        result.unshift(IDENTITY)
        result
      end

      # 每个定义的原始点以 double 紧凑存放，只在小块计算时解包。
      # 缓存不会随实例数量放大；抽样固定种子，结果可复现。
      class Cloud
        attr_reader :count,:sample,:data
        def initialize(limit)
          @limit=limit; @data=''.b; @sample=[]; @count=0; @random=Random.new(41893)
        end
        def add(p)
          raise ArgumentError,'非有限几何坐标' unless p.all?(&:finite?)
          @data << p.pack('d3'); @count+=1
          if @sample.length<@limit
            @sample << p
          else
            i=@random.rand(@count); @sample[i]=p if i<@limit
          end
        end
        def chunks
          offset=0
          while offset<@data.bytesize
            yield @data.byteslice(offset,24*512).unpack('d*')
            offset+=24*512
          end
        end
      end
      # 所有入围方向共用一次全量遍历，未抽中的极端点仍参加最终边界核定。
      def exact(cloud,extra,frames,pulse)
        boxes=frames.map { [[Float::INFINITY]*3,[-Float::INFINITY]*3] }
        process=->(flat) do
          frames.each_with_index do |axes,k|
            lo,hi=boxes[k]; x,y,z=axes
            i=0
            while i<flat.length
              a,b,c=flat[i],flat[i+1],flat[i+2]
              u=a*x[0]+b*x[1]+c*x[2]; v=a*y[0]+b*y[1]+c*y[2]; w=a*z[0]+b*z[1]+c*z[2]
              lo[0]=u if u<lo[0]; hi[0]=u if u>hi[0]
              lo[1]=v if v<lo[1]; hi[1]=v if v>hi[1]
              lo[2]=w if w<lo[2]; hi[2]=w if w>hi[2]
              i+=3
            end
            pulse.call
          end
        end
        cloud.chunks { |flat| process.call(flat) }
        extra.chunks { |flat| process.call(flat) }
        frames.zip(boxes)
      end
    end
  end
end
