import Cocoa
import Foundation

public struct ClipboardHelper {
    @MainActor
    public static func copyFile(at url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
    
    @MainActor
    public static func copyImage(_ image: CGImage, fileURL: URL? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        var objects: [NSPasteboardWriting] = []
        let rep = NSBitmapImageRep(cgImage: image)
        let img = NSImage(size: NSSize(width: image.width, height: image.height))
        img.addRepresentation(rep)
        objects.append(img)
        
        if let url = fileURL {
            objects.append(url as NSURL)
        }
        
        pasteboard.writeObjects(objects)
        if let pngData = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(pngData, forType: .png)
        }
    }
}
