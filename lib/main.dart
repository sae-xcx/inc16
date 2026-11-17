import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:http/http.dart' as http;
import 'firebase_options.dart';

const apiUrl =
    'https://opentdb.com/api.php?amount=10&category=9&difficulty=easy&type=multiple';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MaterialApp(home: Root()));
}

class Root extends StatelessWidget {
  const Root({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (c, s) {
        if (s.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (s.data == null) return const SignIn();
        // New key per UID: a different user always gets a fresh state (stale guard).
        return QuizPage(key: ValueKey(s.data!.uid));
      },
    );
  }
}

// ---------------- Sign in (state: signedOut / authError) ----------------
class SignIn extends StatefulWidget {
  const SignIn({super.key});
  @override
  State<SignIn> createState() => _SignInState();
}

class _SignInState extends State<SignIn> {
  final email = TextEditingController();
  final pass = TextEditingController();
  String err = '';
  bool busy = false;

  Future<void> _go() async {
    setState(() {
      busy = true;
      err = '';
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.text.trim(),
        password: pass.text,
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => err = 'authError: ${e.code}');
    } catch (e) {
      if (mounted) setState(() => err = 'authError: unexpected failure');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(
              controller: email,
              decoration: const InputDecoration(labelText: 'Email')),
          TextField(
              controller: pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: busy ? null : _go,
              child: busy
                  ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Sign in')),
          if (err.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(children: [
                const Icon(Icons.error, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(err, style: const TextStyle(color: Colors.red))),
              ]),
            ),
        ]),
      ),
    );
  }
}

// ---------------- Model + fetch ----------------
class Q {
  final String question, correct;
  final List<String> choices;
  Q(this.question, this.correct, this.choices);
}

Future<List<Q>> fetchQuestions(String fault) async {
  final res =
  await http.get(Uri.parse(apiUrl)).timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) throw FormatException('HTTP ${res.statusCode}');
  var body = res.body;
  if (fault == 'badjson') body = '{not valid json';
  final j = jsonDecode(body);
  if (j is! Map) throw const FormatException('Unexpected JSON shape');
  var code = j['response_code'];
  if (fault == 'apicode') code = 1;
  if (code != 0) throw FormatException('API response_code $code');
  var results = j['results'];
  if (results is! List) throw const FormatException('No results list');
  if (fault == 'nine') results = results.sublist(0, 9);
  if (results.length != 10) {
    throw FormatException('Expected 10 results, got ${results.length}');
  }
  final u = HtmlUnescape();
  final out = <Q>[];
  for (final r in results) {
    if (r is! Map) throw const FormatException('Bad result item');
    if (r['category'] != 'General Knowledge' ||
        r['difficulty'] != 'easy' ||
        r['type'] != 'multiple') {
      throw const FormatException('Wrong category, difficulty, or type');
    }
    final q = u.convert('${r['question'] ?? ''}').trim();
    final c = u.convert('${r['correct_answer'] ?? ''}').trim();
    final inc = r['incorrect_answers'];
    if (q.isEmpty || c.isEmpty || inc is! List || inc.length != 3) {
      throw const FormatException('Incomplete question');
    }
    final choices = <String>[c, ...inc.map((e) => u.convert('$e').trim())];
    if (choices.any((e) => e.isEmpty) || choices.toSet().length != 4) {
      throw const FormatException('Empty or duplicate choices');
    }
    choices.shuffle(); // shuffled once here, never in build()
    out.add(Q(q, c, choices));
  }
  return out;
}

// ---------------- State machine ----------------
enum S {
  signedOut,
  loading,
  playing,
  readyToSubmit,
  submitting,
  verifying,
  cloudVerified,
  authError,
  requestError,
  saveUnknown,
  permissionDenied,
  verificationUnavailable,
}

class Collision implements Exception {}

class QuizPage extends StatefulWidget {
  const QuizPage({super.key});
  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  final String uid = FirebaseAuth.instance.currentUser!.uid;
  List<Q> qs = [];
  List<int?> sel = List.filled(10, null);
  int idx = 0, score = 0;
  bool answered = false, finished = false;
  S st = S.loading;
  String msg = '';
  String roundId = '';
  DateTime? lastFetch;
  Map<String, dynamic>? payload; // frozen once per completed round
  Map<String, dynamic>? verifiedData;
  String? verifiedPath;
  // DEV-ONLY fault injection (one-shot, labeled in UI)
  String apiFault = 'none'; // none, badjson, apicode, nine
  String saveFault = 'none'; // none, lostAck, unavailable, exhausted
  final idCtl = TextEditingController();
  String retrieved = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  CollectionReference<Map<String, dynamic>> get _col => FirebaseFirestore
      .instance
      .collection('users')
      .doc(uid)
      .collection('attempts');

