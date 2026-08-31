import Cocoa
import FlutterMacOS
import AVFoundation
import CoreImage

class CameraHandler: NSObject, AVCapturePhotoCaptureDelegate {
    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var completionHandler: ((Data?) -> Void)?
    private var currentFilter: String = "none"
    private let ciContext = CIContext()
    
    func setFilter(_ filter: String) {
        self.currentFilter = filter
        print("🎨 Filter set to: \(filter)")
    }
    
    func checkCameraPermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("📹 Camera permission status: \(status.rawValue)")
        return status == .authorized
    }
    
    func requestCameraPermission(completion: @escaping (Bool) -> Void) {
        print("📹 Requesting camera permission...")
        AVCaptureDevice.requestAccess(for: .video) { granted in
            print("📹 Permission granted: \(granted)")
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    func takePicture(completion: @escaping (Data?) -> Void) {
        print("📸 Taking picture with filter: \(currentFilter)")
        self.completionHandler = completion
        
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        guard status == .authorized else {
            print("❌ Camera permission not granted")
            completion(nil)
            return
        }
        
        captureSession = AVCaptureSession()
        guard let captureSession = captureSession else {
            completion(nil)
            return
        }
        
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo
        
        guard let videoDevice = AVCaptureDevice.default(for: .video),
              let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoDeviceInput) else {
            print("❌ Cannot access camera device")
            completion(nil)
            return
        }
        
        captureSession.addInput(videoDeviceInput)
        
        photoOutput = AVCapturePhotoOutput()
        guard let photoOutput = photoOutput,
              captureSession.canAddOutput(photoOutput) else {
            print("❌ Cannot add photo output")
            completion(nil)
            return
        }
        
        captureSession.addOutput(photoOutput)
        captureSession.commitConfiguration()
        
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
            Thread.sleep(forTimeInterval: 0.5)
            
            DispatchQueue.main.async {
                let settings = AVCapturePhotoSettings()
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        captureSession?.stopRunning()
        
        if let error = error {
            print("❌ Error capturing photo: \(error.localizedDescription)")
            completionHandler?(nil)
            return
        }
        
        guard let imageData = photo.fileDataRepresentation(),
              let ciImage = CIImage(data: imageData) else {
            print("❌ Could not get image data")
            completionHandler?(nil)
            return
        }
        
        // Apply filter
        let filteredImage = applyFilter(to: ciImage, filter: currentFilter)
        
        // Convert to JPEG
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let jpegData = ciContext.jpegRepresentation(
                of: filteredImage,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
              ) else {
            print("❌ Could not convert to JPEG")
            completionHandler?(nil)
            return
        }
        
        print("✅ Photo captured with filter '\(currentFilter)': \(jpegData.count) bytes")
        completionHandler?(jpegData)
    }
    
    private func applyFilter(to image: CIImage, filter: String) -> CIImage {
        switch filter {
        case "smooth":
            if let filter = CIFilter(name: "CIGaussianBlur") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(2.0, forKey: kCIInputRadiusKey)
                if let output = filter.outputImage {
                    return output.cropped(to: image.extent)
                }
            }
            
        case "brightness":
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(0.3, forKey: kCIInputBrightnessKey)
                filter.setValue(1.1, forKey: kCIInputSaturationKey)
                if let output = filter.outputImage {
                    return output
                }
            }
            
        case "grayscale":
            if let filter = CIFilter(name: "CIPhotoEffectMono") {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let output = filter.outputImage {
                    return output
                }
            }
            
        case "vintage":
            if let filter = CIFilter(name: "CISepiaTone") {
                filter.setValue(image, forKey: kCIInputImageKey)
                filter.setValue(0.8, forKey: kCIInputIntensityKey)
                if let output = filter.outputImage {
                    if let vignetteFilter = CIFilter(name: "CIVignette") {
                        vignetteFilter.setValue(output, forKey: kCIInputImageKey)
                        vignetteFilter.setValue(2.0, forKey: kCIInputIntensityKey)
                        if let finalOutput = vignetteFilter.outputImage {
                            return finalOutput
                        }
                    }
                    return output
                }
            }
            
        default: // "none"
            return image
        }
        
        return image
    }
}

@main
class AppDelegate: FlutterAppDelegate {
    private var cameraHandler: CameraHandler?
    
    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    override func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 App launched")
        
        let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
        let cameraChannel = FlutterMethodChannel(
            name: "com.example.photobooth/camera",
            binaryMessenger: controller.engine.binaryMessenger
        )
        
        cameraHandler = CameraHandler()
        print("✅ Camera handler initialized")
        
        cameraChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            print("📞 Method called: \(call.method)")
            
            guard let self = self, let handler = self.cameraHandler else {
                print("❌ Camera handler not available")
                result(FlutterError(code: "UNAVAILABLE",
                                   message: "Camera handler not available",
                                   details: nil))
                return
            }
            
            switch call.method {
            case "checkCameraPermission":
                let hasPermission = handler.checkCameraPermission()
                result(hasPermission)
                
            case "requestCameraPermission":
                handler.requestCameraPermission { granted in
                    result(granted)
                }
                
            case "setFilter":
                if let args = call.arguments as? [String: Any],
                   let filter = args["filter"] as? String {
                    handler.setFilter(filter)
                    result(nil)
                } else {
                    result(FlutterError(code: "INVALID_ARGUMENT",
                                       message: "Filter name required",
                                       details: nil))
                }
                
            case "takePicture":
                handler.takePicture { imageData in
                    if let data = imageData {
                        print("✅ Returning image data to Flutter: \(data.count) bytes")
                        result(FlutterStandardTypedData(bytes: data))
                    } else {
                        print("❌ No image data to return")
                        result(FlutterError(code: "CAPTURE_FAILED",
                                           message: "Failed to capture photo",
                                           details: nil))
                    }
                }
                
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}