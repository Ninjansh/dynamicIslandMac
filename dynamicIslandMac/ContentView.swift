import SwiftUI

struct ContentView: View {
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.green)
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dynamic Island")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    Text("Active Session")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            
            Spacer()
            
            Image(systemName: isExpanded ? "xmark.circle.fill" : "sparkles")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 12)
        .frame(width: isExpanded ? 320 : 200, height: isExpanded ? 60 : 32)
        .background(Color.black)
        .clipShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isExpanded.toggle()
            }
        }
    }
}

#Preview {
    ContentView()
}
