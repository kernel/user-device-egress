// Local QR generation using macOS frameworks; never send invitations to a QR website.
import AppKit
import CoreImage.CIFilterBuiltins
import Foundation

struct Invitation: Decodable { let url: String }
let invitation = try JSONDecoder().decode(Invitation.self, from: FileHandle.standardInput.readDataToEndOfFile())
guard CommandLine.arguments.count == 2 else { fatalError("Supply the PNG output path") }
let filter = CIFilter.qrCodeGenerator()
filter.message = Data(invitation.url.utf8)
filter.correctionLevel = "M"
guard let qr = filter.outputImage else { fatalError("QR generation failed") }
let border = qr.extent.insetBy(dx: -4, dy: -4)
let white = CIImage(color: CIColor.white).cropped(to: border)
let framed = qr.composited(over: white).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
guard let cg = CIContext().createCGImage(framed, from: framed.extent),
      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { fatalError("PNG generation failed") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
