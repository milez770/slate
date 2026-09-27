import WebKit
import XCTest
@testable import Slate

/// auto-translate.js: 일본어 텍스트 노드를 모아 네이티브에 넘기고, 돌아온 번역으로 치환한다.
/// 시험 환경에는 메시지 핸들러가 없으므로 대기 중 묶음을 window.__slateTranslatePending()으로 읽는다.
@MainActor
final class AutoTranslateTests: XCTestCase {
    private func harness() -> ScriptHarness {
        ScriptHarness(scripts: [UserScripts.source(named: "auto-translate")])
    }

    private func pending(_ h: ScriptHarness) async throws -> [[String: Any]] {
        let value = try await h.eval("JSON.stringify(window.__slateTranslatePending())") as? String ?? "[]"
        let data = Data(value.utf8)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    private func texts(_ items: [[String: Any]]) -> [String] {
        items.compactMap { $0["text"] as? String }
    }

    private func langs(_ items: [[String: Any]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let t = item["text"] as? String, let l = item["lang"] as? String else { return nil }
            return (t, l)
        })
    }

    private let page = """
    <html><body>
      <p id="ja">こんにちは</p>
      <p id="ko">안녕하세요</p>
      <p id="en">Hello</p>
      <p id="mixed">  今日は<b>晴れ</b>です  </p>
      <script>var s = "これはスクリプト";</script>
      <style>.x::before { content: "スタイル"; }</style>
      <textarea id="ta">入力欄</textarea>
      <div contenteditable="true">編集可能</div>
      <pre>コード</pre>
      <span translate="no">翻訳しない</span>
    </body></html>
    """

    func testCollectsOnlyJapaneseTextNodes() async throws {
        let h = harness()
        await h.load(page)
        let got = texts(try await pending(h))
        XCTAssertEqual(Set(got), ["こんにちは", "今日は", "晴れ", "です"])
    }

    func testApplyReplacesTextAndKeepsSurroundingWhitespace() async throws {
        let h = harness()
        await h.load(page)
        let items = try await pending(h)
        let json = items.map { item -> String in
            let id = item["id"] as! Int
            let text = item["text"] as! String
            let translated: String? = text == "こんにちは" ? "안녕하세요" : (text == "今日は" ? "오늘은" : nil)
            return translated.map { "{\"id\":\(id),\"text\":\(h.jsString($0))}" } ?? "{\"id\":\(id),\"text\":null}"
        }.joined(separator: ",")
        _ = try await h.eval("window.__slateApplyTranslations([\(json)]); 1")
        let ja = try await h.eval("document.getElementById('ja').textContent") as? String
        XCTAssertEqual(ja, "안녕하세요")
        let mixed = try await h.eval("document.getElementById('mixed').firstChild.nodeValue") as? String
        XCTAssertEqual(mixed, "  오늘은", "앞 공백은 남기고 글자만 바꾼다")
        let bold = try await h.eval("document.querySelector('#mixed b').textContent") as? String
        XCTAssertEqual(bold, "晴れ", "번역이 안 온(null) 노드는 원문 그대로")
        let after = try await pending(h)
        XCTAssertTrue(after.isEmpty, "답이 온 노드는 대기 목록에서 빠진다")
    }

    func testNewNodesAreCollectedAfterMutation() async throws {
        let h = harness()
        await h.load(page)
        _ = try await pending(h)
        _ = try await h.eval("""
            window.__slateApplyTranslations(window.__slateTranslatePending().map(function (i) { return { id: i.id, text: null }; }));
            var d = document.createElement('div'); d.id = 'late'; d.textContent = 'あとから'; document.body.appendChild(d);
            document.getElementById('ko').textContent = '나중에';
            1
        """)
        try await Task.sleep(for: .milliseconds(600))
        let got = texts(try await pending(h))
        XCTAssertEqual(got, ["あとから"], "새로 생긴 일본어만 다시 모은다")
    }

    func testTranslatedNodeIsNotRecollectedButChangedTextIs() async throws {
        let h = harness()
        await h.load(page)
        let items = try await pending(h)
        let all = items.map { "{\"id\":\($0["id"] as! Int),\"text\":\"번역\"}" }.joined(separator: ",")
        _ = try await h.eval("window.__slateApplyTranslations([\(all)]); 1")
        try await Task.sleep(for: .milliseconds(600))
        let untouched = try await pending(h)
        XCTAssertTrue(untouched.isEmpty, "우리가 바꾼 글자는 다시 모으지 않는다")
        _ = try await h.eval("document.getElementById('ja').firstChild.nodeValue = 'さようなら'; 1")
        try await Task.sleep(for: .milliseconds(600))
        let changed = texts(try await pending(h))
        XCTAssertEqual(changed, ["さようなら"], "사이트가 글자를 갈면 다시 모은다")
    }

    func testCachedTranslationAppliesWithoutRoundTrip() async throws {
        let h = harness()
        await h.load(page)
        let items = try await pending(h)
        let id = items.first { $0["text"] as? String == "こんにちは" }!["id"] as! Int
        let others = items.filter { $0["text"] as? String != "こんにちは" }
            .map { "{\"id\":\($0["id"] as! Int),\"text\":null}" }
        _ = try await h.eval("window.__slateApplyTranslations([{id:\(id),text:'안녕하세요'},\(others.joined(separator: ","))]); 1")
        _ = try await h.eval("""
            var d = document.createElement('div'); d.id = 'again'; d.textContent = 'こんにちは'; document.body.appendChild(d); 1
        """)
        try await Task.sleep(for: .milliseconds(600))
        let again = try await h.eval("document.getElementById('again').textContent") as? String
        XCTAssertEqual(again, "안녕하세요", "같은 문장은 왕복 없이 캐시로 바꾼다")
        let rest = try await pending(h)
        XCTAssertTrue(rest.isEmpty)
    }

