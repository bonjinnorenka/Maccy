import SwiftUI

struct SlideoutContentView: View {
  @Environment(AppState.self) var appState

  var body: some View {
    VStack {
      ToolbarView()

      if appState.preview.state != .closed {
        if let item = appState.navigator.leadHistoryItem {
          PreviewItemView(item: item)
        } else if let pasteStack = appState.history.pasteStack,
          appState.navigator.pasteStackSelected {
          PasteStackPreviewView(pasteStack: pasteStack)
        } else {
          EmptyView()
        }
      } else {
        EmptyView()
      }
    }
    .padding(.horizontal)
    .padding(.bottom)
    .padding(.top, Popup.verticalPadding)
    .onChange(of: appState.navigator.leadHistoryItem?.id) { oldID, _ in
      guard let oldID,
            let oldItem = appState.history.all.first(where: { $0.id == oldID }) else {
        return
      }
      oldItem.cleanupImages()
    }
    .onChange(of: appState.preview.state) { _, state in
      guard state == .closed else {
        return
      }
      appState.navigator.leadHistoryItem?.cleanupImages()
    }
  }

}
