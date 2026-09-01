// slateOverlayBuster: 전면 투명 오버레이·터치 하이재킹 제거
(function () {
  if (window.__slateOverlayBuster) return;
  window.__slateOverlayBuster = true;

  function isHijackOverlay(el) {
    if (!(el instanceof Element)) return false;
    const s = getComputedStyle(el);
    if (s.position !== "fixed" && s.position !== "absolute") return false;
    if (s.pointerEvents === "none") return false;
    const r = el.getBoundingClientRect();
    if (r.width < innerWidth * 0.85 || r.height < innerHeight * 0.85) return false;
    const z = parseInt(s.zIndex, 10) || 0;
    if (z < 500) return false;
    const noContent = !el.textContent.trim() && !el.querySelector("img,video,iframe,svg,canvas");
    const transparent = (parseFloat(s.opacity) < 0.05 || s.backgroundColor === "rgba(0, 0, 0, 0)") && noContent;
    return transparent;
  }

  // 여기서는 ad-cloak의 덮개를 쓰지 않는다 — 대상이 화면 전체를 덮는 투명 층이라 덮개를
  // 씌우면 페이지 전체가 불투명하게 가려진다. 이 층은 광고 슬롯 카운트 대상도 아니다.
  function kill(el) {
    el.remove();
  }

  function sweep(root) {
    for (const el of root.querySelectorAll("body *")) {
      if (isHijackOverlay(el)) kill(el);
    }
  }

  // 첫 터치를 새 창 열기로 가로채는 수법 무력화: 오버레이 위 클릭이면 삼킨다
  document.addEventListener("click", function (e) {
    if (isHijackOverlay(e.target)) {
      e.stopImmediatePropagation();
      e.preventDefault();
      kill(e.target);
    }
  }, true);

  let queued = false;
  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(function () { queued = false; sweep(document); });
  }

  sweep(document);
  new MutationObserver(function (records) {
    for (const r of records) if (r.addedNodes.length) { schedule(); return; }
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
