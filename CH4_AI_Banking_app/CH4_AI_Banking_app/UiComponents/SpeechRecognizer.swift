//
//  SpeechRecognizer.swift
//  CH4_AI_Banking_app
//
//  Wraps Apple's Speech framework to provide live, on-device speech-to-text
//  transcription. Streams partial results into `transcript` so the InputBar
//  can show text as the user speaks.
//

import Foundation
import Speech
import AVFoundation
import Observation

@MainActor
@Observable
final class SpeechRecognizer {
    
    // MARK: - Published State
    
    /// The live transcription text (partial → final).
    var transcript: String = ""
    
    /// Whether the recognizer is currently capturing audio.
    var isListening: Bool = false
    
    /// A user-facing error message, shown briefly then cleared.
    var errorMessage: String? = nil
    
    /// The current authorization status for speech recognition.
    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    
    // MARK: - Private State
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // MARK: - Authorization
    
    /// Requests microphone + speech authorization. Call once on appear.
    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if status != .authorized {
                    self?.errorMessage = "Speech recognition not authorized."
                }
            }
        }
    }
    
    // MARK: - Start / Stop
    
    /// Toggles listening on/off.
    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }
    
    /// Begins capturing audio and streaming it to the speech recognizer.
    func startListening() {
        // Reset any prior state
        stopListening()
        
        guard authorizationStatus == .authorized else {
            errorMessage = "Please allow speech recognition in Settings."
            return
        }
        
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognition is not available on this device."
            return
        }
        
        do {
            // Configure the audio session for recording
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Create the recognition request
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            
            // Prefer on-device recognition when available (faster, private)
            if speechRecognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            
            self.recognitionRequest = request
            
            // Start the recognition task
            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                    }
                    
                    if let error {
                        // Don't treat cancellation as an error
                        let nsError = error as NSError
                        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                            // User cancelled — not an error
                        } else if nsError.code != 1 { // Code 1 = no speech detected (normal)
                            self.errorMessage = "Recognition error: \(error.localizedDescription)"
                        }
                        self.stopListening()
                        return
                    }
                }
            }
            
            // Install an audio tap on the input node
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            
            isListening = true
            transcript = ""
            
        } catch {
            errorMessage = "Audio engine error: \(error.localizedDescription)"
            stopListening()
        }
    }
    
    /// Stops audio capture and finalizes any in-progress recognition.
    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        isListening = false
        
        // Deactivate audio session so other apps can use the mic
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
