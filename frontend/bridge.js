/* Browser-owned resources only. Workflow decisions, validation, forms, HTTP
   jobs, and production geometry belong to Elm/Rust. No secure-context APIs. */
export function connect(app) {
  const send = event => app.ports.browserEvents.send(event);
  let workspaceFrame, workspaceAnimations = [];
  const stopWorkspaceTransition = () => {
    cancelAnimationFrame(workspaceFrame);
    workspaceAnimations.forEach(animation => animation.cancel());
    workspaceAnimations = [];
    const shell = document.querySelector('.elm-shell');
    shell?.removeAttribute('data-workspace-animating');
    shell?.style.removeProperty('--workspace-rows');
  };
  const animateWorkspace = () => {
    const shell = document.querySelector('.elm-shell');
    if (!shell) return;
    // Capture the current visual bounds before Elm renders the new workflow.
    // This also lets a reversed transition continue from its current position.
    const frames = ['.app-header', '.ready-shell', '.ready-card'].map(selector => {
      const element = shell.querySelector(selector);
      return element && {element, bounds:element.getBoundingClientRect(), radius:getComputedStyle(element).borderRadius};
    }).filter(Boolean);
    stopWorkspaceTransition();
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    workspaceFrame = requestAnimationFrame(() => {
      if (!shell.isConnected || shell.classList.contains('empty-shell')) return;
      const style = getComputedStyle(shell);
      const options = {duration:parseFloat(style.getPropertyValue('--workspace-duration')), easing:style.getPropertyValue('--workspace-easing').trim()};
      // Keep the grid's final positions fixed while the child frames resize;
      // centering must not shift a second time during the return animation.
      shell.style.setProperty('--workspace-rows', style.gridTemplateRows);
      shell.setAttribute('data-workspace-animating', '');
      const targets = frames.filter(frame => frame.element.isConnected).map(frame => ({...frame, next:frame.element.getBoundingClientRect(), nextRadius:getComputedStyle(frame.element).borderRadius}));
      workspaceAnimations = targets.map(({element, bounds, radius, next, nextRadius}) => {
        const shape = {borderRadius:radius, height:`${bounds.height}px`};
        const settled = {borderRadius:nextRadius, height:`${next.height}px`};
        if (!element.matches('.ready-card')) {
          Object.assign(shape, {width:`${bounds.width}px`, transform:`translate(${bounds.x-next.x}px, ${bounds.y-next.y}px)`});
          Object.assign(settled, {width:`${next.width}px`, transform:'translate(0, 0)'});
        }
        return element.animate([shape, settled], options);
      });
      const current = workspaceAnimations;
      Promise.allSettled(current.map(animation => animation.finished)).then(() => {
        if (workspaceAnimations === current) stopWorkspaceTransition();
      });
    });
  };
  window.addEventListener('resize', stopWorkspaceTransition);
  matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', stopWorkspaceTransition);
  const cache = new Map();
  let protectedUrls = new Set(), previewController, downloadController, activeSource, restoreFocus, identity = 0;
  let cacheBytes = 0;
  const revoke = key => {
    const asset = cache.get(key);
    URL.revokeObjectURL(asset.url);
    cacheBytes -= asset.bytes;
    cache.delete(key);
  };
  const evict = () => {
    for (const [key, asset] of cache) {
      if (cache.size <= 32 && cacheBytes <= 128 * 1024 * 1024) break;
      if (!protectedUrls.has(asset.url)) revoke(key);
    }
  };
  const clear = () => {
    previewController?.abort();
    protectedUrls.clear();
    for (const key of [...cache.keys()]) revoke(key);
  };
  const delay = (ms, signal) => new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener('abort', () => { clearTimeout(timer); reject(new DOMException('Cancelled', 'AbortError')); }, {once:true});
  });
  async function batch(source, pages, bleed, signal) {
    let failure;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const response = await fetch(`gang-up/sources/${encodeURIComponent(source)}/previews`, {
          method:'POST', headers:{'Content-Type':'application/json'}, signal,
          body:JSON.stringify({pageNumbers:pages, sourceBleedOverride:bleed})
        });
        if (!response.ok) {
          const message = await response.text();
          const error = new Error(message || `Preview failed (${response.status}).`);
          error.permanent = response.status < 500 && response.status !== 429;
          throw error;
        }
        const buffer = await response.arrayBuffer();
        const bytes = new Uint8Array(buffer), view = new DataView(buffer);
        if (buffer.byteLength < 12 || new TextDecoder().decode(bytes.slice(0,8)) !== 'PDFPV001' || view.getUint32(8) !== pages.length) throw new Error('Invalid preview batch header.');
        const assets = [], seen = new Set();
        let offset = 12;
        for (let i = 0; i < pages.length; i++) {
          if (offset + 8 > bytes.length) throw new Error('Truncated preview header.');
          const page = view.getUint32(offset), length = view.getUint32(offset + 4);
          offset += 8;
          if (!pages.includes(page) || seen.has(page) || length < 8 || offset + length > bytes.length) throw new Error('Invalid preview page.');
          const png = bytes.slice(offset, offset + length);
          if (![137,80,78,71,13,10,26,10].every((n,j) => png[j] === n)) throw new Error('Invalid preview PNG.');
          assets.push({page, png}); seen.add(page); offset += length;
        }
        if (offset !== bytes.length) throw new Error('Unexpected preview bytes.');
        return assets;
      } catch (error) {
        if (signal.aborted || error.permanent) throw error;
        failure = error;
        if (attempt < 2) await delay(150 * (attempt + 1), signal);
      }
    }
    throw failure;
  }
  async function preview(command) {
    previewController?.abort();
    const controller = new AbortController();
    previewController = controller;
    const {token, source, pages, bleed} = command;
    const keyFor = page => `${source}:${bleed ?? 'default'}:${page}`;
    try {
      const missing = pages.filter(page => !cache.has(keyFor(page)));
      // One scheduler per workspace, one request in flight, four pages maximum.
      for (let i = 0; i < missing.length; i += 4) {
        const assets = await batch(source, missing.slice(i,i+4), bleed, controller.signal);
        if (controller.signal.aborted) return;
        for (const {page,png} of assets) {
          const key = keyFor(page), asset = {url:URL.createObjectURL(new Blob([png], {type:'image/png'})), bytes:png.length};
          if (cache.has(key)) revoke(key);
          cache.set(key,asset); cacheBytes += png.length;
        }
      }
      if (controller.signal.aborted) return;
      const urls = pages.map(page => ({page, url:cache.get(keyFor(page)).url}));
      for (const page of pages) { const key = keyFor(page), asset = cache.get(key); cache.delete(key); cache.set(key,asset); }
      send({action:'preview',token,urls});
    } catch(error) {
      if (!controller.signal.aborted) send({action:'previewError',token,message:error.message});
      evict();
    }
  }
  async function download({url,filename,token}) {
    downloadController?.abort();
    const controller = new AbortController();
    downloadController = controller;
    try {
      const response = await fetch(url,{signal:controller.signal});
      if (!response.ok) throw new Error(await response.text());
      const blob = await response.blob();
      if (controller.signal.aborted || token !== identity) return;
      const objectUrl = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = objectUrl; link.download = filename; document.body.append(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(objectUrl), 60000);
      send({action:'downloadDone',token,filename});
      if (/^jobs\/[^/]+\/download$/.test(url)) void fetch(url.replace('/download',''), {method:'DELETE'}).catch(() => {});
    } catch(error) { if (!controller.signal.aborted && token === identity) send({action:'downloadError',token,message:error.message || 'Download failed. Retry.'}); }
  }
  app.ports.resources.subscribe(command => {
    switch(command.action) {
      case 'workspaceTransition': animateWorkspace(); break;
      case 'identity': identity = command.token; downloadController?.abort(); break;
      case 'preview': void preview(command); break;
      case 'cancelPreview': previewController?.abort(); break;
      case 'commitPreview':
        protectedUrls = new Set(command.urls);
        for (const [key,asset] of cache) if (!key.startsWith(command.source+':') && !protectedUrls.has(asset.url)) revoke(key);
        evict(); break;
      case 'clearPreviews': clear(); activeSource = undefined; break;
      case 'source': activeSource = command.id; break;
      case 'download': void download(command); break;
      case 'theme':
        document.documentElement.dataset.theme = command.value;
        try { localStorage.setItem('pdf-tools-theme',command.value); } catch (_) {}
        break;
      case 'focus': requestAnimationFrame(() => document.getElementById(command.id)?.focus()); break;
      case 'dialog':
        restoreFocus = document.activeElement;
        requestAnimationFrame(() => {
          const dialog = document.getElementById(command.id);
          dialog?.showModal();
          dialog?.querySelector('input, button')?.focus();
        });
        break;
      case 'closeDialog':
        document.getElementById('workspace-dialog')?.close();
        requestAnimationFrame(() => restoreFocus?.isConnected && restoreFocus.focus());
        break;
    }
  });
  const visible = () => { if (document.visibilityState === 'visible') send({action:'visible'}); };
  document.addEventListener('visibilitychange',visible);
  const fitPopover = details => {
    const panel = details?.matches?.('.elm-toolbar details[open]') && details.querySelector(':scope > fieldset');
    if (panel) {
      const left=details.getBoundingClientRect().left;
      panel.style.right='auto';
      panel.style.left=`${Math.max(8,Math.min(left,innerWidth-panel.offsetWidth-8))-left}px`;
      panel.style.maxHeight = `${Math.max(80,Math.min(580,innerHeight-panel.getBoundingClientRect().top-12))}px`;
    }
  };
  document.addEventListener('toggle',event => requestAnimationFrame(() => fitPopover(event.target)),true);
  window.addEventListener('resize',() => document.querySelectorAll('.elm-toolbar details[open]').forEach(fitPopover));
  // FileList is not a JSON array; keep File objects native and adapt only the
  // browser event payload for Elm's File.decoder.
  document.addEventListener('drop',event => {
    const files = Array.from(event.dataTransfer?.files || []);
    if (!files.length) return;
    event.preventDefault(); event.stopPropagation();
    document.querySelector('.elm-shell')?.dispatchEvent(new CustomEvent('elm-files',{detail:files,bubbles:true}));
  },true);
  let drag;
  document.addEventListener('pointerdown',event => {
    const editor = event.target.closest('.elm-crop-editor');
    if (!editor || editor.closest('fieldset')?.disabled) return;
    const bounds = editor.getBoundingClientRect();
    drag = {editor, x:event.clientX, y:event.clientY, bounds, px:Number(editor.dataset.cropX), py:Number(editor.dataset.cropY), tx:Number(editor.dataset.travelX), ty:Number(editor.dataset.travelY), w:Number(editor.dataset.cutWidth), h:Number(editor.dataset.cutHeight)};
    editor.setPointerCapture(event.pointerId); event.preventDefault();
  });
  document.addEventListener('pointermove',event => {
    if (!drag) return;
    const d = drag;
    const scale = Math.min(d.bounds.width / d.w,d.bounds.height / d.h);
    const x = Math.abs(d.tx) > .001 ? Math.min(1,Math.max(0,d.px + (event.clientX - d.x) / scale / d.tx)) : d.px;
    const y = Math.abs(d.ty) > .001 ? Math.min(1,Math.max(0,d.py + (event.clientY - d.y) / scale / d.ty)) : d.py;
    send({action:'crop',x,y});
  });
  document.addEventListener('pointerup',() => { drag = undefined; });
  document.addEventListener('pointercancel',() => { drag = undefined; });
  window.addEventListener('pagehide',() => {
    downloadController?.abort();
    clear();
    if (activeSource) void fetch(`gang-up/sources/${encodeURIComponent(activeSource)}`,{method:'DELETE',keepalive:true});
  });
}
