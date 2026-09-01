// 붙박이 탭: 링크 클릭을 JS 라우터보다 먼저(capture) 가로챈다. 네이티브의
// decidePolicyFor는 라우터가 pushState로 움직이면 아예 못 보므로, 여기서 잡아
// 새 탭으로 돌린다. 쪽 넘김(숫자만 다른 경로·같은 경로의 쿼리/# 변화)은 통과.
(function () {
  'use strict';
  if (window.__slateStickyDetourInstalled) { return; }
  window.__slateStickyDetourInstalled = true;

  function maskDigits(path) {
    return path.replace(/[0-9]+/g, '#');
  }

  function isPaginationMove(from, to) {
    if (from.host !== to.host) { return false; }
    if (from.pathname === to.pathname) { return true; }
    return maskDigits(from.pathname) === maskDigits(to.pathname);
  }

  document.addEventListener('click', function (event) {
    if (!window.__slateSticky) { return; }
    if (event.button !== 0) { return; }
    var anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
    if (!anchor) { return; }
    var target;
    try { target = new URL(anchor.href, location.href); } catch (e) { return; }
    if (target.protocol !== 'http:' && target.protocol !== 'https:') { return; }
    if (isPaginationMove(location, target)) { return; }
    event.preventDefault();
    event.stopImmediatePropagation();
    try {
      window.webkit.messageHandlers.slateStickyOpen.postMessage(target.href);
    } catch (e) {}
  }, true);
})();
