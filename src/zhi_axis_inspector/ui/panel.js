/* 对象信息与轴点。只使用本地资源，不加载第三方脚本。 */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const NS = 'http://www.w3.org/2000/svg';
  let state = null, busy = false, activePoint = null;
  let yaw = -0.7, pitch = 0.48, drag = null;
  const edges = [[0,1],[1,3],[3,2],[2,0],[4,5],[5,7],[7,6],[6,4],[0,4],[1,5],[2,6],[3,7]];
  const faces = [[0,1,3,2],[4,5,7,6],[0,1,5,4],[2,3,7,6],[0,2,6,4],[1,3,7,5]];
  const fmt = n => Number(n).toLocaleString('en-US', {maximumFractionDigits: 4, useGrouping: false});
  const xyz = a => a ? a.map(fmt).join(' / ') : '—';
  // 常用建模预设，不把习惯尺寸冒充强制规范；可随时输入工程实际值。
  const stepSeries = [
    {id:'fine', label:'精调 / 缝隙', values:[0.1,0.5,1,2,3,5,10,20]},
    {id:'building', label:'建筑模数 · M = 100 mm', values:[50,100,200,300,600,1200,3000,6000]},
    {id:'cabinet32', label:'柜体 / 五金 · 32 mm 系列', values:[16,32,64,96,128,160,192,224,256,320]},
    {id:'board', label:'常用板厚 / 材料', values:[3,5,9,12,15,18,20,25,30,36]},
    {id:'tile', label:'铺贴 / 吊顶常用尺寸', values:[100,150,200,300,400,450,600,800,900,1200]}
  ];
  function renderSteps() {
    const series = stepSeries.find(s => s.id === $('step-series').value);
    if (!series) return;
    $('step-presets').replaceChildren();
    series.values.forEach(value => {
      const button = document.createElement('button');
      button.type = 'button'; button.dataset.step = String(value); button.textContent = fmt(value);
      button.title = `${value} mm`; button.setAttribute('aria-label', `步长 ${value} 毫米`);
      button.addEventListener('click', () => { $('step-value').value = String(value); updateStepTitles(); });
      $('step-presets').append(button);
    });
    updateStepTitles();
  }
  function updateStepTitles() {
    const step = $('step-value').value.trim();
    document.querySelectorAll('[data-step]').forEach(b => b.classList.toggle('active', b.dataset.step === step));
    document.querySelectorAll('[data-nudge]').forEach(b => {
      const label = b.closest('form').dataset.space === 'world' ? '世界' : '父级';
      b.title = `${label} ${b.dataset.axis.toUpperCase()} ${b.dataset.nudge === '1' ? '增加' : '减少'} ${step || '（请输入步长）'}${/^[\d.]+$/.test(step) ? ' mm' : ''}`;
      b.setAttribute('aria-label', b.title);
    });
  }
  function nudge(space, axis, direction) {
    if (busy || !state || !state.position_movable) return;
    if (document.querySelector('.coord-form input.dirty')) {
      status('坐标有尚未应用的输入，请先按 Enter 应用，或 Esc 还原后再步进。', 'error'); return;
    }
    const step = $('step-value').value.trim();
    if (!step) { status('请输入大于零的移动步长。', 'error'); $('step-value').focus(); return; }
    pending(true); status(`正在沿${space === 'world' ? '世界' : '父级'} ${axis.toUpperCase()} 按步长移动…`);
    call('nudge_position', {revision:state.revision, space, axis, direction, step});
  }
  // 保持输入为 text，兼容 25cm 等单位；显式箭头避免 number 输入的隐式滚轮移动。
  document.querySelectorAll('.coord-row label').forEach(label => {
    const input = label.querySelector('input');
    const [space, axis] = input.id.split('-');
    const field = document.createElement('div'); field.className = label.className + ' coord-field';
    label.replaceWith(field); field.append(label);
    const arrows = document.createElement('div'); arrows.className = 'coord-arrows';
    for (const direction of [1,-1]) {
      const b = document.createElement('button'); b.type = 'button'; b.dataset.nudge = String(direction); b.dataset.axis = axis;
      b.textContent = direction === 1 ? '▲' : '▼'; b.addEventListener('click', () => nudge(space, axis, direction));
      arrows.append(b);
    }
    field.append(arrows);
    input.addEventListener('keydown', e => {
      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') { e.preventDefault(); if (!e.repeat) nudge(space, axis, e.key === 'ArrowUp' ? 1 : -1); }
    });
  });
  stepSeries.forEach(series => { const option=document.createElement('option');option.value=series.id;option.textContent=series.label;$('step-series').append(option); });
  $('step-series').addEventListener('change', renderSteps);
  $('step-value').addEventListener('input', updateStepTitles);
  renderSteps();
  function status(text, kind = '') { $('status').textContent = text; $('status').className = kind; }
  function pending(value) { busy = value; document.body.classList.toggle('busy', value); }
  function call(name, data) {
    if (!window.sketchup || typeof window.sketchup[name] !== 'function') {
      pending(false); status('未连接 SketchUp，不能修改模型。', 'error'); return;
    }
    if (data === undefined) window.sketchup[name]();
    else if (typeof data === 'boolean') window.sketchup[name](data);
    else window.sketchup[name](JSON.stringify(data));
  }
  function setWarning(id, message) { $(id).textContent = message || ''; $(id).hidden = !message; }
  function receive(data) {
    const hadDraft = !!document.querySelector('input.dirty');
    state = data; activePoint = null; pending(false);
    $('empty').hidden = data.selected;
    $('content').hidden = !data.selected;
    if (!data.selected) {
      $('empty-message').textContent = data.message;
      status(data.message); return;
    }
    $('object-name').textContent = data.name;
    $('type').textContent = data.type;
    $('solid').textContent = data.solid ? '实体' : '非实体';
    $('path').textContent = data.path;
    $('tag').textContent = `标签 · ${data.tag}`;
    $('instances').textContent = `同定义直接实例 · ${data.instance_count}`;
    for (const space of ['world', 'parent']) {
      data[space + '_origin'].forEach((v, i) => {
        const input = $(space + '-' + 'xyz'[i]);
        input.value = fmt(v); input.classList.remove('dirty');
        input.disabled = !data.position_movable;
      });
      $(space + '-form').querySelectorAll('button').forEach(button => { button.disabled = !data.position_movable; });
    }
    setWarning('position-warning', data.position_error);
    setWarning('axis-warning', data.blocked_reason || (data.dynamic ? '动态组件：修改轴点后，动态组件重绘可能重新计算其内部坐标。' : null));
    buildButtons(); renderCube(); updateScopeHint(); renderInfo(); hover(null, false);
    status(hadDraft ? '对象状态已更新，未应用的坐标输入已还原。' : '跟随当前选择 · 修改坐标移动物体，点选包围框只改轴。');
  }
  function result(data) { pending(false); status(data.message, data.ok ? 'success' : 'error'); }
  function createPointButton(point) {
    const b = document.createElement('button');
    b.type = 'button'; b.dataset.point = point.id; b.title = point.label;
    b.setAttribute('aria-label', '原位改轴到' + point.label);
    b.disabled = !state.movable;
    b.textContent = point.id.startsWith('c') && point.id !== 'center'
      ? point.label.replace('角点 · ', '') : point.label.replace('（底面）','').replace('（顶面）','');
    if (point.id === 'center') b.className = 'center-button';
    return b;
  }
  function buildButtons() {
    $('face-buttons').replaceChildren(); $('corner-buttons').replaceChildren();
    state.points.forEach(p => {
      const target = /^c\d$/.test(p.id) ? $('corner-buttons') : $('face-buttons');
      target.append(createPointButton(p));
    });
  }
  function updateScopeHint() {
    if (!state || !state.selected) return;
    $('scope-hint').textContent = $('scope').value === 'linked'
      ? '联动修改全部同定义实例的轴点；保持各物体原位，执行前会确认。'
      : state.shared_ancestors.length
        ? '当前对象位于共享父组件内：必要的父级会独立化，其他副本不变。'
        : state.instance_count > 1
          ? '当前实例会独立化；其他副本的轴点与位置不变。'
          : '仅修改当前对象；每次操作均可在 SketchUp 中 Ctrl+Z 撤销。';
  }
  function hover(id, notify = true) {
    if (!state || !state.selected) return;
    activePoint = id;
    document.querySelectorAll('[data-point]').forEach(e => e.classList.toggle('active', e.dataset.point === id));
    const p = state.points.find(p => p.id === id);
    $('target-readout').querySelector('strong').textContent = p ? p.label : '15 个快捷点位';
    $('target-readout').querySelector('span').textContent = p ? `目标世界坐标（mm）  X ${fmt(p.world[0])}   Y ${fmt(p.world[1])}   Z ${fmt(p.world[2])}` : '8 角点 · 6 面心 · 1 中心';
    if (notify && !busy) call('hover', {revision: state.revision, id});
  }
  function moveAxis(id) {
    if (busy || !state || !state.movable || !state.points.some(p => p.id === id)) return;
    pending(true); status('正在原位修改轴点…');
    call('move_axis', {revision: state.revision, id, scope: $('scope').value});
  }
  function renderInfo() {
    const s = state;
    const rows = [
      ['实例名称', s.instance_name || '未命名'], ['组件定义', s.definition_name || '—'],
      ['对象 ID', s.pid], ['材质', s.material],
      ['局部轴向尺寸', xyz(s.dimensions) + ' mm'], ['世界包围框尺寸', xyz(s.world_dimensions) + ' mm'],
      ['定义原始尺寸', xyz(s.definition_dimensions) + ' mm'], ['累计缩放 X/Y/Z', xyz(s.scale)],
      ['镜像', s.mirrored ? '是（含负向缩放）' : '否'],
      ['世界 X 轴方向', xyz(s.axes[0])], ['世界 Y 轴方向', xyz(s.axes[1])], ['世界 Z 轴方向', xyz(s.axes[2])],
      ['体积', s.volume_m3 === null ? '非封闭实体' : fmt(s.volume_m3) + ' m³'],
      ['直接内部实体数', String(s.entity_count)], ['锁定 / 隐藏', `${s.locked ? '锁定' : '未锁定'} / ${s.hidden ? '隐藏' : '显示'}`]
    ];
    if (s.description) rows.push(['定义说明', s.description]);
    const list = $('info-list'); list.replaceChildren();
    rows.forEach(([label,value]) => {
      const dt = document.createElement('dt'), dd = document.createElement('dd');
      dt.textContent = label; dd.textContent = value; list.append(dt, dd);
    });
  }
  function svg(tag, attrs, parent) {
    const element = document.createElementNS(NS, tag);
    Object.entries(attrs).forEach(([k,v]) => element.setAttribute(k, String(v)));
    if (parent) parent.append(element); return element;
  }
  function dimensions() {
    const d = state.definition_dimensions || [1,1,1];
    const max = Math.max(...d, 0.001);
    // 极薄构件也保留可点击厚度；此处是示意，不冒充尺寸精确的模型视图。
    return d.map(n => Math.max(n / max, 0.28));
  }
  function project(fraction) {
    const sizes = dimensions();
    let [x,y,z] = fraction.map((n,i) => (n - 0.5) * sizes[i] * 160);
    const a = x * Math.cos(yaw) - y * Math.sin(yaw);
    const b = x * Math.sin(yaw) + y * Math.cos(yaw);
    return {x: 240 + a, y: 112 + b * Math.sin(pitch) - z * Math.cos(pitch), depth: b * Math.cos(pitch) + z * Math.sin(pitch)};
  }
  function renderCube() {
    if (!state || !state.selected) return;
    ['cube-faces','cube-lines','cube-axes','cube-points'].forEach(id => $(id).replaceChildren());
    if (!state.points.length) return;
    const corners = Array.from({length:8}, (_,i) => project([i & 1, (i >> 1) & 1, (i >> 2) & 1]));
    faces.map(indices => ({indices, depth:indices.reduce((a,i)=>a+corners[i].depth,0)/4}))
      .sort((a,b)=>a.depth-b.depth).forEach(({indices}) => svg('polygon', {points: indices.map(i=>`${corners[i].x},${corners[i].y}`).join(' '), fill:'#a7cadc', 'fill-opacity':'.09', stroke:'none'}, $('cube-faces')));
    edges.forEach(([a,b])=>svg('line',{x1:corners[a].x,y1:corners[a].y,x2:corners[b].x,y2:corners[b].y,stroke:'#85a9bd','stroke-width':1.5},$('cube-lines')));
    const zero = project([0,0,0]);
    const colors = ['#c14d55','#318263','#3e72c3'];
    for(let i=0;i<3;i++) {
      const v = [0,0,0]; v[i] = 1.2;
      const tip = project(v);
      svg('line',{x1:zero.x,y1:zero.y,x2:tip.x,y2:tip.y,stroke:colors[i],'stroke-width':2,'stroke-opacity':.75},$('cube-axes'));
      const label=svg('text',{x:tip.x+5,y:tip.y-4,fill:colors[i],'font-size':12,'font-weight':700},$('cube-axes')); label.textContent='XYZ'[i];
    }
    // 同时显示当前原点在包围框中的相对位置。离框太远时不挤压示意，真实视图仍显示。
    const fraction=state.local_min.map((v,i)=>{
      const span=state.local_max[i]-v; return Math.abs(span)<1e-8 ? .5 : -v/span;
    });
    if(fraction.every(n=>n>=-.2&&n<=1.2)) {
      const o=project(fraction);
      svg('circle',{cx:o.x,cy:o.y,r:11,fill:'none',stroke:'#d79735','stroke-width':2,'stroke-dasharray':'3 2'},$('cube-axes'));
    }
    state.points.map(p=>({...p, projected:project(p.fraction)})).sort((a,b)=>a.projected.depth-b.projected.depth).forEach(p=>{
      const pt=p.projected;
      const g=svg('g',{'data-point':p.id,class:'point-hit'+(p.id===activePoint?' active':''),role:'button',tabindex:state.movable?0:-1,'aria-disabled':!state.movable,'aria-label':'原位改轴到'+p.label},$('cube-points'));
      svg('circle',{cx:pt.x,cy:pt.y,r:12,fill:'transparent'},g);
      svg('circle',{cx:pt.x,cy:pt.y,r:p.id==='center'?7:5.5,class:'node',fill:p.id==='center'?'#ce954c':/^c\d$/.test(p.id)?'#3e819e':'#6c9bb0'},g);
      const title=svg('title',{},g); title.textContent=p.label+' · 点击原位改轴';
    });
  }
  document.querySelectorAll('.coord-form').forEach(form=>{
    form.addEventListener('submit',event=>{
      event.preventDefault();
      if(busy||!state||!state.position_movable) return;
      const values=Array.from(form.querySelectorAll('input')).map(i=>i.value.trim());
      if(values.some(v=>!v)){status('请填写完整的 X、Y、Z 坐标。','error');return;}
      pending(true); status('正在按坐标移动整个物体…');
      call('move_position',{revision:state.revision,space:form.dataset.space,values});
    });
    form.addEventListener('input',event=>event.target.classList.add('dirty'));
    form.addEventListener('keydown',event=>{
      if(event.key==='Escape'&&state){event.preventDefault();state[form.dataset.space+'_origin'].forEach((v,i)=>{const el=form.querySelectorAll('input')[i];el.value=fmt(v);el.classList.remove('dirty');});status('已还原输入，物体没有移动。');}
    });
  });
  for(const id of ['face-buttons','corner-buttons','cube-points']) {
    const group=$(id);
    const point=target=>target.closest('[data-point]');
    group.addEventListener('mouseover',e=>{const p=point(e.target);if(p)hover(p.dataset.point);});
    group.addEventListener('mouseout',e=>{if(!group.contains(e.relatedTarget))hover(null);});
    group.addEventListener('focusin',e=>{const p=point(e.target);if(p)hover(p.dataset.point);});
    group.addEventListener('focusout',e=>{if(!group.contains(e.relatedTarget))hover(null);});
    group.addEventListener('click',e=>{const p=point(e.target);if(p)moveAxis(p.dataset.point);});
    if(id==='cube-points')group.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){const p=point(e.target);if(p){e.preventDefault();moveAxis(p.dataset.point);}}});
  }
  $('cube').addEventListener('pointerdown',e=>{if(e.target.closest('[data-point]'))return;drag={x:e.clientX,y:e.clientY,yaw,pitch};$('cube').setPointerCapture(e.pointerId);});
  $('cube').addEventListener('pointermove',e=>{if(!drag)return;yaw=drag.yaw+(e.clientX-drag.x)*.012;pitch=Math.max(-1.3,Math.min(1.3,drag.pitch+(e.clientY-drag.y)*.009));renderCube();});
  $('cube').addEventListener('pointerup',()=>{drag=null;});
  $('cube').addEventListener('pointercancel',()=>{drag=null;});
  $('reset-view').addEventListener('click',()=>{yaw=-.7;pitch=.48;renderCube();});
  $('refresh').addEventListener('click',()=>call('refresh'));
  $('scope').addEventListener('change',updateScopeHint);
  $('overlay').addEventListener('change',e=>call('overlay',e.target.checked));
  $('copy-info').addEventListener('click',()=>{
    if(!state||!state.selected)return;
    const text=[state.name,state.path,`世界轴点 (mm): ${xyz(state.world_origin)}`,`父级轴点 (mm): ${xyz(state.parent_origin)}`,...Array.from($('info-list').querySelectorAll('dt')).map(dt=>dt.textContent+': '+dt.nextElementSibling.textContent)].join('\n');
    // CEF 本地文件页不一定提供 Clipboard API，使用其支持的同步复制入口。
    const area=document.createElement('textarea');area.value=text;document.body.append(area);area.select();
    const ok=document.execCommand('copy');area.remove();status(ok?'对象信息已复制。':'复制未成功，请直接选中面板文字复制。',ok?'success':'error');
  });
  window.AxisPanel = {receive,result};
  call('ready');
})();
