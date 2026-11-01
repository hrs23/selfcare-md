import SwiftUI
import UIKit

enum Theme {
    static let canvas = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.106, green: 0.090, blue: 0.078, alpha: 1)
            : UIColor(red: 0.957, green: 0.925, blue: 0.878, alpha: 1)
    })
}

extension View {
    func themed() -> some View {
        scrollContentBackground(.hidden).background(Theme.canvas)
    }

    func errorAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
