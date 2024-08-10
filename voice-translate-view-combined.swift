import SwiftUI
import AVFoundation
import SwiftOpenAI

struct VoiceTranslateView: View {
    @StateObject private var viewModel = VoiceTranslateViewModel()
    
    var body: some View {
        VStack {
            Text(viewModel.statusMessage)
                .font(.headline)
                .padding()
            
            Button(action: {
                viewModel.toggleRecording()
            }) {
                Text(viewModel.isRecording ? "Stop" : "Start")
                    .font(.title)
                    .padding()
                    .background(viewModel.isRecording ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            
            Text("Recognized: \(viewModel.recognizedText)")
                .padding()
            
            Text("Translated: \(viewModel.translatedText)")
                .padding()
        }
    }
}

class VoiceTranslateViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var recognizedText = ""
    @Published var translatedText = ""
    @Published var statusMessage = "Ready to start"
    
    private var audioRecorder: AVAudioRecorder?
    private let openAIService: OpenAIService
    private var audioFileURL: URL?
    
    init() {
        self.openAIService = OpenAIServiceFactory.service(apiKey: "YOUR_API_KEY")
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default)
            try audioSession.setActive(true)
        } catch {
            statusMessage = "Failed to set up audio session: \(error.localizedDescription)"
        }
    }
    
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("recording.m4a")
        audioFileURL = audioFilename
        
        let settings = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.record()
            isRecording = true
            statusMessage = "Recording..."
        } catch {
            statusMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }
    
    private func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        statusMessage = "Processing audio..."
        
        transcribeAudio()
    }
    
    private func transcribeAudio() {
        guard let audioFileURL = audioFileURL,
              let audioData = try? Data(contentsOf: audioFileURL) else {
            statusMessage = "Failed to load audio data"
            return
        }
        
        let parameters = AudioTranscriptionParameters(
            fileName: "recording.m4a",
            file: audioData,
            model: .whisperOne,
            responseFormat: "text"
        )
        
        Task {
            do {
                let result = try await openAIService.createTranscription(parameters: parameters)
                await MainActor.run {
                    self.recognizedText = result.text
                    self.translateText(result.text)
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Transcription error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func translateText(_ text: String) {
        let messages: [ChatCompletionParameters.Message] = [
            .init(role: .system, content: .text("You are a helpful assistant that detects the language of the input and translates it to the other language (English or Japanese). Respond only with the translation, nothing else.")),
            .init(role: .user, content: .text(text))
        ]
        
        let parameters = ChatCompletionParameters(messages: messages, model: .gpt4o)
        
        Task {
            do {
                let result = try await openAIService.startChat(parameters: parameters)
                if let translatedContent = result.choices.first?.message.content {
                    await MainActor.run {
                        self.translatedText = translatedContent
                        self.generateSpeech(for: translatedContent)
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Translation error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func generateSpeech(for text: String) {
        let parameters = AudioSpeechParameters(
            model: .tts1,
            input: text,
            voice: .nova
        )
        
        Task {
            do {
                let result = try await openAIService.createSpeech(parameters: parameters)
                await MainActor.run {
                    self.playAudio(from: result.output)
                    self.statusMessage = "Translation complete"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Speech generation error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func playAudio(from data: Data) {
        do {
            let audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer.prepareToPlay()
            audioPlayer.play()
        } catch {
            statusMessage = "Error playing audio: \(error.localizedDescription)"
        }
    }
    
    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
