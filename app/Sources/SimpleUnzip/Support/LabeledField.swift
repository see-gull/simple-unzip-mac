import SwiftUI

/// A labelled form row that puts the field on its own full-width line.
///
/// Two macOS `Form` behaviours conspire against a plain `TextField` row:
/// the field's title is hoisted out to become the row's leading label, and the
/// control itself is placed in the right-hand value column. The result is a
/// duplicated label and text hugging the trailing edge. `labelsHidden()` stops
/// the hoisting, and the caption above supplies the label instead.
struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
