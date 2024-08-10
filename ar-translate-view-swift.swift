import SwiftUI
import AVFoundation
import Vision
import SwiftOpenAI

struct ARTranslateView: View {
    @State private var recognizedText = ""
    @State private var translatedText = ""
    @State private var isPaused = false
    @State private var isAnalyzing = false
    @State private var showAnalysisPopup = false
    @State private var analysisResult = ""
    
    var body: some View {
        ZStack {
            CameraView(recognizedText: $recognizedText, translatedText: $translatedText, isPaused: $isPaused, isAnalyzing: $isAnalyzing, analysisResult: $analysisResult, showAnalysisPopup: $showAnalysisPopup)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                Spacer()
                VStack {
                    Text(translatedText)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)
                    
//                    Text(recognizedText)
//                        .foregroundColor(.white)
//                        .padding()
//                        .background(Color.black.opacity(0.7))
//                        .cornerRadius(10)
                }
                
                HStack {
                    Button(action: {
                        isPaused.toggle()
                    }) {
                        Text(isPaused ? "Resume" : "Pause")
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                    
                    Button(action: {
                        isAnalyzing = true
                    }) {
                        Text("Capture & Analyze")
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(10)
                    }
                    .disabled(isAnalyzing)
                }
                .padding()
            }
            .padding()
        }
        .sheet(isPresented: $showAnalysisPopup) {
            AnalysisPopupView(analysisResult: $analysisResult)
        }
    }
}

struct AnalysisPopupView: View {
    @Binding var analysisResult: String
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack {
            Text("Image Analysis Result")
                .font(.headline)
                .padding()
            
            ScrollView {
                Text(analysisResult)
                    .padding()
            }
            
            Button("Close") {
                presentationMode.wrappedValue.dismiss()
            }
            .padding()
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Binding var recognizedText: String
    @Binding var translatedText: String
    @Binding var isPaused: Bool
    @Binding var isAnalyzing: Bool
    @Binding var analysisResult: String
    @Binding var showAnalysisPopup: Bool
    
    func makeUIViewController(context: Context) -> CameraViewController {
        return CameraViewController(recognizedText: $recognizedText, translatedText: $translatedText, isPaused: $isPaused, isAnalyzing: $isAnalyzing, analysisResult: $analysisResult, showAnalysisPopup: $showAnalysisPopup)
    }
    
    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        uiViewController.updatePausedState(isPaused)
        uiViewController.updateAnalyzingState(isAnalyzing)
    }
}

class CameraViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Binding var recognizedText: String
    @Binding var translatedText: String
    @Binding var isPaused: Bool
    @Binding var isAnalyzing: Bool
    @Binding var analysisResult: String
    @Binding var showAnalysisPopup: Bool
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let openAIService: OpenAIService
    
    private var translationCache: [String: String] = [:]
    private var lastTranslationRequest: Date?
    private let translationCooldown: TimeInterval = 5 // 5 seconds cooldown
    private var cacheCleanupTimer: Timer?
    private var isTranslating = false
    
    init(recognizedText: Binding<String>, translatedText: Binding<String>, isPaused: Binding<Bool>, isAnalyzing: Binding<Bool>, analysisResult: Binding<String>, showAnalysisPopup: Binding<Bool>) {
        _recognizedText = recognizedText
        _translatedText = translatedText
        _isPaused = isPaused
        _isAnalyzing = isAnalyzing
        _analysisResult = analysisResult
        _showAnalysisPopup = showAnalysisPopup
        openAIService = OpenAIServiceFactory.service(apiKey: "")
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
        setupCacheCleanupTimer()
    }
    
    private func setupCamera() {
        captureSession.sessionPreset = .high
        
        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            return
        }
        
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        }
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer?.frame = view.bounds
        previewLayer?.videoGravity = .resizeAspectFill
        if let previewLayer = previewLayer {
            view.layer.addSublayer(previewLayer)
        }
        
        captureSession.startRunning()
    }
    
    func updatePausedState(_ paused: Bool) {
        if paused {
            captureSession.stopRunning()
        } else {
            captureSession.startRunning()
        }
    }
    
    func updateAnalyzingState(_ analyzing: Bool) {
        if analyzing {
            captureAndAnalyzeImage()
        }
    }
    
    private func setupCacheCleanupTimer() {
        cacheCleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.cleanupTranslationCache()
        }
    }
    
    private func cleanupTranslationCache() {
        let now = Date()
        translationCache = translationCache.filter { _, value in
            if let timestamp = value.components(separatedBy: "|||").last,
               let date = DateFormatter.iso8601.date(from: timestamp),
               now.timeIntervalSince(date) < 3600 { // Keep translations for 1 hour
                return true
            }
            return false
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isPaused, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        let request = VNRecognizeTextRequest { [weak self] (request, error) in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            self?.processTextObservations(observations)
        }
        
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP"]
        request.usesLanguageCorrection = false
        
        do {
            try requestHandler.perform([request])
        } catch {
            print(error)
        }
    }
    
    private func processTextObservations(_ observations: [VNRecognizedTextObservation]) {
        let recognizedStrings = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        
        let japaneseText = recognizedStrings.filter { containsJapaneseCharacters($0) }
        let fullJapaneseText = japaneseText.joined(separator: "\n")
        
        DispatchQueue.main.async {
            self.recognizedText = fullJapaneseText
            self.translateTextIfNeeded(fullJapaneseText)
        }
    }
    
    private func containsJapaneseCharacters(_ text: String) -> Bool {
        let japaneseRange = 0x3040...0x30FF
        let kanjiRange = 0x4E00...0x9FFF
        
        for scalar in text.unicodeScalars {
            let scalarValue = Int(scalar.value)
            if japaneseRange.contains(scalarValue) || kanjiRange.contains(scalarValue) {
                return true
            }
        }
        return false
    }
    
    private func translateTextIfNeeded(_ text: String) {
        guard !text.isEmpty else {
            self.translatedText = ""
            return
        }
        
        if let cachedTranslation = translationCache[text]?.components(separatedBy: "|||").first {
            self.translatedText = cachedTranslation
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
            .init(role: .system, content: .text("You are a helpful assistant that translates Japanese to English.")),
            .init(role: .user, content: .text("Translate the following Japanese text to English only translate do output anything else: \(text)"))
        ]
        
        let parameters = ChatCompletionParameters(messages: messages, model: .gpt4o)
        
        Task {
            do {
                let result = try await openAIService.startChat(parameters: parameters)
                if let translatedContent = result.choices.first?.message.content {
                    DispatchQueue.main.async {
                        self.translatedText = translatedContent
                        let cacheEntry = "\(translatedContent)|||" + DateFormatter.iso8601.string(from: Date())
                        self.translationCache[text] = cacheEntry
                        self.isTranslating = false
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
    
    private func captureAndAnalyzeImage() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        
        let settings = AVCapturePhotoSettings()
        let photoOutput = AVCapturePhotoOutput()
        
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

 extension CameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let imageData = photo.fileDataRepresentation() else {
            print("Error capturing photo: \(error?.localizedDescription ?? "Unknown error")")
            DispatchQueue.main.async {
                self.isAnalyzing = false
            }
            return
        }
        
        analyzeImage(imageData)
    }
    
    private func analyzeImage(_ imageData: Data) {
        let base64Image = imageData.base64EncodedString()
        let imageURL = "data:image/jpeg;base64,\(base64Image)"
        
        let prompt = "Analyze this image and describe what you see, focusing on any Japanese text or cultural elements present. Please Make your response Brief"
        let messageContent: [ChatCompletionParameters.Message.ContentType.MessageContent] = [
            .text(prompt),
            .imageUrl(.init(url: URL(string: imageURL)!))
        ]
        
        let parameters = ChatCompletionParameters(
            messages: [.init(role: .user, content: .contentArray(messageContent))],
            model: .gpt4o
        )
        
        Task {
            do {
                let result = try await openAIService.startChat(parameters: parameters)
                if let analysisContent = result.choices.first?.message.content {
                    DispatchQueue.main.async {
                        self.analysisResult = analysisContent
                        self.isAnalyzing = false
                        self.showAnalysisPopup = true
                    }
                }
            } catch {
                print("Image analysis error: \(error)")
                DispatchQueue.main.async {
                    self.isAnalyzing = false
                }
            }
        }
    }
}

extension DateFormatter {
    static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

struct ARTranslateView_Previews: PreviewProvider {
    static var previews: some View {
        ARTranslateView()
    }
}
