'use strict';
(() => {
  const one = s => document.querySelector(s);
  const all = s => [...document.querySelectorAll(s)];
  const screenTabs = all('[data-screen]');
  const screenCopy = {
    tools: ['熟悉的工具，顺手的工作台。', '直接选择工具，调整参数，先看预览再保存结果。', '01 / 02'],
    rito: ['换一种方式，把想法说给 Rito。', '保留聊天与附件，一起核对参数，再让本机工具处理。', '02 / 02']
  };
  function selectScreen(key, focus = false) {
    screenTabs.forEach(tab => {
      const selected = tab.dataset.screen === key;
      tab.setAttribute('aria-selected', String(selected));
      tab.tabIndex = selected ? 0 : -1;
      if (selected && focus) tab.focus();
    });
    all('[data-screen-panel]').forEach(panel => { panel.hidden = panel.dataset.screenPanel !== key; });
    one('#screen-caption-title').textContent = screenCopy[key][0];
    one('#screen-caption-copy').textContent = screenCopy[key][1];
    one('#screen-count').textContent = screenCopy[key][2];
  }
  screenTabs.forEach((tab, index) => {
    tab.addEventListener('click', () => selectScreen(tab.dataset.screen));
    tab.addEventListener('keydown', e => {
      if (!['ArrowRight', 'ArrowLeft', 'Home', 'End'].includes(e.key)) return;
      e.preventDefault();
      let next = e.key === 'Home' ? 0 : e.key === 'End' ? screenTabs.length - 1 : (index + (e.key === 'ArrowRight' ? 1 : -1) + screenTabs.length) % screenTabs.length;
      selectScreen(screenTabs[next].dataset.screen, true);
    });
  });

  const shots = [
    { src: 'assets/screenshot-tools.png', title: '工具工作台', caption: '锐途办公大师 1.9.0 · 工具模式实际截图', alt: '锐途办公大师工具首页与侧边栏' },
    { src: 'assets/screenshot-rito.png', title: 'Rito AI', caption: '锐途办公大师 1.9.0 · AI 模式实际截图', alt: 'Rito AI 欢迎页、聊天侧边栏和输入框' },
    { src: 'assets/screenshot-collage-light.png', title: '拼图 · 浅色界面', caption: '实际拼图工具视图 · 使用测试图形展示', alt: '浅色拼图工具界面与实时预览' },
    { src: 'assets/screenshot-collage-dark.png', title: '拼图 · 深色界面', caption: '实际拼图工具视图 · 使用测试图形展示', alt: '深色拼图工具界面与实时预览' }
  ];
  const lightbox = one('#screenshot-dialog');
  let shotIndex = 0;
  function showShot(index) {
    shotIndex = (index + shots.length) % shots.length;
    const shot = shots[shotIndex];
    one('#lightbox-image').src = shot.src;
    one('#lightbox-image').alt = shot.alt;
    one('#screenshot-title').textContent = shot.title;
    one('#lightbox-caption').textContent = shot.caption;
    one('#screenshot-position').textContent = `${String(shotIndex + 1).padStart(2, '0')} / 04`;
  }
  all('[data-gallery-open]').forEach(button => button.addEventListener('click', () => {
    showShot(Number(button.dataset.galleryOpen));
    lightbox.showModal();
    one('#close-screenshot').focus();
  }));
  one('#close-screenshot').addEventListener('click', () => lightbox.close());
  one('#previous-screenshot').addEventListener('click', () => showShot(shotIndex - 1));
  one('#next-screenshot').addEventListener('click', () => showShot(shotIndex + 1));
  lightbox.addEventListener('keydown', e => {
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      e.preventDefault();
      showShot(shotIndex + (e.key === 'ArrowRight' ? 1 : -1));
    }
  });
  lightbox.addEventListener('click', e => {
    if (e.target !== lightbox) return;
    const rect = lightbox.getBoundingClientRect();
    if (e.clientX < rect.left || e.clientX > rect.right || e.clientY < rect.top || e.clientY > rect.bottom) lightbox.close();
  });
  all('[data-gallery-theme]').forEach(button => button.addEventListener('click', () => {
    const dark = button.dataset.galleryTheme === 'dark';
    const shot = shots[dark ? 3 : 2];
    one('#collage-screenshot').src = shot.src;
    one('#collage-screenshot').alt = shot.alt;
    one('#collage-zoom').dataset.galleryOpen = String(dark ? 3 : 2);
    all('[data-gallery-theme]').forEach(b => b.setAttribute('aria-pressed', String(b === button)));
  }));
})();
