// slatePopupGuard: 스크립트가 여는 외부 창·이동을 막는다.
// 광고 스크립트는 사용자의 탭 한 번을 받아 window.open → 가짜 <a target=_blank>.click() → location.href 순으로
// 외부 광고 페이지를 연다. 첫 단계에 "성공한 창"을 돌려줘 다음 단계로 못 넘어가게 하고,
// 사용자 손가락이 아닌 클릭으로 외부 앵커를 누르는 것은 취소한다.
// 사용자가 누른 앵커의 주소는 따로 기억한다 — 핸들러가 그 클릭을 가로채 광고로 보내면 누른 링크로 되돌린다.
(function () {
  if (window.__slatePopupGuard) return;
  window.__slatePopupGuard = true;

  var GESTURE_WINDOW_MS = 1000;
  var lastTrusted = { time: 0, target: null };
  // 지금 처리 중인 사용자 클릭. { href: 누른 앵커 주소 또는 null, faked: 이 클릭 안에서 광고 창을 가짜로 넘겼나 }
  var gesture = null;

  // 광고 수법을 막은 순간 네이티브에 알린다. 광고 스크립트는 창 열기가 막히면
  // location 이동으로 넘어가는데, 그건 JS로 못 막는다 — 네이티브 이동 정책이 이
  // 신호 직후의 딴 사이트 이동을 자른다.
  function signalAdIntent() {
    try { window.webkit.messageHandlers.slateAdIntent.postMessage(1); } catch (e) {}
  }

  function registrable(host) {
    var labels = host.split(".");
    if (labels.length <= 2) return host;
    var second = labels[labels.length - 2];
    var keep = (second.length <= 3 && labels.length >= 3) ? 3 : 2;   // co.kr·com.au 류
    return labels.slice(-keep).join(".");
  }

  function webURL(raw) {
    var url;
    try { url = new URL(raw, location.href); } catch (e) { return null; }
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    return url;
  }

  function crossSite(raw) {
    var url = webURL(raw);
    if (!url) return false;
    return registrable(url.hostname) !== registrable(location.hostname);
  }

  window.addEventListener("click", function (e) {
    if (e.isTrusted) {
      lastTrusted = { time: Date.now(), target: e.target };
      var anchor = e.target && e.target.closest ? e.target.closest("a[href]") : null;
      var href = anchor ? webURL(anchor.href) : null;
      var current = gesture = { href: href ? href.href : null, faked: false };
      // 페이지 핸들러들이 다 돈 뒤에 본다. 누른 앵커의 기본 이동을 막았는지, 광고 창을 가짜로 받았는지
      // 네이티브에 알리고, 둘 다면 누른 링크로 간다 — 핸들러가 클릭을 광고로 바꿔치기한 것이다.
      setTimeout(function () {
        if (gesture === current) gesture = null;
        if (!current.href) return;
        try {
          window.webkit.messageHandlers.slateClickIntent.postMessage({ href: current.href, prevented: !!e.defaultPrevented });
        } catch (e2) {}
        if (current.faked && e.defaultPrevented) {
          if (window.__slateSticky) {
            try { window.webkit.messageHandlers.slateStickyOpen.postMessage(current.href); } catch (e3) {}
          } else {
            location.href = current.href;
          }
        }
      }, 0);
      return;
    }
    var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (a && crossSite(a.href)) { e.preventDefault(); e.stopImmediatePropagation(); signalAdIntent(); }
  }, true);

  // 사용자가 방금 누른 앵커가 그 URL을 가리키고 있을 때만 진짜 창을 연다.
  function gestureOpens(url) {
    if (Date.now() - lastTrusted.time > GESTURE_WINDOW_MS) return false;
    var t = lastTrusted.target;
    var a = t && t.closest ? t.closest("a[href]") : null;
    if (!a) return false;
    try { return new URL(a.href, location.href).hostname === new URL(url, location.href).hostname; }
    catch (e) { return false; }
  }

  function fakeWindow() {
    var w = {
      closed: false, opener: null, name: "",
      focus: function () {}, blur: function () {}, close: function () { w.closed = true; },
      postMessage: function () {}, addEventListener: function () {}, removeEventListener: function () {},
      document: { write: function () {}, writeln: function () {}, open: function () {}, close: function () {},
                  body: {}, head: {}, title: "" },
      location: {}
    };
    ["href", "assign", "replace", "reload"].forEach(function (k) {
      Object.defineProperty(w.location, k, { get: function () { return k === "href" ? "about:blank" : function () {}; },
                                             set: function () { signalAdIntent(); }, configurable: true });
    });
    return w;
  }

  var realOpen = window.open;
  window.open = function (url, name, features) {
    var target = url == null ? "" : String(url);
    if (target && crossSite(target) && !gestureOpens(target)) {
      signalAdIntent();
      if (gesture) gesture.faked = true;
      return fakeWindow();
    }
    return realOpen.apply(window, arguments);
  };

  var realClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (!this.isConnected && crossSite(this.href)) { signalAdIntent(); return; }
    return realClick.apply(this, arguments);
  };
})();
