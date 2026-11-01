import 'package:intl/intl.dart';

/// 412 MB, 1.2 GB, 3.2 MB, 640 KB (docs/UI.md "SizeText").
String sizeText(int bytes) {
  final b = bytes < 0 ? 0 : bytes;
  String trim(double v) {
    final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (b >= 1000000000) return '${trim(b / 1e9)} GB';
  if (b >= 1000000) return '${trim(b / 1e6)} MB';
  if (b >= 1000) return '${trim(b / 1e3)} KB';
  return '$b B';
}

/// "2 minutes ago", "today 03:12", "yesterday 08:10", "8 Nov" (docs/UI.md "TimeText").
String timeText(int? epochMs, {DateTime? now}) {
  if (epochMs == null) return 'never';
  final n = now ?? DateTime.now();
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = n.difference(t);
  if (!diff.isNegative && diff.inSeconds < 60) return 'just now';
  if (!diff.isNegative && diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return '$m minute${m == 1 ? '' : 's'} ago';
  }
  final hm = DateFormat('HH:mm').format(t);
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days == 0) return 'today $hm';
  if (days == 1) return 'yesterday $hm';
  if (t.year == n.year) return DateFormat('d MMM').format(t);
  return DateFormat('d MMM yyyy').format(t);
}

/// Heading for a group of history rows: Today, Yesterday, or the date.
String dayHeader(int epochMs, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(t.year, t.month, t.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  return DateFormat(t.year == n.year ? 'EEEE d MMM' : 'd MMM yyyy').format(t);
}

String clockText(int epochMs) => DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(epochMs));

String dateText(int epochMs) => DateFormat('d MMM yyyy').format(DateTime.fromMillisecondsSinceEpoch(epochMs));

/// "Delay 2h", "Delay 45 min" (the buttons on Home and the notification).
String delayLabel(int minutes) {
  if (minutes % 60 == 0) return 'Delay ${minutes ~/ 60}h';
  return 'Delay $minutes min';
}

/// "2 hours", "45 minutes" (settings list).
String delayWords(int minutes) {
  if (minutes % 60 == 0) {
    final h = minutes ~/ 60;
    return '$h hour${h == 1 ? '' : 's'}';
  }
  return '$minutes minutes';
}

String plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';
