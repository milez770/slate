// slateEdgeSwipeGuard: 화면 왼쪽·오른쪽 끝에서 시작한 손가락 동작은 페이지 스크립트에 넘기지 않는다.
// 그 동작은 브라우저의 뒤로·앞으로 가기다. 가로 밀기를 직접 받아 이전화·다음화로 넘기는 페이지는 그 이동을
// 새 기록으로 쌓아서, 끝에서 밀어 뒤로 가려 할수록 기록이 늘고 앞 페이지에 닿지 못한다.
// 전파만 막고 기본 동작은 그대로라 끝 근처를 누르는 것은 그대로 클릭이 된다.
(function () {
  if (window.__slateEdgeSwipeGuard) return;
  window.__slateEdgeSwipeGuard = true;

  var EDGE = 24;
  var touching = false;
  var pointers = {};

  function atEdge(x) {
    return typeof x === "number" && (x <= EDGE || x >= window.innerWidth - EDGE);
  }

  window.addEventListener("touchstart", function (e) {
    var t = e.touches;
    touching = !!t && t.length === 1 && atEdge(t[0].clientX);
    if (touching) e.stopImmediatePropagation();
  }, { capture: true, passive: true });

  ["touchmove", "touchend", "touchcancel"].forEach(function (type) {
    window.addEventListener(type, function (e) {
      if (!touching) return;
      e.stopImmediatePropagation();
      if (type !== "touchmove" && (!e.touches || e.touches.length === 0)) touching = false;
    }, { capture: true, passive: true });
  });

  window.addEventListener("pointerdown", function (e) {
    if (e.pointerType !== "touch" || !atEdge(e.clientX)) return;
    pointers[e.pointerId] = true;
    e.stopImmediatePropagation();
  }, true);

  ["pointermove", "pointerup", "pointercancel"].forEach(function (type) {
    window.addEventListener(type, function (e) {
      if (!pointers[e.pointerId]) return;
      e.stopImmediatePropagation();
      if (type !== "pointermove") delete pointers[e.pointerId];
    }, true);
  });
})();
