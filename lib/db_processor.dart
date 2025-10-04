import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DBHelper {
  // Copy an asset DB file to device (if not already copied) and return path
  static Future<String> initDb(String assetName) async {
    final dbDir = await getDatabasesPath();
    final path = join(dbDir, assetName);

    if (!await File(path).exists()) {
      final data = await rootBundle.load("assets/$assetName");
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await File(path).writeAsBytes(bytes, flush: true);
    }
    return path;
  }
}

class DBProcessor {
  final Map<String, String> _verseMap = {}; // key: "Gen 1:1", value: verse text
  final Map<String, String> _strongDataCache = {}; // cache for Thayer/BDB data

  /// Call once at app start to ensure DB files copied and txt loaded.
  Future<void> init() async {
    // ensure DB files are copied (won't re-copy if present)
    await DBHelper.initDb("kjv.db");
    await DBHelper.initDb("bdb.sqlite");
    await DBHelper.initDb("thayer.sqlite");

    // load kjvteleng.txt into _verseMap
    await _loadTextFile("assets/kjvteleng.txt");
  }

  Future<void> _loadTextFile(String assetPath) async {
    _verseMap.clear();
    final content = await rootBundle.loadString(assetPath);
    // expect lines like: Gen 1:1: <verse text>
    final regex = RegExp(r'^([1-3]?[A-Za-z]{2,3}\s+\d+:\d+):\s*(.*)$');
    for (var line in LineSplitter.split(content)) {
      final m = regex.firstMatch(line);
      if (m != null) {
        final ref = m.group(1)!.trim(); // "Gen 1:1"
        final text = m.group(2)!.trim();
        _verseMap[ref] = text;
      }
    }
  }

  /// 1) Search all occurrences of `word` (full or partial from first character)
  ///    inside Bible.Scripture and return the set of Strong numbers (H###/G###)
  Future<Set<String>> getStrongNumbersForWord(String word) async {
    final path = await DBHelper.initDb("kjv.db");
    final db = await openDatabase(path, readOnly: true);

    final rows = await db.query("Bible", columns: ["Scripture"]);
    await db.close();

    final lowerWord = word.toLowerCase();
    final Set<String> strongs = {};

    // pattern to find H### or G### inside an HTML/tag: we will search inside tags
    final strongTagPattern = RegExp(
      r'<[^>]*?([HG]\d+)[^>]*?>',
      caseSensitive: false,
    );

    for (var row in rows) {
      final scripture = row['Scripture'].toString();
      final scriptureLower = scripture.toLowerCase();

      // partial match from first character of a token: \b + word
      final regexWord = RegExp(
        r'\b' + RegExp.escape(lowerWord),
        caseSensitive: false,
      );

      for (var m in regexWord.allMatches(scriptureLower)) {
        // use the index in lower-case to get corresponding substring in original
        final after = scripture.substring(m.end);
        final sn = strongTagPattern.firstMatch(after);
        if (sn != null && sn.groupCount >= 1) {
          final s = sn.group(1)!; // "H430" or "G2316"
          strongs.add(s);
        } else {
          // fallback: maybe the scripture contains bare H123 (rare). Check immediate text
          final barePattern = RegExp(r'\b([HG]\d+)\b', caseSensitive: false);
          final bareMatch = barePattern.firstMatch(after);
          if (bareMatch != null) strongs.add(bareMatch.group(1)!);
        }
      }
    }

    return strongs;
  }

  /// 2 & 4) For each strong number, find all verses in Bible containing it and
  /// return a map: strong -> { precedingWord -> [ "BookT Chapter:Verse", ... ] }
  Future<Map<String, Map<String, List<String>>>>
  getWordReferencesForStrongNumbers(Set<String> strongNumbers) async {
    final path = await DBHelper.initDb("kjv.db");
    final db = await openDatabase(path, readOnly: true);

    final Map<String, Map<String, List<String>>> results = {};

    for (var strong in strongNumbers) {
      final rows = await db.query(
        "Bible",
        columns: ["BookT", "Chapter", "Verse", "Scripture"],
        where: "Scripture LIKE ?",
        whereArgs: ['%$strong%'],
      );

      final Map<String, List<String>> wordMap = {};

      for (var row in rows) {
        final scripture = row["Scripture"].toString();
        final bookT = row["BookT"].toString();
        final chapter = row["Chapter"].toString();
        final verse = row["Verse"].toString();
        final reference = "$bookT $chapter:$verse"; // BookT Chapter:Verse

        // find the word immediately preceding the tag that contains our strong number
        // e.g., "... God<WH430> ..." -> capture "God"
        final regex = RegExp(
          r'(\S+)\s*<[^>]*?' + RegExp.escape(strong) + r'[^>]*?>',
          caseSensitive: false,
        );
        final matches = regex.allMatches(scripture);

        for (var m in matches) {
          final preceding = m.group(1);
          if (preceding != null && preceding.trim().isNotEmpty) {
            final key = preceding.trim();
            wordMap.putIfAbsent(key, () => []);
            if (!wordMap[key]!.contains(reference)) {
              wordMap[key]!.add(reference);
            }
          }
        }

        // fallback: if no tag form, handle bare ...WORD H123 ... (less common)
        if (!wordMap.containsKey(RegExp(r'.').pattern)) {
          // no-op; already handled above
        }
      }

      results[strong] = wordMap;
    }

    await db.close();
    return results;
  }

  /// 3) Get "data" field from relevant dictionary DB for the strong number
  ///    strong is like "H430" or "G2316"
  Future<String?> getStrongData(String strong) async {
    if (_strongDataCache.containsKey(strong)) return _strongDataCache[strong];

    final dbFile = strong.toUpperCase().startsWith('H')
        ? 'bdb.sqlite'
        : 'thayer.sqlite';
    final path = await DBHelper.initDb(dbFile);
    final db = await openDatabase(path, readOnly: true);

    // dictionary.word should match e.g. H430 or G2316
    final rows = await db.query(
      "dictionary",
      columns: ["data"],
      where: "word = ?",
      whereArgs: [strong],
      limit: 1,
    );
    await db.close();

    if (rows.isNotEmpty) {
      var data = rows.first["data"].toString();
      _strongDataCache[strong] = data;
      data = cleanStrongData(data);
      print(data);
      return data;
    }
    return null;
  }

  ///function to clean data from bdm/thayer
  String cleanStrongData(String htmlString) {
    if (htmlString.isEmpty) return "";

    // Replace paragraph tags with newlines
    String text = htmlString.replaceAll(RegExp(r'</p>|<p>'), '\n');

    // Replace <li> with dash + space
    text = text.replaceAllMapped(RegExp(r'<li>(.*?)</li>', dotAll: true), (m) {
      return "- ${m.group(1)}\n";
    });

    // Remove all other tags like <strong>, <ol>, <a>, etc.
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');

    // Collapse multiple newlines into max 2
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    // Trim leading/trailing whitespace
    return text.trim();
  }

  /// 5) Return a map of reference -> verse text (from loaded kjvteleng.txt)
  ///     Expects refs like "Gen 1:1"
  Future<Map<String, String>> getVersesForReferences(List<String> refs) async {
    final Map<String, String> out = {};
    for (var r in refs) {
      if (_verseMap.containsKey(r)) {
        out[r] = _verseMap[r]!;
      } else {
        // try alternative: sometimes we stored keys trimmed; make sure to try trimming
        final key = r.trim();
        if (_verseMap.containsKey(key)) out[r] = _verseMap[key]!;
      }
    }
    return out;
  }
}
