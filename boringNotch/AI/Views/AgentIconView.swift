import SwiftUI

struct AgentIconView: View {
    var body: some View {
        Image(systemName: "brain")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.orange)
            .padding(2)
    }
}
