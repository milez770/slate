// slateBannerSweeper: 1차 파티 이미지 배너 제거. 다섯 조건을 모두 만족할 때만 지운다.
(function () {
  if (window.__slateBannerSweeper) return;
  window.__slateBannerSweeper = true;

  var MIN_WIDTH = 200;
  var MIN_RATIO = 2.5;
  var CANDIDATE_SELECTOR = 'a[href], button, [onclick], [role="link"]';

  function hostOf(value, base) {
    try {
      return new URL(value, base || location.href).hostname;
    } catch (e) {
      return "";
    }
  }

  // 조건 1: 클릭하면 현재 호스트 밖으로 나간다
  function goesOutside(el) {
    if (el.tagName === "A") {
      var href = el.getAttribute("href") || "";
      var host = hostOf(href);
      if (host && host !== location.hostname) return true;
    }
    var attrs = el.attributes;
    for (var i = 0; i < attrs.length; i++) {
      var value = attrs[i].value || "";
      if (value.indexOf("http://") !== 0 && value.indexOf("https://") !== 0) continue;
      var target = hostOf(value);
      if (target && target !== location.hostname) return true;
    }
    return false;
  }

  // 조건 3: 이미지 한 장짜리. 크기 측정 대상(이미지 자신 또는 후보 엘리먼트)을 함께 반환
  function sizeSource(el) {
    var images = el.querySelectorAll("img");
    if (images.length === 1) return images[0];
    if (images.length > 1) return null;
    var background = getComputedStyle(el).backgroundImage;
    if (background && background !== "none") return el;
    return null;
  }

  function isBanner(el) {
    if (el.textContent.trim() !== "") return false;      // 조건 2
    var source = sizeSource(el);                         // 조건 3
    if (!source) return false;
    // 배너의 규격은 감싼 엘리먼트의 여백이 아니라 이미지 자체의 규격이다.
    // display:inline인 a는 자식 img의 높이를 라인박스에 반영하지 않는 반면
    // button은 반영하는 등, 후보 엘리먼트 자신의 rect는 태그에 따라 값이
    // 달라져 신뢰할 수 없다 — 이미지 자체를 재면 래퍼 태그와 무관하게 같다.
    var rect = source.getBoundingClientRect();            // 조건 4
    if (rect.width < MIN_WIDTH) return false;
    if (rect.height <= 0) return false;
    if (rect.width / rect.height < MIN_RATIO) return false;
    return goesOutside(el);                              // 조건 1
  }

  // 조건 5: 같은 부모 밑에 둘 이상 나란히 있을 때만 제거
  function sweep() {
    var candidates = document.querySelectorAll(CANDIDATE_SELECTOR);
    var groups = new Map();
    for (var i = 0; i < candidates.length; i++) {
      var el = candidates[i];
      if (!isBanner(el)) continue;
      var parent = el.parentElement;
      if (!parent) continue;
      if (!groups.has(parent)) groups.set(parent, []);
      groups.get(parent).push(el);
    }
    groups.forEach(function (group) {
      if (group.length < 2) return;
      // 제거 대신 화면에서만 죽인다 — ad-cloak의 window.__slateKill이 요소를 DOM에 남기고
      // 크기 조회를 속여 anti-adblock 감지를 통과시킨다.
      for (var i = 0; i < group.length; i++) {
        if (window.__slateKill) window.__slateKill(group[i]);
        else group[i].remove();
      }
    });
  }

  var queued = false;
  function schedule() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(function () {
      queued = false;
      sweep();
    });
  }

  sweep();
  window.addEventListener("load", sweep);   // 지연 로딩 이미지가 크기를 얻은 뒤 한 번 더
  new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      if (records[i].addedNodes.length) {
        schedule();
        return;
      }
    }
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
