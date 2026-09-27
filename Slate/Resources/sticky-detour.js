// 고정 탭의 페이지 안 층. 링크 클릭은 JS 라우터보다 먼저(capture) 가로채 새 탭으로 돌리고,
// 라우터가 pushState로 제자리에서 다른 페이지로 넘어가려 하면 새 탭을 열고 이 문서는 되돌린다.
// 네이티브 이동 정책은 pushState를 못 보므로 이 둘은 여기서 잡는다. location 변경으로 옮기는
// 이동은 네이티브가 잡는다. 쪽 넘김(숫자만 다른 경로·같은 경로의 쿼리/# 변화)은 통과.
(function () {
  'use strict';
  if (window.__slateStickyDetourInstalled) { return; }
  window.__slateStickyDetourInstalled = true;

  function maskDigits(path) {
    return path.replace(/[0-9]+/g, '#');
  }

  // 경로 끝의 쪽 번호 꼬리(/page/2/, /page-2, /paged/3). 1쪽은 꼬리가 없고 2쪽부터 붙는
  // 목록이 많아, 꼬리를 떼고 견주지 않으면 1쪽→2쪽이 딴 페이지로 보인다.
  var PAGE_SUFFIX = /\/paged?[-_\/]?[0-9]+\/?$/i;

  function hasPageMarker(url) {
    if (PAGE_SUFFIX.test(url.pathname)) { return true; }
    return /(^|&)paged?=[0-9]+(&|$)/i.test(url.search.slice(1));
  }

  function listShape(path) {
    return maskDigits(path.replace(PAGE_SUFFIX, '').replace(/\/+$/, ''));
  }

  function isPaginationMove(from, to) {
    if (from.host !== to.host) { return false; }
    if (from.pathname === to.pathname) { return true; }
    if (hasPageMarker(to)) { return true; }
    return listShape(from.pathname) === listShape(to.pathname);
  }

  // 고정이 켜져 있고 raw가 다른 페이지 모양의 웹 주소면 그 URL, 아니면 null.
  function detourTarget(raw) {
    if (!window.__slateSticky) { return null; }
    var target;
    try { target = new URL(String(raw), location.href); } catch (e) { return null; }
    if (target.protocol !== 'http:' && target.protocol !== 'https:') { return null; }
    if (isPaginationMove(location, target)) { return null; }
    return target;
  }

  function openInNewTab(href) {
    try {
      window.webkit.messageHandlers.slateStickyOpen.postMessage(href);
    } catch (e) {}
  }

  document.addEventListener('click', function (event) {
    if (event.button !== 0) { return; }
    var anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
    if (!anchor) { return; }
    var target = detourTarget(anchor.href);
    if (!target) { return; }
    event.preventDefault();
    event.stopImmediatePropagation();
    openInNewTab(target.href);
  }, true);

  // SPA 라우터의 제자리 이동. 주소 변경은 삼키고 새 탭을 연다. 라우터가 이미 바꾸기 시작한
  // 화면은 한 틱 뒤 popstate를 받아 지금 주소(원래 페이지)대로 되살린다. 뒤로가기 목록에는
  // 아무것도 남지 않는다.
  var originalPushState = history.pushState;
  history.pushState = function (state, title, url) {
    var target = url == null ? null : detourTarget(url);
    if (!target) { return originalPushState.apply(this, arguments); }
    openInNewTab(target.href);
    var previousState = history.state;
    setTimeout(function () {
      window.dispatchEvent(new PopStateEvent('popstate', { state: previousState }));
    }, 0);
    return undefined;
  };
})();
