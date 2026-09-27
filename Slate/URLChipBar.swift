import SwiftUI

/// 주소 편집 중 주소창 위에 뜨는 조각 줄. 긴 주소를 마디(호스트·경로 조각·쿼리·#)로
/// 쪼개 칩으로 보여주고, 칩 하나를 누르면 그 조각만 고쳐서 바로 이동한다.
/// 아래 주소창의 통짜 편집은 그대로 남는다 — 이 줄은 지름길이다.
struct URLChipBar: View {
    let url: URL
    /// 조각 편집이 열려 있는 동안 참. 칩을 누르면 주소창이 포커스를 잃는데, 이 값이
    /// 바깥에서 줄을 붙들어 준다 — 없으면 편집 줄이 뜨기 전에 줄째 사라진다.
    @Binding var isEditingPart: Bool
    var onNavigate: (URL) -> Void

    /// 지금 고치는 중인 조각. nil이면 칩 줄, 있으면 편집 줄을 그린다.
    @State private var editing: URLPart? {
        didSet { isEditingPart = editing != nil }
    }
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Group {
            if let editing {
                editRow(editing)
            } else {
                chipRow
            }
        }
        .barSurface(Capsule())
        .onChange(of: url) { _, _ in self.editing = nil }
        .onDisappear { isEditingPart = false }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(URLPart.parts(of: url)) { part in
                    Button {
                        editing = part
                        editText = part.text
                        fieldFocused = true
                    } label: {
                        Text(part.text)
                            .font(.footnote.monospacedDigit())
                            .lineLimit(1)
                            .frame(maxWidth: 170)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func editRow(_ part: URLPart) -> some View {
        HStack(spacing: 8) {
            Button {
                editing = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            TextField("", text: $editText)
                .focused($fieldFocused)
                .font(.footnote.monospacedDigit())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .onSubmit(go)
                // 칩을 누른 시점엔 이 필드가 아직 화면에 없어서 포커스 지정이 무시될 수
                // 있다 — 붙고 나서 한 번 더 준다.
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
                }
            // 조각이 숫자를 품고 있으면 한 칸씩 넘기는 손잡이를 준다 — 쪽 번호용.
            if URLPart.number(in: editText) != nil {
                stepper(-1)
                stepper(+1)
            }
            Button("이동", action: go)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func stepper(_ delta: Int) -> some View {
        Button {
            if let stepped = URLPart.stepping(editText, by: delta) {
                editText = stepped
            }
        } label: {
            Image(systemName: delta < 0 ? "minus" : "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Color(.systemGray5), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func go() {
        guard let editing, let newURL = editing.replacing(with: editText, in: url) else { return }
        self.editing = nil
        onNavigate(newURL)
    }
}

/// 주소의 마디 하나. 어느 자리인지 알아야 고친 값을 제자리에 되꽂는다.
struct URLPart: Identifiable, Equatable {
    enum Kind: Equatable {
        case host
        case pathComponent(Int)
        case queryItem(Int)
        case fragment
    }

    let kind: Kind
    let text: String
    var id: String { "\(kind)-\(text)" }

    static func parts(of url: URL) -> [URLPart] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        var parts: [URLPart] = []
        if let host = components.host {
            parts.append(URLPart(kind: .host, text: host))
        }
        let pathPieces = components.path.split(separator: "/").map(String.init)
        for (index, piece) in pathPieces.enumerated() {
            parts.append(URLPart(kind: .pathComponent(index), text: piece))
        }
        for (index, item) in (components.queryItems ?? []).enumerated() {
            let text = item.value.map { "\(item.name)=\($0)" } ?? item.name
            parts.append(URLPart(kind: .queryItem(index), text: text))
        }
        if let fragment = components.fragment, !fragment.isEmpty {
            parts.append(URLPart(kind: .fragment, text: "#\(fragment)"))
        }
        return parts
    }

    /// 이 조각만 새 값으로 바꾼 주소를 만든다.
    func replacing(with newText: String, in url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let value = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .host:
            components.host = value
        case .pathComponent(let index):
            var pieces = components.path.split(separator: "/").map(String.init)
            guard pieces.indices.contains(index) else { return nil }
            pieces[index] = value
            components.path = "/" + pieces.joined(separator: "/")
        case .queryItem(let index):
            var items = components.queryItems ?? []
            guard items.indices.contains(index) else { return nil }
            if let eq = value.firstIndex(of: "=") {
                items[index] = URLQueryItem(name: String(value[..<eq]),
                                            value: String(value[value.index(after: eq)...]))
            } else {
                items[index] = URLQueryItem(name: value, value: nil)
            }
            components.queryItems = items
        case .fragment:
            components.fragment = value.hasPrefix("#") ? String(value.dropFirst()) : value
        }
        return components.url
    }

    /// 문자열 안 마지막 숫자 덩어리. all-1.html이면 1.
    static func number(in text: String) -> Range<String.Index>? {
        var last: Range<String.Index>?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isNumber {
                var end = index
                while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
                last = index..<end
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return last
    }

    /// 두 주소가 쪽 넘김 관계인가 — 같은 호스트에서 경로는 같고 쿼리·#만 다르거나, 목표에
    /// 쪽 번호 표시(/page/N 꼬리, ?page=N)가 있거나, 쪽 번호 꼬리를 뗀 경로가 숫자 덩어리만
    /// 다른 이동. 고정 탭이 제자리 이동을 허락하는 기준이다. sticky-detour.js와 같은 규칙.
    static func isPaginationMove(from current: URL, to target: URL) -> Bool {
        guard let a = URLComponents(url: current, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: target, resolvingAgainstBaseURL: false),
              a.host == b.host else { return false }
        if a.path == b.path { return true }
        if hasPageMarker(b) { return true }
        return listShape(a.path) == listShape(b.path)
    }

    /// 경로 끝의 쪽 번호 꼬리: /page/2/, /page-2, /paged/3. 1쪽은 꼬리가 없고 2쪽부터 붙는
    /// 목록이 많다.
    private static let pageSuffix = #/\/paged?[-_\/]?[0-9]+\/?$/#.ignoresCase()

    private static func hasPageMarker(_ components: URLComponents) -> Bool {
        if components.path.contains(pageSuffix) { return true }
        return components.queryItems?.contains { item in
            ["page", "paged"].contains(item.name.lowercased()) && Int(item.value ?? "") != nil
        } ?? false
    }

    /// 쪽 번호 꼬리와 끝 슬래시를 떼고 숫자를 뭉갠 경로. 목록 모양 비교용.
    private static func listShape(_ path: String) -> String {
        var stripped = path.replacing(pageSuffix, with: "")
        while stripped.hasSuffix("/") { stripped.removeLast() }
        return maskDigits(stripped)
    }

    /// 숫자 덩어리를 전부 #으로 뭉갠 경로. 모양 비교용.
    private static func maskDigits(_ path: String) -> String {
        var out = ""
        var inDigits = false
        for ch in path {
            if ch.isNumber {
                if !inDigits { out.append("#") }
                inDigits = true
            } else {
                out.append(ch)
                inDigits = false
            }
        }
        return out
    }

    /// 마지막 숫자 덩어리를 delta만큼 움직인 문자열. 0 아래로는 안 내려간다.
    static func stepping(_ text: String, by delta: Int) -> String? {
        guard let range = number(in: text), let value = Int(text[range]) else { return nil }
        let stepped = max(0, value + delta)
        return text.replacingCharacters(in: range, with: String(stepped))
    }
}
