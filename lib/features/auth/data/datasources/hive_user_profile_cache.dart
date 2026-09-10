import 'dart:convert';

import 'package:hive/hive.dart';

import '../../domain/entities/user.dart';
import '../../domain/repositories/user_profile_cache.dart';

final class HiveUserProfileCache implements UserProfileCache {
  static const String boxName = 'auth_box';
  static const String currentUserKey = 'current_user';

  @override
  Future<User?> read() async {
    final value = (await Hive.openBox<dynamic>(boxName)).get(currentUserKey);
    if (value == null) return null;
    if (value is! String) {
      throw const FormatException('Cached user is not encoded JSON.');
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      throw const FormatException('Cached user JSON is not an object.');
    }
    return User.fromJson(Map<String, dynamic>.from(decoded));
  }

  @override
  Future<void> write(User user) async {
    await (await Hive.openBox<dynamic>(boxName)).put(
      currentUserKey,
      jsonEncode(user.toJson()),
    );
  }

  @override
  Future<void> delete() async {
    await (await Hive.openBox<dynamic>(boxName)).delete(currentUserKey);
  }
}
