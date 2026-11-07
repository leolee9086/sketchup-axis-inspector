/* SPDX-License-Identifier: AGPL-3.0-only */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  let valid = false, running = false;
  function call(name, data) {
    if (!window.sketchup || typeof window.sketchup[name] !== 'function') {
      $('status').textContent = '未连接 SketchUp。'; return;
    }
    if (data === undefined) window.sketchup[name]();
    else window.sketchup[name](JSON.stringify(data));
  }
  function controls() {
    $('options').querySelectorAll('input,select,button').forEach(e => { e.disabled = running; });
    $('start').disabled = running || !valid;
    $('refresh').disabled = running;
    $('progress').hidden = !running;
  }
  function receive(data) {
    if (data.phase === 'idle') {
      valid = data.valid;
      $('selection').textContent = valid ? `已选择 ${data.count} 个对象` : '尚未选中组／组件';
      $('names').textContent = data.names ? data.names.join(' · ') : data.message;
    }
    running = data.phase === 'running';
    controls();
    $('cancel').disabled = data.cancellable === false;
    $('status').className = data.phase === 'error' ? 'error' : '';
    if (data.message) $('status').textContent = data.message;
    else if (data.phase === 'idle') $('status').textContent = valid ? '选择计算范围后开始。' : data.message;
    if (data.rows) {
      $('results').replaceChildren();
      for (const row of data.rows) {
        const li = document.createElement('li');
        const name = document.createElement('strong'), text = document.createElement('span');
        name.textContent = row.name; text.textContent = row.message;
        li.append(name, text); $('results').append(li);
      }
    }
  }
  $('options').addEventListener('submit', e => {
    e.preventDefault();
    if (running || !valid) return;
    $('results').replaceChildren();
    running = true; controls();
    call('shrink_start', {quality: $('quality').value, scope: $('scope').value, nested: $('nested').checked});
  });
  $('cancel').addEventListener('click', () => { call('shrink_cancel'); $('cancel').disabled = true; });
  $('refresh').addEventListener('click', () => call('shrink_refresh'));
  $('scope').addEventListener('change', () => {
    $('scope-help').textContent = $('scope').value === 'linked'
      ? '同定义实例一起调整轴向与轴点，各自内容保持原位。'
      : '所选对象及必要的父级、内部定义独立化，其它副本保持原状。';
  });
  window.ShrinkPanel = {receive};
  call('shrink_ready');
})();
