import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

/* =========================
   퍼즐 모델 / 로더
========================= */
class SudokuPuzzle {
  final List<List<int>> puzzle;   // 0 = 빈칸
  final List<List<int>> solution; // 정답

  SudokuPuzzle({required this.puzzle, required this.solution});

  static List<List<int>> _parse81(String s) {
    assert(s.length == 81, '퍼즐/해답 문자열은 81글자여야 합니다.');
    final g = List.generate(9, (_) => List.filled(9, 0));
    for (int i = 0; i < 81; i++) {
      final r = i ~/ 9;
      final c = i % 9;
      g[r][c] = int.tryParse(s[i]) ?? 0;
    }
    return g;
  }

  factory SudokuPuzzle.fromStrings(String p, String s) =>
      SudokuPuzzle(puzzle: _parse81(p), solution: _parse81(s));
}

class SudokuRepo {
  static Map<String, dynamic>? _cache;

  static Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    final raw = await rootBundle.loadString('assets/puzzles.json');
    _cache = json.decode(raw) as Map<String, dynamic>;
  }

  /// difficulty: "상"|"중"|"하"  (UI의 수지/원석/콩이는 매핑해서 넘김)
  static Future<SudokuPuzzle> load(String difficulty, int number) async {
    await _ensureLoaded();
    final d = _cache![difficulty] as Map<String, dynamic>?;
    if (d == null) throw Exception('난이도($difficulty)를 찾을 수 없어요.');
    final item = d['$number'] as Map<String, dynamic>?;
    if (item == null) throw Exception('번호($number) 퍼즐이 없어요.');
    return SudokuPuzzle.fromStrings(item['puzzle'] as String, item['solution'] as String);
  }
}

/* =========================
   앱 상태
========================= */
class MyAppState extends ChangeNotifier {
  // 표시용 난이도 라벨
  String uiDifficulty = '콩이(쉬움)';
  int number = 1;

  // 로딩/에러
  bool loading = false;
  String? error;

  // 보드 상태
  List<List<int>> grid = List.generate(9, (_) => List.filled(9, 0));
  List<List<bool>> fixed = List.generate(9, (_) => List.filled(9, false));
  List<List<int>> solution = List.generate(9, (_) => List.filled(9, 0));
  int? selR, selC;

  // 메모(연필) 모드
  bool noteMode = false;
  // 각 셀마다 1~9 메모 숫자 집합
  List<List<Set<int>>> notes = List.generate(
    9,
    (_) => List.generate(9, (_) => <int>{}),
  );

  // UI 난이도 → JSON 키 매핑
  static const Map<String, String> difficultyMap = {
    '콩이(쉬움)': '하',
    '원석(보통)': '중',
    '수지(어려움)': '상',
  };

  // ===== 퍼즐 로딩 =====
  Future<void> loadPuzzle({String? uiDiff, int? num}) async {
    loading = true;
    error = null;
    if (uiDiff != null) uiDifficulty = uiDiff;
    if (num != null) number = num;
    notifyListeners();

    try {
      final key = difficultyMap[uiDifficulty]!;
      final p = await SudokuRepo.load(key, number);
      grid = p.puzzle.map((r) => List<int>.from(r)).toList();
      fixed = List.generate(9, (r) => List.generate(9, (c) => p.puzzle[r][c] != 0));
      solution = p.solution.map((r) => List<int>.from(r)).toList();
      selR = selC = null;
      // 메모 초기화
      notes = List.generate(9, (_) => List.generate(9, (_) => <int>{}));
      noteMode = false;
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void selectCell(int r, int c) {
    selR = r;
    selC = c;
    notifyListeners();
  }

  void inputNumber(int n) {
    if (selR == null || selC == null) return;
    final r = selR!, c = selC!;
    if (fixed[r][c]) return;

    if (noteMode) {
      // 메모 토글
      if (grid[r][c] != 0) return; // 값이 들어있으면 메모 안 받음
      if (notes[r][c].contains(n)) {
        notes[r][c].remove(n);
      } else {
        notes[r][c].add(n);
      }
    } else {
      // 실제 숫자 입력
      grid[r][c] = n;
      // 해당 칸 메모는 비우기
      notes[r][c].clear();
    }
    notifyListeners();
  }

  void clearCell() {
    if (selR == null || selC == null) return;
    final r = selR!, c = selC!;
    if (fixed[r][c]) return;

    if (noteMode) {
      // 메모 모드에서 X: 선택 칸 메모 모두 지우기
      notes[r][c].clear();
    } else {
      // 일반 모드에서 X: 값 지우기
      grid[r][c] = 0;
    }
    notifyListeners();
  }

  /// 현재 선택 칸에 정답 1칸 채우기
  void hintOne() {
    if (selR == null || selC == null) return;
    final r = selR!, c = selC!;
    if (fixed[r][c]) return;
    grid[r][c] = solution[r][c];
    notes[r][c].clear();
    notifyListeners();
  }

  /// 전체 보드가 정답과 동일한지
  bool isSolved() {
    for (int r = 0; r < 9; r++) {
      for (int c = 0; c < 9; c++) {
        if (grid[r][c] != solution[r][c]) return false;
      }
    }
    return true;
  }

  void toggleNoteMode() {
    noteMode = !noteMode;
    notifyListeners();
  }

  // ===== 중간저장/불러오기 =====
  static const _saveKey = 'sudoku_saved_v1';

  Future<void> saveProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'uiDifficulty': uiDifficulty,
      'number': number,
      'grid': grid,
      'fixed': fixed,
      'solution': solution,
      'selR': selR,
      'selC': selC,
      'noteMode': noteMode,
      'notes': notes
          .map((row) => row.map((s) => s.toList()..sort()).toList())
          .toList(), // Set<int> -> List<int>
    };
    await prefs.setString(_saveKey, json.encode(data));
  }

