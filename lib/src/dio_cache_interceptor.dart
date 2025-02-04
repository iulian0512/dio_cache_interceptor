import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_cache_interceptor/src/model/cache_control.dart';
import 'package:dio_cache_interceptor/src/util/contants.dart';
import 'package:dio_cache_interceptor/src/util/http_date.dart';

import './model/cache_response.dart';
import './store/cache_store.dart';
import 'model/cache_options.dart';
import 'util/content_serialization.dart';
import 'util/response_extension.dart';

/// Cache interceptor
class DioCacheInterceptor extends Interceptor {
  static const String _getMethodName = 'GET';

  final CacheOptions _options;
  final CacheStore _store;

  DioCacheInterceptor({required CacheOptions options})
      : assert(options.store != null),
        _options = options,
        _store = options.store!;

  @override
  void onRequest(
    RequestOptions request,
    RequestInterceptorHandler handler,
  ) async {
    if (_shouldSkipRequest(request)) {
      handler.next(request);
      return;
    }

    final options = _getCacheOptions(request);

    if (options.policy != CachePolicy.refresh) {
      final cacheResp = await _getCacheResponse(request);
      if (cacheResp != null) {
        if (_shouldReturnCache(options, cacheResp)) {
          handler.resolve(cacheResp.toResponse(request, fromNetwork: false));
          return;
        }

        // Update request with cache directives
        _addCacheDirectives(request, cacheResp);
      }
    }

    handler.next(request);
  }

  @override
  void onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    if (_shouldSkipRequest(response.requestOptions) ||
        response.statusCode != 200) {
      handler.next(response);
      return;
    }

    final options = _getCacheOptions(response.requestOptions);
    final policy = options.policy;

    if (policy == CachePolicy.noCache) {
      // Delete previous potential cached response
      await _getCacheStore(options).delete(
        options.keyBuilder(response.requestOptions),
      );
    } else if (_hasCacheDirectives(response, policy: policy)) {
      // Cache response into store
      final cacheResp = await _buildCacheResponse(
        options.keyBuilder(response.requestOptions),
        options,
        response,
      );

      await _getCacheStore(options).set(cacheResp);

      response.extra.putIfAbsent(CacheResponse.cacheKey, () => cacheResp.key);
      response.extra.putIfAbsent(CacheResponse.fromNetwork, () => true);
    }

