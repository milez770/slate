// slateAdCloak: 광고를 지우거나 숨김 스타일을 주지 않고, 광고만 담고 있는 상위 컨테이너를
// 높이 0으로 접어 화면에서 치운다.
//
// 광고 요소 자신은 손대지 않는다. 크기·투명도·클릭 가능 여부가 전부 진짜 정상이라
// anti-adblock의 가시성 검사에 걸릴 것이 없다(요소 자신의 박스는 조상 overflow에 잘리지
// 않는다). 요소를 숨기거나 브라우저 API를 후킹하는 방식은 "우회 스크립트"로 탐지된다 —
// 실측 마크업 기준.
//
// 접을 컨테이너를 못 찾으면(광고가 본문과 섞여 있으면) 그 광고는 불투명 덮개로 가린다.
//
// 다른 스크립트(rule-applier·banner-sweeper)가 window.__slateKill로 호출한다.
(function () {
  if (window.__slateKill) return;

  var killed = new Set();          // 죽이기로 지목된 광고 요소
  var collapsed = new Set();       // 접은 컨테이너
  var covered = new WeakSet();     // 덮개를 씌운 광고
  var noCollapse = new WeakSet();  // 콘텐츠가 들어와 접기를 푼 묶음
  var queued = false;

  window.__slateKill = function (el) {
    if (!(el instanceof Element) || killed.has(el)) return;
    killed.add(el);
    schedule();
  };

  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(function () {
      queued = false;
      apply();
    });
  }

  // 이 요소 아래에 광고 말고 다른 내용이 있는지. 죽인 광고와 빈 껍데기만 있으면 광고 전용이다.
  function adOnly(node) {
    if (killed.has(node)) return true;
    if (node.nodeType === 3) return !node.textContent.trim();
    if (node.nodeType !== 1) return true;
    // 화면에 안 그려지는 요소는 있으나 마나다.
    if (/^(SCRIPT|STYLE|LINK|META|NOSCRIPT|TEMPLATE|HEAD)$/.test(node.tagName)) return true;
    if (/^(IMG|VIDEO|IFRAME|CANVAS|INPUT|TEXTAREA|SELECT)$/.test(node.tagName)) return false;
    for (var i = 0; i < node.childNodes.length; i++) {
      if (!adOnly(node.childNodes[i])) return false;
    }
    return true;
  }

  // 지금 비어 있어도 자리를 차지하는 칸은 나중에 콘텐츠가 채워질 자리다. 후보의 면적이
  // 그 안의 광고 면적 합보다 이 배수 넘게 크면 광고 전용으로 보지 않는다.
  var AREA_SLACK = 1.5;

  function area(el) {
    var r = el.getBoundingClientRect();
    return r.width * r.height;
  }

  function adAreaIn(node) {
    var sum = 0;
    killed.forEach(function (ad) {
      if (ad.isConnected && node.contains(ad)) sum += area(ad);
    });
    return sum;
  }

  // 광고만 담은 가장 바깥 조상. 없으면 null.
  function adBlockOf(el) {
    var best = null;
    var node = el.parentElement;
    while (node && node !== document.body && node !== document.documentElement) {
      if (!adOnly(node)) break;
      // 광고가 채우고 있지 않은 여백이 크면 그 안에 나중에 채워질 자리가 있다고 본다.
      var boxArea = area(node);
      if (boxArea > 0 && boxArea > adAreaIn(node) * AREA_SLACK) break;
      best = node;
      node = node.parentElement;
    }
    return best;
  }

  // 광고 묶음을 높이 0짜리 새 래퍼로 감싼다. 묶음 자체의 스타일은 건드리지 않는다 —
  // 컨테이너에 직접 높이 0을 주면 그 안의 자식들이 같이 눌려(flex stretch 등) 광고 크기가
  // 0이 되고 사이트가 숨겨졌다고 본다. 래퍼는 사이트 DOM에 없던 요소라 스캐너의 조상 검사
  // 경로 밖이고, 안에 든 묶음은 자연 높이로 그대로 남아 넘친 채 잘린다.
  function collapse(box) {
    if (collapsed.has(box) || noCollapse.has(box) || !box.parentNode) return;
    var wrap = document.createElement("div");
    wrap.setAttribute("data-slate-collapse", "1");
    wrap.style.cssText =
      "height:0!important;min-height:0!important;max-height:0!important;" +
      "overflow:hidden!important;margin:0!important;padding:0!important;border:0!important";
    box.parentNode.insertBefore(wrap, box);
    wrap.appendChild(box);
    collapsed.add(box);
    watch(box);
  }

  // 접은 뒤에 광고가 아닌 내용이 들어오면(지연 로딩·나중에 보이게 되는 자리) 접기를 풀고
  // 그 묶음은 다시 접지 않는다. 광고는 각각 덮개로 가린다.
  function watch(box) {
    var observer = new MutationObserver(function () {
      if (adOnly(box)) return;
      observer.disconnect();
      uncollapse(box);
      noCollapse.add(box);
      schedule();
    });
    observer.observe(box, { childList: true, subtree: true, characterData: true });
  }

  function uncollapse(box) {
    var wrap = box.parentElement;
    if (wrap && wrap.getAttribute("data-slate-collapse") === "1" && wrap.parentNode) {
      wrap.parentNode.insertBefore(box, wrap);
      wrap.remove();
    }
    collapsed.delete(box);
  }


  // 광고 묶음을 접을 수 없을 때 쓰는 대비책. 광고를 그대로 두고 위에 불투명 덮개만 덮는다.
  function cover(el) {
    if (covered.has(el)) return;
    var r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return;
    covered.add(el);
    if (getComputedStyle(el).position === "static") el.style.setProperty("position", "relative");
    var c = document.createElement("div");
    c.setAttribute("data-slate-cover", "1");
    c.style.cssText = "position:absolute;inset:0;z-index:2147483000;background:" + backdrop(el);
    c.addEventListener("click", function (e) { e.stopPropagation(); e.preventDefault(); }, true);
    el.appendChild(c);
  }

  function backdrop(el) {
    var node = el;
    while (node && node !== document.documentElement) {
      var bg = getComputedStyle(node).backgroundColor;
      if (bg && !/rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\)/.test(bg) && bg !== "transparent") return bg;
      node = node.parentElement;
    }
    return matchMedia("(prefers-color-scheme: dark)").matches ? "#000" : "#fff";
  }

  function apply() {
    killed.forEach(function (el) {
      if (!el.isConnected) return;
      // 이미 접힌 묶음 안이면 더 할 일이 없다.
      if (el.closest("[data-slate-collapse]")) return;
      var box = adBlockOf(el);
      if (box) { collapse(box); return; }
      // 접을 묶음이 없다 — 광고가 본문과 섞여 있으면 덮개로 가린다.
      cover(el);
    });
  }


  // 사이트가 다시 그리면 접기가 풀린다 — 다시 건다.
  new MutationObserver(function () {
    if (killed.size) schedule();
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
