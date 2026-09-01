// slateAutoTranslate: 일본어·중국어 글자를 모아 네이티브(slateTranslate)에 넘기고, 돌아온 한국어로
// 바꾼다. 텍스트 노드와 placeholder·버튼 value 속성이 대상이다. 페이지가 나중에 갈아끼우는 글자는
// 관찰자가 다시 모은다.
(function () {
  if (window.__slateAutoTranslate) return;
  window.__slateAutoTranslate = true;

  var KANA = /[぀-ヿㇰ-ㇿｦ-ﾟ]/;
  var HAN = /[㐀-䶿一-鿿]/;
  var BATCH = 60;
  var DEBOUNCE_MS = 300;
  var NO_TRANSLATE = "[translate='no'],.notranslate";
  var SKIP = "script,style,noscript,textarea,input,code,pre,[contenteditable]:not([contenteditable='false'])," + NO_TRANSLATE;
  var ATTR_TARGETS = "input[placeholder],textarea[placeholder],input[type='button'][value],input[type='submit'][value],input[type='reset'][value]";

  // 텍스트 노드 → 우리가 마지막으로 써넣은 글자. 이 값 그대로면 우리 변경, 다르면 사이트가 간 것.
  var written = new WeakMap();
  // 요소 → { 속성명: 우리가 써넣은 값 }
  var writtenAttr = new WeakMap();
  // 왕복 중. id → { node, text } 또는 { el, attr, text }
  var pending = new Map();
  // 원문 → 번역. 같은 문장은 왕복 없이 바꾼다.
  var cache = new Map();
  var nextID = 1;
  var timer = null;
  var pageHasKana = false;

  // 가나가 있으면 일본어. 한자만 있으면 문서에 가나가 하나라도 있을 때 일본어, 아니면 중국어.
  function detect(text) {
    if (KANA.test(text)) return "ja";
    if (!HAN.test(text)) return null;
    return pageHasKana ? "ja" : "zh";
  }

  // 앞뒤 공백은 그대로 두고 가운데 글자만 다룬다.
  function split(value) {
    var m = /^(\s*)([\s\S]*?)(\s*)$/.exec(value);
    return { lead: m[1], core: m[2], trail: m[3] };
  }

  function write(node, lead, text, trail) {
    var value = lead + text + trail;
    written.set(node, value);
    node.nodeValue = value;
  }

  function writeAttr(el, attr, text) {
    var map = writtenAttr.get(el);
    if (!map) {
      map = {};
      writtenAttr.set(el, map);
    }
    map[attr] = text;
    el.setAttribute(attr, text);
  }

  function acceptable(node) {
    var value = node.nodeValue;
    if (!value || !value.trim()) return false;
    var p = node.parentElement;
    if (!p || p.closest(SKIP)) return false;
    if (written.get(node) === value) return false;
    return detect(value) !== null;
  }

  function attrOf(el) {
    if (el.hasAttribute("placeholder")) return "placeholder";
    return "value";
  }

  function queue(batch, entry, text, lang) {
    var id = nextID++;
    entry.text = text;
    entry.lang = lang;
    pending.set(id, entry);
    batch.push({ id: id, text: text, lang: lang });
  }

  // 바뀐 곳만 다시 본다. 로드 때 한 번은 문서 전체.
  var dirty = new Set();
  var fullScan = true;

  function acceptText(node, inflight, batch) {
    if (inflight.has(node) || !acceptable(node)) return false;
    var parts = split(node.nodeValue);
    if (!pageHasKana && KANA.test(parts.core)) pageHasKana = true;
    var hit = cache.get(parts.core);
    if (hit !== undefined) {
      write(node, parts.lead, hit, parts.trail);
      return false;
    }
    queue(batch, { node: node }, parts.core, detect(parts.core));
    return batch.length >= BATCH;
  }

  function acceptAttr(el, inflight, batch) {
    if (inflight.has(el) || el.closest(NO_TRANSLATE)) return false;
    var attr = attrOf(el);
    var value = el.getAttribute(attr);
    if (!value || !value.trim()) return false;
    var map = writtenAttr.get(el);
    if (map && map[attr] === value) return false;
    var lang = detect(value);
    if (lang === null) return false;
    var cached = cache.get(value);
    if (cached !== undefined) {
      writeAttr(el, attr, cached);
      return false;
    }
    queue(batch, { el: el, attr: attr }, value, lang);
    return batch.length >= BATCH;
  }

  // root 하나(텍스트 노드 또는 요소 서브트리)를 훑는다. 묶음이 찼으면 true.
  function scan(root, inflight, batch) {
    if (root.nodeType === Node.TEXT_NODE) return acceptText(root, inflight, batch);
    if (root.nodeType !== Node.ELEMENT_NODE && root.nodeType !== Node.DOCUMENT_NODE) return false;
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var node;
    while ((node = walker.nextNode())) {
      if (acceptText(node, inflight, batch)) return true;
    }
    if (root.nodeType === Node.ELEMENT_NODE && root.matches(ATTR_TARGETS) && acceptAttr(root, inflight, batch)) return true;
    var els = root.querySelectorAll(ATTR_TARGETS);
    for (var i = 0; i < els.length; i++) {
      if (acceptAttr(els[i], inflight, batch)) return true;
    }
    return false;
  }

  function collect() {
    if (!document.body) return [];
    var inflight = new Set();
    pending.forEach(function (entry) { inflight.add(entry.node || entry.el); });
    var batch = [];
    if (fullScan) {
      pageHasKana = KANA.test(document.body.textContent || "");
      if (scan(document.body, inflight, batch)) return batch;   // 남은 건 다음 run이 이어서
      fullScan = false;
      dirty.clear();
      return batch;
    }
    var roots = Array.from(dirty);
    dirty.clear();
    for (var i = 0; i < roots.length; i++) {
      if (!roots[i].isConnected) continue;
      if (scan(roots[i], inflight, batch)) {
        // 묶음이 찼으면 못 본 뿌리는 되돌려 놓는다.
        for (var j = i; j < roots.length; j++) dirty.add(roots[j]);
        return batch;
      }
    }
    return batch;
  }

  function send(batch) {
    if (!batch.length) return;
    try {
      window.webkit.messageHandlers.slateTranslate.postMessage(batch);
    } catch (e) {
      // 시험 환경: 핸들러 없음. 대기 목록은 __slateTranslatePending으로 읽는다.
    }
  }

  function run() {
    timer = null;
    if (document.hidden) return;   // 돌아오면 visibilitychange가 다시 돌린다
    var batch = collect();
    send(batch);
    // 한 묶음 상한에 걸렸으면 남은 것을 이어서 모은다.
    if (batch.length >= BATCH || dirty.size) schedule();
  }

  function schedule() {
    if (timer !== null) return;
    timer = setTimeout(run, DEBOUNCE_MS);
  }

  document.addEventListener("visibilitychange", function () {
    if (!document.hidden && (dirty.size || fullScan)) schedule();
  });

  window.__slateApplyTranslations = function (items) {
    for (var i = 0; i < items.length; i++) {
      var entry = pending.get(items[i].id);
      if (!entry) continue;
      pending.delete(items[i].id);
      var text = items[i].text;
      if (typeof text !== "string" || !text) {
        // 번역이 안 온 글자는 사이트가 갈 때까지 다시 묻지 않는다.
        if (entry.node) written.set(entry.node, entry.node.nodeValue);
        else writeAttr(entry.el, entry.attr, entry.el.getAttribute(entry.attr));
        continue;
      }
      cache.set(entry.text, text);
      if (entry.el) {
        // 답을 기다리는 동안 사이트가 값을 갈았으면 다음 순회가 다시 모은다.
        if (entry.el.getAttribute(entry.attr) === entry.text) writeAttr(entry.el, entry.attr, text);
        continue;
      }
      var parts = split(entry.node.nodeValue);
      if (parts.core !== entry.text) continue;
      write(entry.node, parts.lead, text, parts.trail);
    }
  };

  window.__slateTranslatePending = function () {
    var out = [];
    pending.forEach(function (entry, id) { out.push({ id: id, text: entry.text, lang: entry.lang }); });
    return out;
  };

  new MutationObserver(function (records) {
    var touched = false;
    for (var i = 0; i < records.length; i++) {
      var r = records[i];
      if (r.type === "characterData") {
        if (written.get(r.target) === r.target.nodeValue) continue;
        dirty.add(r.target);
        touched = true;
      } else if (r.type === "attributes") {
        var map = writtenAttr.get(r.target);
        if (map && map[r.attributeName] === r.target.getAttribute(r.attributeName)) continue;
        dirty.add(r.target);
        touched = true;
      } else {
        for (var k = 0; k < r.addedNodes.length; k++) dirty.add(r.addedNodes[k]);
        if (r.addedNodes.length) touched = true;
      }
    }
    if (touched) schedule();
  }).observe(document.documentElement, {
    childList: true, characterData: true, subtree: true,
    attributes: true, attributeFilter: ["placeholder", "value"],
  });

  run();
})();
