import Foundation
import SwiftUI
import AVFoundation
import SwiftOpenAI

class AudioTranscriber: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var transcriptions: [(text: String, translation: String)] = []
    @Published var isRecording: Bool = false
    @Published var debugInfo: String = ""
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    
    private var audioRecorder: AVAudioRecorder?
    private let openAIService: OpenAIService
    private var levelUpdateTimer: Timer?
    private let pauseThreshold: Float = -30.0 // Adjusted threshold for better pause detection
    private let pauseDuration: TimeInterval = 1.5 // Slightly longer pause duration
    private var lastTranscriptionTime: Date?
    private var lastAudioLevel: Float = 0
    private var pauseStartTime: Date?
    private var currentAudioFileURL: URL?
    private var isTranscribing: Bool = false
    private var isTranslating: Bool = false
    private var sessionActive: Bool = false // New property to manage session state
    
    // Translation-related properties
    private var translationCache: [String: String] = [:]
    private var lastTranslationRequest: Date?
    private let translationCooldown: TimeInterval = 5.0 // Delay after audio playback
    private let postPlaybackDelay: TimeInterval = 2.0 // Audio player for TTS
    private var audioPlayer: AVAudioPlayer?
    
    init(openAIService: OpenAIService) {
        self.openAIService = openAIService
    }
    
    func startRecording() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            currentAudioFileURL = createUniqueAudioFileURL()
            let settings = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1, // Changed to mono for better transcription
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioRecorder = try AVAudioRecorder(url: currentAudioFileURL!, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            isRecording = true
            debugInfo = "Recording started"
            startUpdatingAudioLevels()
        } catch {
            debugInfo = "Failed to start recording: \(error.localizedDescription)"
            print(debugInfo)
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        levelUpdateTimer?.invalidate()
        debugInfo = "Recording stopped"
        transcribeAudio()
    }
    
    func endSession() {
        sessionActive = false
        stopRecording()
        debugInfo = "Session ended"
    }
    
    private func createUniqueAudioFileURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = dateFormatter.string(from: Date())
        return documentsPath.appendingPathComponent("recording_\(dateString).m4a")
    }
    
    private func startUpdatingAudioLevels() {
        levelUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let audioRecorder = self.audioRecorder, self.isRecording else { return }
            audioRecorder.updateMeters()
            let level = audioRecorder.averagePower(forChannel: 0)
            let normalizedLevel = CGFloat((level + 160) / 160) // Normalize the dB value to 0-1 range
            DispatchQueue.main.async {
                self.audioLevels.removeFirst()
                self.audioLevels.append(normalizedLevel)
                self.checkForPause(currentLevel: level)
            }
        }
    }
    
    private func checkForPause(currentLevel: Float) {
        if currentLevel < pauseThreshold {
            if pauseStartTime == nil {
                pauseStartTime = Date()
            }
        } else {
            pauseStartTime = nil
        }
        if let pauseStart = pauseStartTime, Date().timeIntervalSince(pauseStart) >= pauseDuration {
            stopRecording()
            pauseStartTime = nil
        }
        lastAudioLevel = currentLevel
    }
    
    private func transcribeAudio() {
        guard let audioFileURL = currentAudioFileURL, !isTranscribing else {
            debugInfo = "No audio file to transcribe or transcription in progress"
            return
        }
        if let lastTranscriptionTime = lastTranscriptionTime, Date().timeIntervalSince(lastTranscriptionTime) < 5.0 {
            return
        }
        isTranscribing = true
        do {
            let audioData = try Data(contentsOf: audioFileURL)
            let fileName = audioFileURL.lastPathComponent
            debugInfo = "Transcribing audio file: \(fileName), size: \(audioData.count) bytes"
            let parameters = SwiftOpenAI.AudioTranscriptionParameters(
                fileName: fileName,
                file: audioData,
                model: .whisperOne
            )
            Task {
                do {
                    let audioObject = try await self.openAIService.createTranscription(parameters: parameters)
                    DispatchQueue.main.async {
                        withAnimation {
                            self.transcriptions.append((text: audioObject.text, translation: ""))
                        }
                        self.debugInfo = "Transcription successful"
                        self.lastTranscriptionTime = Date()
                        self.translateTextIfNeeded(audioObject.text)
                        self.isTranscribing = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.debugInfo = "Error transcribing audio: \(error.localizedDescription)"
                        print(self.debugInfo)
                        self.isTranscribing = false
                    }
                }
            }
        } catch {
            debugInfo = "Error reading audio data: \(error.localizedDescription)"
            print(debugInfo)
            isTranscribing = false
        }
    }
    
    private func translateTextIfNeeded(_ text: String) {
        guard !text.isEmpty else { return }
        if let cachedTranslation = translationCache[text]?.components(separatedBy: "|||").first {
            if let index = transcriptions.firstIndex(where: { $0.text == text }) {
                withAnimation {
                    transcriptions[index].translation = cachedTranslation
                }
            }
            return
        }
        let now = Date()
        if let lastRequest = lastTranslationRequest, now.timeIntervalSince(lastRequest) < translationCooldown {
            return
        }
        lastTranslationRequest = now
        if isTranslating {
            return
        }
        isTranslating = true
        let messages: [ChatCompletionParameters.Message] = [
            .init(role: .system, content: .text("You are a helpful assistant. If the text is in Japanese, translate to English. If the text is in English, translate to Japanese.")),
            .init(role: .user, content: .text("Translate the following Japanese text to English, or English to Japanese, only translate do not output anything else: \(text)"))
        ]
        let parameters = ChatCompletionParameters(messages: messages, model: .gpt4o)
        Task {
            do {
                let result = try await openAIService.startChat(parameters: parameters)
                if let translatedContent = result.choices.first?.message.content {
                    DispatchQueue.main.async {
                        if let index = self.transcriptions.firstIndex(where: { $0.text == text }) {
                            withAnimation {
                                self.transcriptions[index].translation = translatedContent
                            }
                        }
                        let cacheEntry = "\(translatedContent)|||" + DateFormatter.iso8601.string(from: Date())
                        self.translationCache[text] = cacheEntry
                        self.isTranslating = false
                        // Generate audio for the translated text
                        self.generateSpeech(for: translatedContent)
                    }
                }
            } catch {
                print("Translation error: \(error)")
                DispatchQueue.main.async {
                    self.isTranslating = false
                }
            }
        }
    }
    
    private func generateSpeech(for text: String) {
        let parameters = AudioSpeechParameters(model: .tts1, input: text, voice: .shimmer)
        Task {
            do {
                let audioObject = try await openAIService.createSpeech(parameters: parameters)
                DispatchQueue.main.async {
                    self.playAudio(from: audioObject.output)
                }
            } catch {
                print("Error generating speech: \(error)")
            }
        }
    }
    
    private func playAudio(from data: Data) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth, .allowAirPlay])
            try audioSession.overrideOutputAudioPort(.speaker)
            try audioSession.setActive(true)
            // Initialize the audio player with the data
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self // Set the delegate to self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            // Handle errors
            print("Error playing audio: \(error.localizedDescription)")
        }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // No automatic restart
    }
}