  Future<bool> loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_saveKey);
    if (raw == null) return false;
    try {
      final m = json.decode(raw) as Map<String, dynamic>;
      uiDifficulty = m['uiDifficulty'] as String;
      number = m['number'] as int;

      List<dynamic> _grid = m['grid'];
      grid = List.generate(9, (r) => List<int>.from(_grid[r] as List));

      List<dynamic> _fixed = m['fixed'];
      fixed = List.generate(9, (r) => List<bool>.from(_fixed[r] as List));

      List<dynamic> _sol = m['solution'];
      solution = List.generate(9, (r) => List<int>.from(_sol[r] as List));

      selR = m['selR'] as int?;
      selC = m['selC'] as int?;
      noteMode = m['noteMode'] as bool? ?? false;

      List<dynamic> _notes = m['notes'];
      notes = List.generate(
        9,
        (r) => List.generate(
          9,
          (c) => <int>{...(List<int>.from(_notes[r][c] as List))},
        ),
      );
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/* =========================
   앱(라우팅)
========================= */
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MyAppState(),
      child: MaterialApp(
        title: '송수지 스도쿠천재',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
        ),
        home: const LandingPage(),
      ),
    );
  }
}

/* =========================
   랜딩 페이지
========================= */
class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  final List<String> diffs = const ['콩이(쉬움)', '원석(보통)', '수지(어려움)'];
  String selected = '콩이(쉬움)';
  final TextEditingController numCtl = TextEditingController(text: '1');

  @override
  void dispose() {
    numCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<MyAppState>();
    final titleStyle = Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        );

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 원형 아이콘으로 쓰고 싶으면 CircleAvatar로 바꿔도 됨 (아래 옵션 참고)
                      Image.asset(
                        'assets/suji_kong.png',
                        width: 120,
                        height: 120,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          '송수지 스도쿠천재',
                          style: titleStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 32),

                  // 난이도 선택
                  Row(
                    children: [
                      const Text('난이도 선택'),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: selected,
                        items: diffs.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                        onChanged: (v) => setState(() => selected = v!),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 번호 선택
                  Row(
                    children: [
                      const Text('번호 선택 (1-999)'),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 120,
                        child: TextField(
                          controller: numCtl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: '예: 1',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),

                  // 입장하기
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: app.loading
                          ? null
                          : () async {
                              final n = int.tryParse(numCtl.text);
                              if (n == null || n < 1 || n > 999) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('번호는 1~999 사이의 정수로 입력하세요.')),
                                );
                                return;
                              }
                              await context.read<MyAppState>().loadPuzzle(uiDiff: selected, num: n);
                              if (!mounted) return;
                              if (app.error != null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(app.error!)),
                                );
                              } else {
                                Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const GamePage()),
                                );
                              }
                            },
                      child: app.loading
                          ? const SizedBox(
                              width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('입장하기'),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // (선택) 이전 저장 불러오기 단축버튼
                  OutlinedButton.icon(
                    onPressed: () async {
                      final ok = await context.read<MyAppState>().loadProgress();
                      if (!mounted) return;
                      if (ok) {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const GamePage()),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('저장된 진행 상태가 없습니다.')),
                        );
                      }
                    },
                    icon: const Icon(Icons.history),
                    label: const Text('이어서 하기(불러오기)'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/* =========================
   게임 페이지
========================= */
class GamePage extends StatelessWidget {
  const GamePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<MyAppState>();

    return Scaffold(
      appBar: AppBar(
        title: Text('${app.uiDifficulty} / ${app.number}'),
        actions: [
          // 메모 모드
          IconButton(
            tooltip: '메모(연필) 모드',
            icon: Icon(app.noteMode ? Icons.edit_note : Icons.edit),
            onPressed: () => context.read<MyAppState>().toggleNoteMode(),
          ),
          // 중간저장
          IconButton(
            tooltip: '중간저장',
            icon: const Icon(Icons.save_outlined),
            onPressed: () async {
              await context.read<MyAppState>().saveProgress();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('진행 상황을 저장했어요.')),
                );
              }
            },
          ),
          // 불러오기
          IconButton(
            tooltip: '불러오기',
            icon: const Icon(Icons.restore_outlined),
            onPressed: () async {
              final ok = await context.read<MyAppState>().loadProgress();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(ok ? '저장된 진행을 불러왔어요.' : '저장 내역이 없어요.')),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // 보드
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: _Board(),
                ),
              ),
            ),
          ),

          // 키패드 + 제출/힌트
          const _KeypadRow(),

          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/* =========================
   보드 위젯
========================= */
class _Board extends StatelessWidget {
  const _Board({super.key});