  bool get _pending =>
      st == S.submitting ||
          st == S.verifying ||
          st == S.saveUnknown ||
          st == S.verificationUnavailable;

  bool _live(String rid) =>
      mounted &&
          roundId == rid &&
          FirebaseAuth.instance.currentUser?.uid == uid;

  Future<void> _load() async {
    if (lastFetch != null &&
        DateTime.now().difference(lastFetch!) < const Duration(seconds: 5)) {
      setState(() {
        qs = [];
        st = S.requestError;
        msg = 'Wait 5 seconds between question requests, then tap Retry.';
      });
      return;
    }
    lastFetch = DateTime.now();
    final f = apiFault;
    apiFault = 'none';
    setState(() {
      qs = [];
      finished = false;
      st = S.loading;
      msg = '';
    });
    try {
      final list = await fetchQuestions(f);
      if (!mounted) return;
      setState(() {
        qs = list;
        idx = 0;
        sel = List.filled(10, null);
        score = 0;
        answered = false;
        finished = false;
        payload = null;
        verifiedData = null;
        verifiedPath = null;
        roundId = _col.doc().id; // reserves nothing on the server
        st = S.playing;
        msg = f == 'none' ? '' : 'INJECTED fault ($f) was used on the last request.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        st = S.requestError;
        msg = 'Could not load a valid round (${f == 'none' ? '' : 'INJECTED $f: '}$e). Tap Retry.';
      });
    }
  }

  void _pick(int i) {
    if (answered) return;
    setState(() {
      sel[idx] = i;
      answered = true;
      if (qs[idx].choices[i] == qs[idx].correct) score++;
    });
  }

  void _next() {
    if (!answered) return;
    setState(() {
      if (idx < 9) {
        idx++;
        answered = false;
      } else {
        finished = true;
        st = S.readyToSubmit;
        payload = {
          'schemaVersion': 1,
          'variant': 'A',
          'categoryId': 9,
          'questionCount': 10,
          'correctCount': score,
          'submittedAt': FieldValue.serverTimestamp(),
        };
      }
    });
  }