    handler.next(response);
  }

  @override
  void onError(
    DioError err,
    ErrorInterceptorHandler handler,
  ) async {
    if (_shouldSkipRequest(err.requestOptions, error: err)) {
      handler.next(err);
      return;
    }

    final errResponse = err.response;
    var returnResponse = false;

    if (errResponse?.statusCode == 304) {
      returnResponse = true;
    } else {
      // Check if we can return cache
      final options = _getCacheOptions(err.requestOptions);
      final hcoeExcept = options.hitCacheOnErrorExcept;

      if (hcoeExcept != null) {
        if (errResponse == null) {
          returnResponse = true;
        } else if (!hcoeExcept.contains(errResponse.statusCode)) {
          returnResponse = true;
        }
      }
    }

    if (returnResponse) {
      // Retrieve response from cache
      final response = await _getResponse(
        err.requestOptions,
        response: errResponse,
      );
      if (response != null) {
        handler.resolve(response);
        return;
      }
    }

    handler.next(err);
  }

  void _addCacheDirectives(RequestOptions request, CacheResponse response) {
    if (response.eTag != null) {
      request.headers[ifNoneMatchHeader] = response.eTag;
    }

    if (response.lastModified != null) {
      request.headers[ifModifiedSinceHeader] = response.lastModified;
    }
  }

  bool _hasCacheDirectives(Response response, {CachePolicy? policy}) {
    if (policy == CachePolicy.forceCache) {
      return true;
    }

    var result = response.headers[etagHeader] != null;
    result |= response.headers[lastModifiedHeader] != null;

    final cacheControl = CacheControl.fromHeader(
      response.headers[cacheControlHeader],
    );

    if (cacheControl != null) {
      result &= !(cacheControl.noStore ?? false);
    }

    return result;
  }

  bool _shouldReturnCache(CacheOptions options, CacheResponse cacheResp) {
    // Forced cache response
    if (options.policy == CachePolicy.forceCache) {
      return true;
    }

    return !cacheResp.isExpired();
  }

  CacheOptions _getCacheOptions(RequestOptions request) {
    return CacheOptions.fromExtra(request) ?? _options;
  }

  CacheStore _getCacheStore(CacheOptions options) {
    return options.store ?? _store;
  }

  bool _shouldSkipRequest(RequestOptions? request, {DioError? error}) {
    var result = error?.type == DioErrorType.cancel;
    result |= (request?.method.toUpperCase() != _getMethodName);
    return result;
  }

  Future<CacheResponse> _buildCacheResponse(
    String key,
    CacheOptions options,
    Response response,
  ) async {
    final content = await _encryptContent(
      options,
      await serializeContent(
        response.requestOptions.responseType,
        response.data,
      ),
    );

    final headers = await _encryptContent(
      options,
      utf8.encode(jsonEncode(response.headers.map)),
    );

    final dateStr = response.headers[dateHeader]?.first;
    DateTime? date;
    if (dateStr != null) {
      try {
        date = HttpDate.parse(dateStr);
      } catch (_) {
        // Invalid date format => ignored
      }
    }

    final expiresDateStr = response.headers[expiresHeader]?.first;
    DateTime? httpExpiresDate;
    if (expiresDateStr != null) {
      try {
        httpExpiresDate = HttpDate.parse(expiresDateStr);
      } catch (_) {
        // Invalid date format => meaning something already expired
        httpExpiresDate = DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true);
      }
    }

    final checkedMaxStale = options.maxStale;

    return CacheResponse(
      cacheControl: CacheControl.fromHeader(
        response.headers[cacheControlHeader],
      ),
      content: content,
      date: date,
      eTag: response.headers[etagHeader]?.first,
      expires: httpExpiresDate,
      headers: headers,
      key: key,
      lastModified: response.headers[lastModifiedHeader]?.first,
      maxStale: checkedMaxStale != null
          ? DateTime.now().toUtc().add(checkedMaxStale)
          : null,
      priority: options.priority,
      responseDate: DateTime.now().toUtc(),
      url: response.requestOptions.uri.toString(),
    );
  }

  Future<CacheResponse?> _getCacheResponse(RequestOptions request) async {
    final options = _getCacheOptions(request);
    final cacheKey = options.keyBuilder(request);
    final result = await _getCacheStore(options).get(cacheKey);

    if (result != null) {
      result.content = await _decryptContent(options, result.content);
      result.headers = await _decryptContent(options, result.headers);
    }

    return result;
  }

  Future<Response?> _getResponse(
    RequestOptions request, {
    Response? response,
  }) async {
    final existing = await _getCacheResponse(request);
    final cacheResponse = existing?.toResponse(request);

    if (response != null && cacheResponse != null) {
      // Update cache header values
      cacheResponse.updateCacheHeaders(response);

      // Update store
      final options = _getCacheOptions(request);
      final updatedCache = await _buildCacheResponse(
        options.keyBuilder(request),
        options,
        cacheResponse,
      );
      await _getCacheStore(options).set(updatedCache);

      // return cached value with updated headers
      return updatedCache.toResponse(request, fromNetwork: true);
    }

    return cacheResponse;
  }

  Future<List<int>?> _decryptContent(CacheOptions options, List<int>? bytes) {
    final checkedCipher = options.cipher;
    if (bytes != null && checkedCipher != null) {
      return checkedCipher.decrypt(bytes);
    }

    return Future.value(bytes);
  }

  Future<List<int>?> _encryptContent(CacheOptions options, List<int>? bytes) {
    final checkedCipher = options.cipher;
    if (bytes != null && checkedCipher != null) {
      return checkedCipher.encrypt(bytes);
    }
    return Future.value(bytes);
  }
}
