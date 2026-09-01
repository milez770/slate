// slateAreaPicker: 지정한 사각형에 대부분 겹치는 최상위 요소를 제거하고 재사용할 규칙을 돌려준다.
(function () {
  var MIN_COVERAGE = 0.6;     // 요소 면적 중 사각형 안에 든 비율이 이 이상이면 잡는다
  var MAX_AREA_MULTIPLE = 2.5; // 사각형보다 이 배수 넘게 큰 요소는 본문 래퍼로 보고 제외
  var BROAD_MATCH_LIMIT = 30; // 이보다 많이 잡히면 너무 넓은 규칙으로 본다

  function insideArea(el, area) {
    if (el === document.body || el === document.documentElement) return false;
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var left = r.left + window.scrollX;
    var top = r.top + window.scrollY;
    var right = r.right + window.scrollX;
    var bottom = r.bottom + window.scrollY;
    var overlapW = Math.min(right, area.x + area.w) - Math.max(left, area.x);
    var overlapH = Math.min(bottom, area.y + area.h) - Math.max(top, area.y);
    if (overlapW <= 0 || overlapH <= 0) return false;
    var elArea = r.width * r.height;
    if (elArea > area.w * area.h * MAX_AREA_MULTIPLE) return false;
    return (overlapW * overlapH) / elArea >= MIN_COVERAGE;
  }

  function collect(area) {
    var all = document.body ? document.body.querySelectorAll("*") : [];
    var inside = [];
    for (var i = 0; i < all.length; i++) {
      if (insideArea(all[i], area)) inside.push(all[i]);
    }
    var set = new Set(inside);
    // 조상이 이미 대상이면 뺀다 — 가장 바깥 요소만 남긴다
    return inside.filter(function (el) {
      var parent = el.parentElement;
      while (parent) {
        if (set.has(parent)) return false;
        parent = parent.parentElement;
      }
      return true;
    });
  }

  function isHashLike(text) {
    var digits = text.match(/\d/g);
    return text.length >= 8 && digits && digits.length >= 3;
  }

  function attributeRule(el) {
    var attrs = el.attributes;
    for (var i = 0; i < attrs.length; i++) {
      var name = attrs[i].name;
      if (name.indexOf("data-") !== 0) continue;
      var value = attrs[i].value || "";
      if (value.indexOf("http://") === 0 || value.indexOf("https://") === 0) {
        return { kind: "selector", value: "[" + name + "]" };
      }
    }
    return null;
  }

  function idRule(el) {
    if (!el.id || isHashLike(el.id)) return null;
    return { kind: "selector", value: "#" + CSS.escape(el.id) };
  }

  function classRule(el) {
    var names = [];
    for (var i = 0; i < el.classList.length; i++) {
      var name = el.classList[i];
      if (!isHashLike(name)) names.push(CSS.escape(name));
    }
    if (!names.length) return null;
    return { kind: "selector", value: "." + names.join(".") };
  }

  function imageRule(el) {
    var img = el.tagName === "IMG" ? el : el.querySelector("img");
    if (!img || !img.src) return null;
    try {
      var url = new URL(img.src);
      var segments = url.pathname.split("/").filter(Boolean);
      if (!segments.length) return null;
      return { kind: "imgSrcPrefix", value: url.hostname + "/" + segments[0] + "/" };
    } catch (e) {
      return null;
    }
  }

  function pathRule(el) {
    var parts = [];
    var current = el;
    while (current && current !== document.body && current.parentElement) {
      var parent = current.parentElement;
      var index = Array.prototype.indexOf.call(parent.children, current) + 1;
      parts.unshift(current.tagName.toLowerCase() + ":nth-child(" + index + ")");
      current = parent;
    }
    return { kind: "selector", value: "body>" + parts.join(">") };
  }

  function countImagesWithPrefix(prefix) {
    var images = document.querySelectorAll("img");
    var count = 0;
    for (var i = 0; i < images.length; i++) {
      var src = images[i].src || "";
      var stripped = src.replace(/^https?:\/\//, "");
      if (stripped.indexOf(prefix) === 0) count++;
    }
    return count;
  }

  function tooBroad(rule, targetCount) {
    var matched;
    if (rule.kind === "selector") {
      try {
        matched = document.querySelectorAll(rule.value).length;
      } catch (e) {
        return true;
      }
    } else if (rule.kind === "imgSrcPrefix") {
      matched = countImagesWithPrefix(rule.value);
    } else {
      return false;
    }
    return matched > BROAD_MATCH_LIMIT && matched > targetCount * 3;
  }

  function ruleFor(el, targetCount) {
    var candidates = [attributeRule(el), idRule(el), classRule(el), imageRule(el), pathRule(el)]
      .filter(function (rule) { return rule !== null; });
    for (var i = 0; i < candidates.length; i++) {
      if (!tooBroad(candidates[i], targetCount)) return candidates[i];
    }
    return candidates[candidates.length - 1];
  }

  window.__slatePickArea = function (area) {
    var targets = collect(area);
    var rules = [];
    var seen = new Set();
    for (var i = 0; i < targets.length; i++) {
      var rule = ruleFor(targets[i], targets.length);
      var key = rule.kind + "|" + rule.value;
      if (!seen.has(key)) {
        seen.add(key);
        rules.push(rule);
      }
    }
    for (var j = 0; j < targets.length; j++) targets[j].remove();
    return rules;
  };
})();
