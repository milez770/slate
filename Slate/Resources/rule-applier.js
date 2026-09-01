// slateRuleApplier: 저장된 사이트별 규칙을 적용한다. 동적 삽입은 관찰자가 다시 잡는다.
(function () {
  if (window.__slateRuleApplier) return;
  window.__slateRuleApplier = true;
  window.__slateRules = [];

  // 제거 대신 화면에서만 죽인다. ad-cloak이 먼저 주입돼 window.__slateKill을 깐다 —
  // 요소를 DOM에 남기고 크기 조회를 원래 값으로 속여 anti-adblock 감지를 통과시킨다.
  function kill(el) {
    if (window.__slateKill) window.__slateKill(el);
    else el.remove();
  }

  function applySelector(value) {
    var found;
    try {
      found = document.querySelectorAll(value);
    } catch (e) {
      return;
    }
    for (var i = 0; i < found.length; i++) kill(found[i]);
  }

  // 이미지를 감싼 가장 가까운 a/button의 넓이가 이미지 넓이의 이 배수를 넘으면 조상 대신
  // 이미지만 지운다. 광고 이미지는 보통 자기 링크/버튼에 딱 맞게 감싸이므로 8배를 넘는 조상은
  // 광고 하나가 본문 카드·목록 항목 전체를 감싼 경우로 본다.
  var WRAPPER_AREA_MULTIPLE = 8;

  function removalTarget(img) {
    var wrapper = img.closest("a, button");
    if (!wrapper) return img;
    var imgRect = img.getBoundingClientRect();
    var wrapperRect = wrapper.getBoundingClientRect();
    var imgArea = imgRect.width * imgRect.height;
    var wrapperArea = wrapperRect.width * wrapperRect.height;
    if (imgArea > 0 && wrapperArea > imgArea * WRAPPER_AREA_MULTIPLE) return img;
    return wrapper;
  }

  function applyImagePrefix(prefix) {
    var images = document.querySelectorAll("img");
    for (var i = 0; i < images.length; i++) {
      var src = images[i].src || "";
      var stripped = src.replace(/^https?:\/\//, "");
      if (stripped.indexOf(prefix) !== 0) continue;
      kill(removalTarget(images[i]));
    }
  }

  function apply() {
    var rules = window.__slateRules || [];
    for (var i = 0; i < rules.length; i++) {
      if (rules[i].kind === "selector") applySelector(rules[i].value);
      else if (rules[i].kind === "imgSrcPrefix") applyImagePrefix(rules[i].value);
    }
  }

  window.__slateSetRules = function (rules) {
    window.__slateRules = rules || [];
    apply();
  };

  var queued = false;
  new MutationObserver(function (records) {
    if (queued || !window.__slateRules.length) return;
    for (var i = 0; i < records.length; i++) {
      if (!records[i].addedNodes.length) continue;
      queued = true;
      requestAnimationFrame(function () {
        queued = false;
        apply();
      });
      return;
    }
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
