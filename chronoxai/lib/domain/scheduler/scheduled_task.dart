/// Una tarea local programada por hora de pared.
enum TaskRepeat { none, daily, weekly }

class ScheduledTask {
  const ScheduledTask({
    required this.id,
    required this.prompt,
    required this.scheduledAt,
    this.repeat = TaskRepeat.none,
    this.enabled = true,
  });

  final String id;
  final String prompt;
  final DateTime scheduledAt;
  final TaskRepeat repeat;
  final bool enabled;

  DateTime? get nextOccurrence {
    if (!enabled) return null;
    final now = DateTime.now();
    if (scheduledAt.isAfter(now)) return scheduledAt;
    return switch (repeat) {
      TaskRepeat.none => null,
      TaskRepeat.daily => _advance(scheduledAt, now, 1),
      TaskRepeat.weekly => _advance(scheduledAt, now, 7),
    };
  }

  DateTime _advance(final DateTime from, final DateTime now, final int days) {
    var candidate = from;
    while (!candidate.isAfter(now)) {
      candidate = candidate.add(Duration(days: days));
    }
    return candidate;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'prompt': prompt,
        'scheduledAt': scheduledAt.toIso8601String(),
        'repeat': repeat.name,
        'enabled': enabled,
      };

  factory ScheduledTask.fromJson(final Map<String, Object?> json) =>
      ScheduledTask(
        id: json['id'] as String,
        prompt: json['prompt'] as String,
        scheduledAt: DateTime.parse(json['scheduledAt'] as String),
        repeat: TaskRepeat.values.firstWhere(
          (final repeat) => repeat.name == json['repeat'],
          orElse: () => TaskRepeat.none,
        ),
        enabled: json['enabled'] as bool? ?? true,
      );
}