struct WaveformView: View {
    let audioLevels: [CGFloat]
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 4) {
                ForEach(0..<audioLevels.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue)
                        .frame(width: geometry.size.width / CGFloat(audioLevels.count) - 4, height: audioLevels[index] * geometry.size.height)
                }
            }
        }
    }
}

struct AudioTranscriberView: View {
    @StateObject private var transcriber: AudioTranscriber
    
    init(openAIService: OpenAIService) {
        _transcriber = StateObject(wrappedValue: AudioTranscriber(openAIService: openAIService))
    }
    
    var body: some View {
        VStack {
            Text("Audio Transcriber")
                .font(.largeTitle)
            
            WaveformView(audioLevels: transcriber.audioLevels)
                .frame(height: 100)
                .padding()
            
            HStack {
                Button(action: {
                    if transcriber.isRecording {
                        transcriber.stopRecording()
                    } else {
                        transcriber.startRecording()
                    }
                }) {
                    Text(transcriber.isRecording ? "Stop Recording" : "Start Recording")
                        .padding()
                        .background(transcriber.isRecording ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                
                Button(action: {
                    transcriber.endSession()
                }) {
                    Text("End Session")
                        .padding()
                        .background(Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .padding()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(transcriber.transcriptions, id: \.text) { transcription in
                        VStack(alignment: .leading) {
                            Text(transcription.text)
                                .padding()
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(10)
                                .transition(.slide)
                            
                            Text(transcription.translation)
                                .padding()
                                .background(Color.yellow.opacity(0.1))
                                .cornerRadius(10)
                                .foregroundColor(.blue)
                                .transition(.slide)
                        }
                        .padding(.vertical, 5)
                    }
                }
                .padding()
            }
            
            Text(transcriber.debugInfo)
                .font(.caption)
                .foregroundColor(.gray)
                .padding()
        }
        .padding()
    }
}