  Border _cellBorder(int r, int c, Color color) {
    final thickTop = r % 3 == 0;
    final thickLeft = c % 3 == 0;
    final thickRight = c == 8;
    final thickBottom = r == 8;
    return Border(
      top: BorderSide(width: thickTop ? 2.0 : 0.5, color: color),
      left: BorderSide(width: thickLeft ? 2.0 : 0.5, color: color),
      right: BorderSide(width: thickRight ? 2.0 : 0.5, color: color),
      bottom: BorderSide(width: thickBottom ? 2.0 : 0.5, color: color),
    );
  }

  Widget _notesGrid(Set<int> notes, TextStyle baseStyle) {
    // 3x3 작은 숫자 그리드
    final style = baseStyle.copyWith(fontSize: 10);
    final cells = List.generate(9, (i) {
      final n = i + 1;
      return Center(child: Text(notes.contains(n) ? '$n' : '', style: style));
    });

    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(children: cells.sublist(0, 3)),
        TableRow(children: cells.sublist(3, 6)),
        TableRow(children: cells.sublist(6)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<MyAppState>();
    final theme = Theme.of(context);
    final borderColor = theme.colorScheme.outline.withOpacity(0.8);
    final selColor = theme.colorScheme.primary.withOpacity(0.15);

    return Container(
      color: theme.colorScheme.surfaceVariant.withOpacity(0.2),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate:
            const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 9),
        itemCount: 81,
        itemBuilder: (context, i) {
          final r = i ~/ 9;
          final c = i % 9;
          final v = app.grid[r][c];
          final fixed = app.fixed[r][c];
          final selected = (app.selR == r && app.selC == c);

          return InkWell(
            onTap: () => app.selectCell(r, c),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: selected ? selColor : Colors.transparent,
                border: _cellBorder(r, c, borderColor),
              ),
              child: Center(
                child: v == 0
                    ? _notesGrid(app.notes[r][c], Theme.of(context).textTheme.bodyMedium!)
                    : Text(
                        '$v',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: fixed ? FontWeight.w700 : FontWeight.w400,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/* =========================
   키패드 + 제출/힌트 행
========================= */
class _KeypadRow extends StatelessWidget {
  const _KeypadRow({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<MyAppState>();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 현재 모드 배지
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                app.noteMode ? '메모 모드: 숫자 버튼이 메모를 토글합니다.' : '일반 모드: 숫자 버튼이 값을 입력합니다.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (int n = 1; n <= 9; n++)
                  SizedBox(
                    width: 56,
                    height: 44,
                    child: ElevatedButton(
                      onPressed: app.selR == null ? null : () => app.inputNumber(n),
                      child: Text('$n', style: const TextStyle(fontSize: 18)),
                    ),
                  ),
                SizedBox(
                  width: 56,
                  height: 44,
                  child: OutlinedButton(
                    onPressed: app.selR == null ? null : app.clearCell,
                    child: const Text('X', style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      if (app.selR == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('힌트를 쓰려면 먼저 빈 칸을 선택하세요.')),
                        );
                        return;
                      }
                      app.hintOne();
                    },
                    icon: const Icon(Icons.lightbulb_outline),
                    label: const Text('힌트'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if (app.isSolved()) {
                        await showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('정답입니다!'),
                            content: const Text('수고했어요 👏'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('확인'),
                              )
                            ],
                          ),
                        );
                        if (context.mounted) {
                          Navigator.of(context).pop(); // GamePage 닫기 → 랜딩
                        }
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('다시 생각해보세요')),
                        );
                      }
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('제출하기'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
