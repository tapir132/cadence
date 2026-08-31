import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var term = ""
    @State private var query = ""

    var filteredTerms: [String] {
        query.isEmpty ? model.dictionary : model.dictionary.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PERSONALIZATION")
                .font(.system(size: 10, weight: .bold)).tracking(1.8)
                .foregroundStyle(CadenceTheme.muted)
            Text("Teach Cadence your words.")
                .font(.system(size: 40, weight: .medium, design: .serif))
                .tracking(-1.4)
                .padding(.top, 28)
            Text("Names, acronyms, and domain language are passed directly to the speech recognizer as context.")
                .font(.system(size: 13)).foregroundStyle(CadenceTheme.muted)
                .padding(.top, 10)

            HStack(spacing: 10) {
                TextField("Add a word or phrase", text: $term)
                    .textFieldStyle(.plain)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .buttonStyle(.borderedProminent)
                    .tint(CadenceTheme.ink)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(CadenceTheme.line))
            .padding(.top, 32)

            HStack {
                Text("\(model.dictionary.count) TERMS")
                    .font(.system(size: 9, weight: .bold)).tracking(1.2)
                Spacer()
                TextField("Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }
            .foregroundStyle(CadenceTheme.muted)
            .padding(.top, 28)
            .padding(.bottom, 8)

            List {
                ForEach(filteredTerms, id: \.self) { value in
                    HStack {
                        Image(systemName: "quote.opening").foregroundStyle(CadenceTheme.muted)
                        Text(value).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    let names = offsets.map { filteredTerms[$0] }
                    model.dictionary.removeAll { names.contains($0) }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.inset)
        }
        .padding(42)
        .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
    }

    private func addTerm() {
        model.addDictionaryTerm(term)
        term = ""
    }
}
