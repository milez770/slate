// 페이지 내 찾기. CSS Custom Highlight로 칠하므로 DOM을 바꾸지 않는다 —
// 텍스트 노드를 쪼개는 방식은 사이트 스크립트와 충돌한다.
(function () {
  if (window.__slateFind) return;

  let ranges = [];
  let current = -1;
  // 현재 일치 표시는 이 객체 하나를 유지하고 내용만 갈아 끼운다. 레지스트리에 새 Highlight를
  // 넣어 교체하면 WebKit이 이전 범위를 다시 칠하지 않아 지난 일치에 불이 남는다.
  const currentHighlight = "highlights" in CSS ? new Highlight() : null;

  function collectRanges(query) {
    const q = query.toLowerCase();
    const out = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        const p = node.parentElement;
        if (!p) return NodeFilter.FILTER_REJECT;
        if (p.closest("script,style,noscript,textarea")) return NodeFilter.FILTER_REJECT;
        const s = getComputedStyle(p);
        if (s.display === "none" || s.visibility === "hidden") return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    let node;
    while ((node = walker.nextNode())) {
      const text = node.nodeValue.toLowerCase();
      let idx = 0;
      while ((idx = text.indexOf(q, idx)) !== -1) {
        const r = new Range();
        r.setStart(node, idx);
        r.setEnd(node, idx + q.length);
        out.push(r);
        idx += q.length;
      }
    }
    return out;
  }

  // 검색을 새로 돌리고 일치 수를 돌려준다.
  window.__slateFind = function (query) {
    window.__slateFindClear();
    if (!query || !("highlights" in CSS)) return 0;
    ranges = collectRanges(String(query));
    if (ranges.length) {
      CSS.highlights.set("slate-find", new Highlight(...ranges));
    }
    return ranges.length;
  };

  // index번째 일치로 이동한다. 범위를 벗어나면 감아서(순환) 정규화된 인덱스를 돌려준다.
  window.__slateFindGoto = function (index) {
    if (!ranges.length) return -1;
    current = ((index % ranges.length) + ranges.length) % ranges.length;
    const r = ranges[current];
    currentHighlight.clear();
    currentHighlight.add(r);
    CSS.highlights.set("slate-find-current", currentHighlight);
    const rect = r.getBoundingClientRect();
    // 화면 밖이면 위에서 1/3 지점으로 데려온다.
    if (rect.top < 0 || rect.bottom > innerHeight) {
      scrollBy({ top: rect.top - innerHeight / 3, behavior: "instant" });
    }
    return current;
  };

  window.__slateFindClear = function () {
    ranges = [];
    current = -1;
    if ("highlights" in CSS) {
      if (currentHighlight) currentHighlight.clear();
      CSS.highlights.delete("slate-find");
      CSS.highlights.delete("slate-find-current");
    }
  };

  const style = document.createElement("style");
  style.textContent =
    "::highlight(slate-find){background-color:rgba(255,235,59,.55);color:inherit;}" +
    "::highlight(slate-find-current){background-color:#29FF6C;color:#000;}";
  document.documentElement.appendChild(style);
})();
