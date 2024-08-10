import SwiftUI
import SwiftOpenAI

struct ContentView: View {
    let openAIService: OpenAIService
    
    init() {
        // Initialize your OpenAI service here
        let apiKey = ""
        self.openAIService = OpenAIServiceFactory.service(apiKey: apiKey)
    }
    
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }
            ARTranslateView()
                .tabItem {
                    Label("AR Translate", systemImage: "camera")
                }
            AudioTranscriberView(openAIService: openAIService)
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }
            ARTranslateView()
                .tabItem {
                    Label("Data Scanner", systemImage: "text.viewfinder")
                }
            MapView()
                .tabItem {
                    Label("Map", systemImage: "map")
                }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
