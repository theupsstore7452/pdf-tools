// Elm owns application state; JavaScript only mounts it and connects resources.
export function start(connect) {
  const node = document.getElementById('app');
  if (!node) throw new Error('Elm mount element missing: app');
  if (typeof globalThis.Elm?.Main?.init !== 'function') {
    throw new Error('Elm module missing: Main');
  }
  const app = globalThis.Elm.Main.init({
    node,
    flags: document.documentElement.dataset.theme === 'light' ? 'light' : 'dark'
  });
  if (typeof app?.ports?.resources?.subscribe !== 'function' ||
      typeof app?.ports?.browserEvents?.send !== 'function') {
    throw new Error('Elm must use resources and browserEvents ports');
  }
  connect(app);
}
