// Copyright QuietStart contributors. SPDX-License-Identifier: MIT
//
// 数据模型 —— 与服务端 API 契约一一对应（见 docs/SERVER-API.md）。
//
// 刻意手写 fromJson 而不引入 freezed / json_serializable：
//   · 仓库里已有一个 4,551 行生成代码的教训
//   · 鸿蒙工具链（Dart 2.19.6）下代码生成的版本约束更麻烦
// 这些模型字段不多，手写成本低于生成链的维护成本。

/// 一个 HAP 附件。
class HapAsset {
  HapAsset({
    required this.name,
    required this.size,
    required this.sha256,
    required this.url,
    required this.mirrorUrls,
    this.bundleName = '',
    this.versionCode = 0,
    this.versionName = '',
    this.minApi = 0,
  });

  final String name;
  final int size;
  final String sha256;

  /// GitHub 原始地址
  final String url;

  /// 镜像候选项（客户端并行竞速用），末项为直连兜底
  final List<String> mirrorUrls;

  final String bundleName;
  final int versionCode;
  final String versionName;
  final int minApi;

  /// 人类可读体积
  String get sizeText {
    if (size <= 0) return '未知';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(size / 1073741824).toStringAsFixed(2)} GB';
  }

  factory HapAsset.fromJson(Map<String, dynamic> j) => HapAsset(
        name: (j['name'] ?? '') as String,
        size: (j['size'] ?? 0) as int,
        sha256: (j['sha256'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        mirrorUrls: ((j['mirror_urls'] ?? []) as List).cast<String>(),
        bundleName: (j['bundle_name'] ?? '') as String,
        versionCode: (j['version_code'] ?? 0) as int,
        versionName: (j['version_name'] ?? '') as String,
        minApi: (j['min_api'] ?? 0) as int,
      );
}

/// 一个 release。
class AppRelease {
  AppRelease({
    required this.tag,
    required this.name,
    required this.body,
    required this.publishedAt,
    required this.prerelease,
    required this.htmlUrl,
    required this.assets,
  });

  final String tag;
  final String name;
  final String body;
  final String publishedAt;
  final bool prerelease;
  final String htmlUrl;
  final List<HapAsset> assets;

  /// 只有含 HAP 的 release 才可安装
  List<HapAsset> get installableAssets =>
      assets.where((a) => a.name.toLowerCase().endsWith('.hap')).toList();

  bool get hasHap => installableAssets.isNotEmpty;

  String get dateText {
    if (publishedAt.length < 10) return publishedAt;
    return publishedAt.substring(0, 10);
  }

  factory AppRelease.fromJson(Map<String, dynamic> j) => AppRelease(
        tag: (j['tag'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        body: (j['body'] ?? '') as String,
        publishedAt: (j['published_at'] ?? '') as String,
        prerelease: (j['prerelease'] ?? false) as bool,
        htmlUrl: (j['html_url'] ?? '') as String,
        assets: ((j['assets'] ?? []) as List)
            .map((e) => HapAsset.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 应用列表项 / 详情共用的模型。
class StoreApp {
  StoreApp({
    required this.id,
    required this.repo,
    required this.owner,
    required this.name,
    required this.displayName,
    required this.summary,
    required this.description,
    required this.iconUrl,
    required this.category,
    required this.tags,
    required this.stars,
    required this.verified,
    required this.featured,
    required this.releasesCount,
    this.latestTag = '',
    this.latestName = '',
    this.latestPublishedAt = '',
    this.downloads = 0,
    this.publisherName = '',
    this.ratingAverage = 0,
    this.ratingCount = 0,
  });

  final int id;
  final String repo;
  final String owner;
  final String name;
  final String displayName;
  final String summary;
  final String description;

  /// 相对路径（`/api/v1/apps/{id}/icon`），由 ApiClient 补全为绝对地址
  final String iconUrl;

  final String category;
  final List<String> tags;
  final int stars;
  final bool verified;
  final bool featured;
  final int releasesCount;

  final String latestTag;
  final String latestName;
  final String latestPublishedAt;
  final int downloads;
  final String publisherName;
  final double ratingAverage;
  final int ratingCount;

  String get latestDateText =>
      latestPublishedAt.length < 10 ? latestPublishedAt : latestPublishedAt.substring(0, 10);

  factory StoreApp.fromJson(Map<String, dynamic> j) {
    final latest = j['latest'];
    return StoreApp(
      id: (j['id'] ?? 0) as int,
      repo: (j['repo'] ?? '') as String,
      owner: (j['owner'] ?? '') as String,
      name: (j['name'] ?? '') as String,
      displayName: (j['display_name'] ?? j['name'] ?? '') as String,
      summary: (j['summary'] ?? '') as String,
      description: (j['description'] ?? '') as String,
      iconUrl: (j['icon_url'] ?? '') as String,
      category: (j['category'] ?? '') as String,
      tags: ((j['tags'] ?? []) as List).cast<String>(),
      stars: (j['stars'] ?? 0) as int,
      verified: (j['verified'] ?? false) as bool,
      featured: (j['featured'] ?? false) as bool,
      releasesCount: (j['releases_count'] ?? 0) as int,
      latestTag: latest is Map ? (latest['tag'] ?? '') as String : '',
      latestName: latest is Map ? (latest['name'] ?? '') as String : '',
      latestPublishedAt:
          latest is Map ? (latest['published_at'] ?? '') as String : '',
      downloads: (j['downloads'] ?? 0) as int,
      publisherName: (j['publisher_name'] ?? '') as String,
      ratingAverage: ((j['rating'] is Map ? j['rating']['average'] : 0) ?? 0).toDouble(),
      ratingCount: ((j['rating'] is Map ? j['rating']['count'] : 0) ?? 0) as int,
    );
  }
}

class AppReview {
  AppReview({required this.displayName, required this.stars,
    required this.body, required this.updatedAt, this.avatarUrl = ''});

  final String displayName;
  final int stars;
  final String body;
  final int updatedAt;
  final String avatarUrl;

  factory AppReview.fromJson(Map<String, dynamic> j) => AppReview(
    displayName: (j['display_name'] ?? '') as String,
    stars: (j['stars'] ?? 0) as int,
    body: (j['body'] ?? '') as String,
    updatedAt: (j['updated_at'] ?? 0) as int,
    avatarUrl: (j['avatar_url'] ?? '') as String,
  );
}

/// 分页结果。
class Paged<T> {
  Paged({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  final List<T> items;
  final int total;
  final int page;
  final int pageSize;

  bool get hasMore => page * pageSize < total;
}