  Future<void> _submit() async {
    if (st == S.submitting || st == S.verifying || payload == null) return;
    final u = FirebaseAuth.instance.currentUser;
    if (u == null || u.uid != uid) {
      setState(() {
        st = S.authError;
        msg = 'Not signed in as the owner of this round.';
      });
      return;
    }
    final rid = roundId;
    final ref = _col.doc(rid);
    final f = saveFault;
    saveFault = 'none';
    final data = payload!;
    final expected = score;
    setState(() {
      st = S.submitting;
      msg = '';
    });
    try {
      if (f == 'unavailable') {
        throw FirebaseException(
            plugin: 'cloud_firestore', code: 'unavailable', message: 'INJECTED');
      }
      if (f == 'exhausted') {
        throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'resource-exhausted',
            message: 'INJECTED');
      }
      await FirebaseFirestore.instance.runTransaction<void>((tx) async {
        final snap = await tx.get(ref);
        if (snap.exists) {
          final d = snap.data()!;
          final same = d['schemaVersion'] == 1 &&
              d['variant'] == 'A' &&
              d['categoryId'] == 9 &&
              d['questionCount'] == 10 &&
              d['correctCount'] == expected;
          if (same) return; // reuse the existing matching attempt
          throw Collision();
        }
        tx.set(ref, data);
      }).timeout(const Duration(seconds: 10));
      if (f == 'lostAck') {
        // INJECTED: the commit really happened, the UI just never hears about it.
        throw TimeoutException('INJECTED: acknowledgement hidden');
      }
    } on TimeoutException {
      if (!_live(rid)) return;
      setState(() {
        st = S.saveUnknown;
        msg =
        'Save unknown (a timeout does not prove failure). Tap "Check cloud" to read the server.';
      });
      return;
    } on Collision {
      if (!_live(rid)) return;
      setState(() {
        st = S.requestError;
        msg = 'Collision: this round ID already holds a different attempt. Original preserved.';
      });
      return;
    } on FirebaseException catch (e) {
      if (!_live(rid)) return;
      _fail(e, 'save');
      return;
    } catch (e) {
      if (!_live(rid)) return;
      setState(() {
        st = S.saveUnknown;
        msg = 'Save outcome unknown. Tap "Check cloud".';
      });
      return;
    }
    if (!_live(rid)) return;
    await _verify(ref, rid);
  }

  void _fail(FirebaseException e, String what) {
    setState(() {
      switch (e.code) {
        case 'permission-denied':
          st = S.permissionDenied;
          msg = 'permission-denied: rules rejected this $what.';
          break;
        case 'unauthenticated':
          st = S.authError;
          msg = 'unauthenticated: sign in again.';
          break;
        case 'unavailable':
          st = what == 'verify' ? S.verificationUnavailable : S.requestError;
          msg =
          'unavailable: cloud unreachable (offline?). Nothing confirmed. Tap "Check cloud" first, then Retry with the same round ID.';
          break;
        case 'resource-exhausted':
          st = S.requestError;
          msg = 'resource-exhausted: quota used up. Do not retry in a loop; try later.';
          break;
        default:
          st = S.requestError;
          msg = 'Cloud error: ${e.code}';
      }
    });
  }

  Future<void> _verify(DocumentReference<Map<String, dynamic>> ref, String rid) async {
    setState(() {
      st = S.verifying;
      msg = '';
    });
    try {
      final s = await ref
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      if (!_live(rid)) return;
      final d = s.data();
      if (!s.exists || d == null) {
        setState(() {
          st = S.saveUnknown;
          msg = 'Server has no document for this round ID, so it is not saved. Retry with the same ID.';
        });
        return;
      }
      final ok = d.length == 6 &&
          d['schemaVersion'] == 1 &&
          d['variant'] == 'A' &&
          d['categoryId'] == 9 &&
          d['questionCount'] == 10 &&
          d['correctCount'] == score &&
          d['submittedAt'] is Timestamp &&
          !s.metadata.hasPendingWrites;
      if (!ok) {
        setState(() {
          st = S.verificationUnavailable;
          msg = 'Document found but fields did not match the expected payload.';
        });
        return;
      }
      setState(() {
        st = S.cloudVerified;
        verifiedData = d;
        verifiedPath = ref.path;
        msg = '';
      });
    } on FirebaseException catch (e) {
      if (!_live(rid)) return;
      if (e.code == 'permission-denied') {
        _fail(e, 'verify');
      } else {
        setState(() {
          st = S.verificationUnavailable;
          msg = 'Verification unavailable (${e.code}). The save may still have succeeded. Tap "Check cloud".';
        });
      }
    } on TimeoutException {
      if (!_live(rid)) return;
      setState(() {
        st = S.verificationUnavailable;
        msg = 'Verification timed out. Tap "Check cloud".';
      });
    }
  }

  Future<void> _retrieve() async {
    setState(() => retrieved = 'Reading server...');
    try {
      final id = idCtl.text.trim();
      String text;
      if (id.isNotEmpty) {
        final s = await _col
            .doc(id)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        text = s.exists ? '${s.reference.path}\n${s.data()}' : 'No such attempt on server.';
      } else {
        final q = await _col
            .orderBy('submittedAt', descending: true)
            .limit(1)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        text = q.docs.isEmpty
            ? 'No attempts on server.'
            : '${q.docs.first.reference.path}\n${q.docs.first.data()}';
      }
      if (mounted) setState(() => retrieved = text);
    } catch (e) {
      if (mounted) setState(() => retrieved = 'Server read failed: $e');
    }
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GK Cloud Quiz'),
        actions: [
          IconButton(
            tooltip: _pending ? 'Locked while a save is unresolved' : 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: _pending ? null : () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('State: ${st.name}', style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        if (msg.isNotEmpty) _banner(msg),
        if (st == S.loading) const Center(child: CircularProgressIndicator()),
        if (!finished && qs.isEmpty && st == S.requestError)
          FilledButton(onPressed: _load, child: const Text('Retry')),
        if (!finished && qs.isNotEmpty) ..._question(),
        if (finished) ..._result(),
        const Divider(height: 32),
        _retrieveTile(),
        _devTile(),
      ]),
    );
  }

  Widget _banner(String t) {
    final bad = st != S.playing && st != S.cloudVerified;
    return Container(
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.only(bottom: 8),
      color: bad ? Colors.red.shade50 : Colors.green.shade50,
      child: Row(children: [
        Icon(bad ? Icons.warning_amber : Icons.check_circle,
            color: bad ? Colors.red : Colors.green),
        const SizedBox(width: 8),
        Expanded(child: Text(t)),
      ]),
    );
  }

  List<Widget> _question() {
    final q = qs[idx];
    return [
      LinearProgressIndicator(value: (idx + 1) / 10),
      const SizedBox(height: 8),
      Text('Question ${idx + 1} of 10   Score: $score',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(q.question, style: const TextStyle(fontSize: 18)),
      const SizedBox(height: 8),
      for (var i = 0; i < 4; i++) _choice(q, i),
      if (answered)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: FilledButton(
              onPressed: _next,
              child: Text(idx < 9 ? 'Next' : 'Finish')),
        ),
    ];
  }

  Widget _choice(Q q, int i) {
    final c = q.choices[i];
    final isCorrect = c == q.correct;
    final isSel = sel[idx] == i;
    Color? bg;
    Widget? icon;
    if (answered && isCorrect) {
      bg = Colors.green.shade100;
      icon = const Icon(Icons.check_circle, color: Colors.green);
    } else if (answered && isSel) {
      bg = Colors.red.shade100;
      icon = const Icon(Icons.cancel, color: Colors.red);
    }
    return Card(
      color: bg,
      child: ListTile(
        title: Text(c),
        trailing: icon,
        subtitle: answered && isCorrect
            ? const Text('Correct answer')
            : (answered && isSel ? const Text('Your answer (wrong)') : null),
        onTap: answered ? null : () => _pick(i),
      ),
    );
  }

  List<Widget> _result() {
    final canSubmit = st == S.readyToSubmit || st == S.requestError;
    final canCheck = st == S.saveUnknown ||
        st == S.verificationUnavailable ||
        st == S.requestError ||
        st == S.permissionDenied;
    return [
      Text('Final score: $score / 10',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      for (var i = 0; i < qs.length; i++)
        ListTile(
          dense: true,
          leading: Icon(
              qs[i].choices[sel[i]!] == qs[i].correct
                  ? Icons.check_circle
                  : Icons.cancel,
              color: qs[i].choices[sel[i]!] == qs[i].correct
                  ? Colors.green
                  : Colors.red),
          title: Text('${i + 1}. ${qs[i].question}'),
          subtitle: Text(
              'You: ${qs[i].choices[sel[i]!]}  |  Correct: ${qs[i].correct}'),
        ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        FilledButton(
            onPressed: canSubmit ? _submit : null,
            child: Text(st == S.requestError ? 'Retry save (same ID)' : 'Submit')),
        OutlinedButton(
            onPressed: canCheck ? () => _verify(_col.doc(roundId), roundId) : null,
            child: const Text('Check cloud')),
        OutlinedButton(
            onPressed: _pending ? null : _load,
            child: const Text('Replay')),
      ]),
      if (st == S.submitting || st == S.verifying)
        const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator())),
      if (st == S.cloudVerified && verifiedData != null)
        Card(
          color: Colors.green.shade50,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
                'Cloud verified\n$verifiedPath\n$verifiedData'),
          ),
        ),
    ];
  }

  Widget _retrieveTile() => ExpansionTile(
    title: const Text('Retrieve saved attempt (server read)'),
    children: [
      TextField(
          controller: idCtl,
          decoration: const InputDecoration(
              labelText: 'Round ID (blank = latest)')),
      TextButton(onPressed: _retrieve, child: const Text('Retrieve')),
      SelectableText(retrieved),
    ],
  );

  Widget _devTile() => ExpansionTile(
    title: const Text('DEV ONLY: fault injection (labeled)'),
    children: [
      Row(children: [
        const Text('Next API request: '),
        DropdownButton<String>(
          value: apiFault,
          items: const ['none', 'badjson', 'apicode', 'nine']
              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
              .toList(),
          onChanged: (v) => setState(() => apiFault = v!),
        ),
      ]),
      Row(children: [
        const Text('Next save: '),
        DropdownButton<String>(
          value: saveFault,
          items: const ['none', 'lostAck', 'unavailable', 'exhausted']
              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
              .toList(),
          onChanged: (v) => setState(() => saveFault = v!),
        ),
      ]),
    ],
  );
}