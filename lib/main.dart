import 'package:flutter/material.dart';
import 'db_processor.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Strong Search',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MyHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final DBProcessor _db = DBProcessor();
  final TextEditingController _controller = TextEditingController();

  bool _ready = false;

  /// Map: definitionData -> (precedingWord -> [refs])
  Map<String, Map<String, List<String>>> _results = {};

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    await _db.init(); // copies DBs and loads kjvteleng.txt into processor
    setState(() => _ready = true);
  }

  Future<void> _onSearch() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;

    // 1) find strong numbers for the word (partial from first char)
    final strongNumbers = await _db.getStrongNumbersForWord(input);

    if (strongNumbers.isEmpty) {
      setState(() => _results = {});
      return;
    }

    // 2) get for each strong the word->refs map
    final strongToWordRefs = await _db.getWordReferencesForStrongNumbers(
      strongNumbers,
    );

    // 3) for each strong, fetch dictionary data (thayer or bdb) and group by data
    final Map<String, Map<String, List<String>>> grouped = {};

    for (var strong in strongToWordRefs.keys) {
      final data =
          await _db.getStrongData(strong) ??
          strong; // fallback to strong itself

      // ensure map exists
      grouped.putIfAbsent(data, () => <String, List<String>>{});

      final Map<String, List<String>> wordMap = strongToWordRefs[strong]!;

      // merge wordMap into grouped[data], avoiding duplicates
      for (var w in wordMap.keys) {
        grouped[data]!.putIfAbsent(w, () => <String>[]);
        for (var ref in wordMap[w]!) {
          if (!grouped[data]![w]!.contains(ref)) grouped[data]![w]!.add(ref);
        }
      }
    }

    setState(() {
      _results = grouped;
    });
  }

  Color _tileColorFor(String key) {
    // deterministic color per key
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.indigo,
      Colors.brown,
    ];
    final idx = key.hashCode.abs() % colors.length;
    return colors[idx].withAlpha(220);
  }

  Future<void> _onShowPopup(
    String definitionData,
    String word,
    List<String> refs,
  ) async {
    // Now we ignore definitionData and use only word + verses.
    final versesMap = await _db.getVersesForReferences(refs);

    final List<Widget> children = [];
    for (var ref in refs) {
      print(refs);
      final raw = versesMap[ref] ?? "";
      print(raw);
      // Clean tags and Strong numbers
      var clean = raw.replaceAll(RegExp(r'<[^>]+>'), ' ');
      clean = clean.replaceAll(
        RegExp(r'\b[HG]\d+\b', caseSensitive: false),
        ' ',
      );
      clean = clean.replaceAll(RegExp(r'\s+'), ' ').trim();

      final span = _highlightWordInText(clean, word);

      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ref, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              RichText(text: span),
            ],
          ),
        ),
      );
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        // title is now the clicked word, not dictionary data
        title: Text(word, style: const TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(child: Column(children: children)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  // Returns a TextSpan where every occurrence of `word` (case-insensitive) is styled blue+underline.
  TextSpan _highlightWordInText(String text, String word) {
    if (word.isEmpty || text.isEmpty)
      return TextSpan(
        text: text,
        style: const TextStyle(color: Colors.black),
      );

    final pattern = RegExp(RegExp.escape(word), caseSensitive: false);
    final matches = pattern.allMatches(text);

    if (matches.isEmpty)
      return TextSpan(
        text: text,
        style: const TextStyle(color: Colors.black),
      );

    final List<TextSpan> spans = [];
    int last = 0;

    for (var m in matches) {
      if (m.start > last) {
        spans.add(
          TextSpan(
            text: text.substring(last, m.start),
            style: const TextStyle(color: Colors.black),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: text.substring(m.start, m.end),
          style: const TextStyle(
            color: Colors.blue,
            decoration: TextDecoration.underline,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      last = m.end;
    }
    if (last < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(last),
          style: const TextStyle(color: Colors.black),
        ),
      );
    }

    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Strong Search")),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          decoration: const InputDecoration(
                            hintText: "Enter word (partial from first char ok)",
                          ),
                          onSubmitted: (_) => _onSearch(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _onSearch,
                        child: const Text("Search"),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _results.isEmpty
                        ? const Center(
                            child: Text("Type a word and press Search"),
                          )
                        : SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: _results.entries.map((entry) {
                                final definitionData = entry.key;
                                final wordMap = entry.value;
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      definitionData,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: wordMap.entries.map((we) {
                                        final word = we.key;
                                        final refs = we.value;
                                        return GestureDetector(
                                          onTap: () => _onShowPopup(
                                            definitionData,
                                            word,
                                            refs,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.all(8),
                                            decoration: BoxDecoration(
                                              color: _tileColorFor(word),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  word,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  refs.join("; "),
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                );
                              }).toList(),
                            ),
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
