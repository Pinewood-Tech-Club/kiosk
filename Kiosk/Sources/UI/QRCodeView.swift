import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let url: URL
    var size: CGFloat = 132

    var body: some View {
        Image(uiImage: Self.render(url.absoluteString))
            .interpolation(.none)
            .resizable()
            .frame(width: size, height: size)
            .padding(10)
            .background(.white, in: .rect(cornerRadius: 12))
            .accessibilityLabel("QR code for your receipt")
    }

    static func render(_ text: String) -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return UIImage() }
        return UIImage(cgImage: cgImage)
    }
}
