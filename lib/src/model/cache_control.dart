/// Cache-Control header subset representation
class CacheControl {
  /// How long the response can be used from the time it was requested (in seconds).
  /// https://tools.ietf.org/html/rfc7234#section-5.2.2.8
  final int? maxAge;

  /// 'public' / 'private'.
  /// https://tools.ietf.org/html/rfc7234#section-5.2.2.5
  final String? privacy;

  /// Must first submit a validation request to an origin server.
  /// https://tools.ietf.org/html/rfc7234#section-5.2.2.2
  final bool? noCache;

  /// Disallow cache, overriding any other directives (Etag, Last-Modified)
  /// https://tools.ietf.org/html/rfc7234#section-5.2.2.3
  final bool? noStore;

  /// Other attributes not parsed
  final List<String> other;

  CacheControl({
    this.maxAge,
    this.privacy,
    this.noCache = false,
    this.noStore = false,
    this.other = const [],
  });

  static CacheControl? fromHeader(List<String>? headerValues) {
    if (headerValues == null) return null;

    int? maxAge;
    String? privacy;
    bool? noCache;
    bool? noStore;
    final other = <String>[];

    for (var value in headerValues) {
      if (value == 'no-cache') {
        noCache = true;
      } else if (value == 'no-store') {
        noStore = true;
      } else if (value == 'public' || value == 'private') {
        privacy = value;
      } else if (value.startsWith('max-age')) {
        maxAge = int.tryParse(value.substring(value.indexOf('=') + 1));
      } else {
        other.add(value);
      }
    }

    return CacheControl(
      maxAge: maxAge,
      privacy: privacy,
      noCache: noCache,
      noStore: noStore,
      other: other,
    );
  }

  /// Serialize cache-control values
  String toHeader() {
    final values = <String>[
      maxAge != null ? 'max-age=$maxAge' : '',
      privacy ?? '',
      (noCache ?? false) ? 'no-cache' : '',
      (noStore ?? false) ? 'no-store' : '',
      ...other
    ];

    return values.join(', ');
  }
}
