// slateAdStubs: 광고 스크립트가 있는 것처럼 보이는 껍데기. 광고 요청은 규칙 목록이 막아 진짜는
// 안 오므로, 감지 스크립트가 "adsbygoogle이 없다·로드가 막혔다"로 판정하지 않게 전역 객체와
// 광고 자리를 채운다. 광고 차단 감지 라이브러리(BlockAdBlock·FuckAdBlock)는 "감지 안 됨"으로
// 답하는 가짜 인스턴스로 갈아 끼운다.
(function () {
  if (window.__slateAdStubs) return;
  window.__slateAdStubs = true;

  function noop() {}
  function chain() { return this; }

  // AdSense
  var ads = window.adsbygoogle;
  if (!Array.isArray(ads)) ads = window.adsbygoogle = [];
  ads.loaded = true;
  ads.push = function () { return 0; };
  window.google_ad_status = 1;

  function sizeOf(ins, name) {
    var v = ins.getAttribute("data-ad-" + name) || ins.getAttribute(name);
    return /^\d+$/.test(v || "") ? v : "1";
  }

  // 광고 자리(ins.adsbygoogle)를 채워진 것으로 표시하고 높이를 준다 — 빈 자리 높이 0을 재는 감지도 통과.
  function fill(ins) {
    if (ins.getAttribute("data-adsbygoogle-status") === "done") return;
    ins.setAttribute("data-adsbygoogle-status", "done");
    ins.setAttribute("data-ad-status", "filled");
    var frame = document.createElement("iframe");
    frame.setAttribute("data-slate-stub", "1");
    frame.style.cssText = "display:block;border:0;width:" + sizeOf(ins, "width") + "px;height:" + sizeOf(ins, "height") + "px";
    ins.appendChild(frame);
  }

  function fillAll(root) {
    if (!root.querySelectorAll) return;
    var list = root.querySelectorAll("ins.adsbygoogle");
    for (var i = 0; i < list.length; i++) fill(list[i]);
  }

  if (document.readyState !== "loading") fillAll(document);
  document.addEventListener("DOMContentLoaded", function () { fillAll(document); });
  new MutationObserver(function (records) {
    for (var i = 0; i < records.length; i++) {
      var added = records[i].addedNodes;
      for (var k = 0; k < added.length; k++) {
        var n = added[k];
        if (n.nodeType !== 1) continue;
        if (n.matches && n.matches("ins.adsbygoogle")) fill(n);
        else fillAll(n);
      }
    }
  }).observe(document.documentElement, { childList: true, subtree: true });

  // Google Publisher Tag
  var tag = window.googletag = window.googletag || {};
  var queued = Array.isArray(tag.cmd) ? tag.cmd.slice() : [];
  var cmd = [];
  cmd.push = function () {
    for (var i = 0; i < arguments.length; i++) {
      try { arguments[i](); } catch (e) {}
    }
    return 0;
  };
  tag.cmd = cmd;
  tag.apiReady = true;
  tag.pubadsReady = true;
  var slot = {
    addService: chain, setTargeting: chain, clearTargeting: chain, defineSizeMapping: chain,
    setCollapseEmptyDiv: chain, setClickUrl: chain, set: chain,
    get: function () { return null; }, getTargeting: function () { return []; },
    getTargetingKeys: function () { return []; }, getSlotElementId: function () { return ""; },
    getAdUnitPath: function () { return ""; }
  };
  var service = {
    addEventListener: chain, removeEventListener: chain, enableSingleRequest: chain,
    enableAsyncRendering: chain, enableLazyLoad: chain, disableInitialLoad: chain,
    collapseEmptyDivs: chain, setTargeting: chain, clearTargeting: chain, setCentering: chain,
    setRequestNonPersonalizedAds: chain, setPrivacySettings: chain, setPublisherProvidedId: chain,
    setForceSafeFrame: chain, setSafeFrameConfig: chain, updateCorrelator: chain, set: chain,
    enableVideoAds: chain, setVideoContent: chain, refresh: noop, display: noop,
    clear: function () { return true; }, getSlots: function () { return []; },
    get: function () { return null; }, getTargetingKeys: function () { return []; },
    isInitialLoadDisabled: function () { return false; }, getName: function () { return "publisher_ads"; }
  };
  tag.pubads = function () { return service; };
  tag.companionAds = function () { return service; };
  tag.content = function () { return service; };
  tag.defineSlot = function () { return slot; };
  tag.defineOutOfPageSlot = function () { return slot; };
  tag.destroySlots = function () { return true; };
  tag.display = noop;
  tag.enableServices = noop;
  tag.disablePublisherConsole = noop;
  tag.setAdIframeTitle = noop;
  tag.getVersion = function () { return "0"; };
  tag.enums = { OutOfPageFormat: {} };
  tag.sizeMapping = function () {
    var builder = { addSize: function () { return builder; }, build: function () { return []; } };
    return builder;
  };
  queued.forEach(function (f) { try { f(); } catch (e) {} });

  // BlockAdBlock · FuckAdBlock · SniffAdBlock: 감지 안 됨으로만 답한다. 전역 이름을 바꿀 수 없게
  // 박아 두면 진짜 라이브러리가 자기 인스턴스를 못 심는다.
  function Detector() {
    var self = this;
    this.onDetected = function () { return self; };
    this.onNotDetected = function (fn) {
      setTimeout(function () { try { fn(); } catch (e) {} }, 1);
      return self;
    };
    this.on = function (detected, fn) { return detected ? self : self.onNotDetected(fn); };
    this.check = function () { return true; };
    this.emitEvent = function () { return self; };
    this.clearEvent = noop;
    this.setOption = function () { return self; };
  }
  ["blockAdBlock", "fuckAdBlock", "sniffAdBlock", "BlockAdBlock", "FuckAdBlock", "SniffAdBlock"].forEach(function (name) {
    var value = /^[A-Z]/.test(name) ? Detector : new Detector();
    try {
      Object.defineProperty(window, name, { value: value, writable: false, configurable: false });
    } catch (e) {}
  });
})();
