import UIKit

/// Minimal async image loader for the music picker's per-row artwork —
/// deliberately NOT Kingfisher/SDWebImage: both only show up as
/// transitive Pods in Podfile.lock (pulled in by some other dependency,
/// never declared directly in the Podfile or imported anywhere in this
/// target), so importing them from app code isn't guaranteed to resolve.
/// A tiny URLSession + NSCache loader avoids that risk entirely.
enum RemoteImageLoader {
  private static let cache = NSCache<NSString, UIImage>()
  private static let session = URLSession(configuration: .default)

  static func load(_ urlString: String, into imageView: UIImageView) {
    imageView.image = nil
    guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
    let key = urlString as NSString
    if let cached = cache.object(forKey: key) {
      imageView.image = cached
      return
    }
    imageView.currentImageURLString = urlString
    session.dataTask(with: url) { data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      cache.setObject(image, forKey: key)
      DispatchQueue.main.async {
        // Guards against a recycled table cell: only apply if this image
        // view hasn't already been reassigned to a different row's URL
        // while the request was in flight.
        guard imageView.currentImageURLString == urlString else { return }
        imageView.image = image
      }
    }.resume()
  }
}

private enum RemoteImageLoaderAssociatedKeys {
  static var urlKey: UInt8 = 0
}

private extension UIImageView {
  var currentImageURLString: String? {
    get { objc_getAssociatedObject(self, &RemoteImageLoaderAssociatedKeys.urlKey) as? String }
    set { objc_setAssociatedObject(self, &RemoteImageLoaderAssociatedKeys.urlKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
  }
}