    /// 원문 보기: 번역된 글자를 제자리에서 원문으로 되돌리고, 그동안 새 글자는 번역하지 않다가
    /// 끄면 번역으로 돌아오며 미뤄 둔 글자도 이어서 모은다.
    func testShowOriginalSwapsInPlaceAndPausesTranslation() async throws {
        let h = harness()
        await h.load(page)
        let items = try await pending(h)
        let all = items.map { "{\"id\":\($0["id"] as! Int),\"text\":\"번역\"}" }.joined(separator: ",")
        _ = try await h.eval("window.__slateApplyTranslations([\(all)]); 1")
        _ = try await h.eval("window.__slateShowOriginal(true); 1")
        let original = try await h.eval("document.getElementById('ja').textContent") as? String
        XCTAssertEqual(original, "こんにちは")
        let mixed = try await h.eval("document.getElementById('mixed').firstChild.nodeValue") as? String
        XCTAssertEqual(mixed, "  今日は", "앞 공백까지 원문 그대로")
        _ = try await h.eval("""
            var d = document.createElement('div'); d.id = 'late'; d.textContent = 'あとから'; document.body.appendChild(d); 1
        """)
        try await Task.sleep(for: .milliseconds(600))
        let paused = try await pending(h)
        XCTAssertTrue(paused.isEmpty, "원문을 보는 동안은 새 글자를 보내지 않는다")
        let stillJa = try await h.eval("document.getElementById('ja').textContent") as? String
        XCTAssertEqual(stillJa, "こんにちは", "되돌린 글자를 다시 모아 번역하지 않는다")
        _ = try await h.eval("window.__slateShowOriginal(false); 1")
        let back = try await h.eval("document.getElementById('ja').textContent") as? String
        XCTAssertEqual(back, "번역")
        try await Task.sleep(for: .milliseconds(600))
        let resumed = texts(try await pending(h))
        XCTAssertEqual(resumed, ["あとから"], "끄면 미뤄 둔 글자를 이어서 모은다")
    }

    /// 원문 보기 중에 도착한 번역은 써넣지 않고 기억해 두다가 끄면 나타난다.
    func testTranslationArrivingWhileShowingOriginalAppearsLater() async throws {
        let h = harness()
        await h.load(page)
        let items = try await pending(h)
        _ = try await h.eval("window.__slateShowOriginal(true); 1")
        let all = items.map { "{\"id\":\($0["id"] as! Int),\"text\":\"번역\"}" }.joined(separator: ",")
        _ = try await h.eval("window.__slateApplyTranslations([\(all)]); 1")
        let during = try await h.eval("document.getElementById('ja').textContent") as? String
        XCTAssertEqual(during, "こんにちは")
        _ = try await h.eval("window.__slateShowOriginal(false); 1")
        let after = try await h.eval("document.getElementById('ja').textContent") as? String
        XCTAssertEqual(after, "번역")
    }

    func testHanOnlyTextIsChineseUnlessPageHasKana() async throws {
        let h = harness()
        await h.load("<html><body><p>漢字</p><p>中文内容</p><p>Hello</p></body></html>")
        let hanOnly = langs(try await pending(h))
        XCTAssertEqual(hanOnly, ["漢字": "zh", "中文内容": "zh"], "가나가 하나도 없는 문서의 한자는 중국어")
        let h2 = harness()
        await h2.load("<html><body><p>漢字</p><p>ひらがな</p></body></html>")
        let withKana = langs(try await pending(h2))
        XCTAssertEqual(withKana, ["漢字": "ja", "ひらがな": "ja"], "가나가 있는 문서의 한자는 일본어")
    }

    func testPlaceholderButtonValueAndOptionAreCollectedAndApplied() async throws {
        let h = harness()
        await h.load("""
            <html><body>
              <input id="q" placeholder="検索キーワード">
              <textarea id="t" placeholder="コメント">本文</textarea>
              <input id="b" type="submit" value="送信">
              <input id="txt" type="text" value="入力済み">
              <select><option id="o">選択肢</option></select>
            </body></html>
        """)
        let items = try await pending(h)
        XCTAssertEqual(Set(texts(items)), ["検索キーワード", "コメント", "送信", "選択肢"],
                       "placeholder·submit value·option은 모으고, 글 입력칸의 value와 textarea 본문은 안 건드린다")
        let json = items.map { "{\"id\":\($0["id"] as! Int),\"text\":\"번역\"}" }.joined(separator: ",")
        _ = try await h.eval("window.__slateApplyTranslations([\(json)]); 1")
        let q = try await h.eval("document.getElementById('q').placeholder") as? String
        let b = try await h.eval("document.getElementById('b').value") as? String
        let o = try await h.eval("document.getElementById('o').textContent") as? String
        XCTAssertEqual([q, b, o], ["번역", "번역", "번역"])
        try await Task.sleep(for: .milliseconds(600))
        let after = try await pending(h)
        XCTAssertTrue(after.isEmpty, "우리가 바꾼 속성은 다시 모으지 않는다")
        _ = try await h.eval("document.getElementById('q').placeholder = '別の言葉'; 1")
        try await Task.sleep(for: .milliseconds(600))
        let changed = texts(try await pending(h))
        XCTAssertEqual(changed, ["別の言葉"], "사이트가 placeholder를 갈면 다시 모은다")
    }
}
