import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/scheduler/scheduled_task_store.dart';
import '../../domain/scheduler/scheduled_task.dart';
import '../../platform/scheduler_channel.dart';

class ScheduledTasksScreen extends StatefulWidget {
  const ScheduledTasksScreen({super.key});

  @override
  State<ScheduledTasksScreen> createState() => _ScheduledTasksScreenState();
}

class _ScheduledTasksScreenState extends State<ScheduledTasksScreen> {
  late Future<List<ScheduledTask>> _tasks = _read();
  final _bridge = const SchedulerChannel();

  Future<ScheduledTaskStore> _store() async {
    final support = await getApplicationSupportDirectory();
    return ScheduledTaskStore(File('${support.path}/scheduled_tasks.json'));
  }

  Future<List<ScheduledTask>> _read() async => (await _store()).readAll();

  Future<void> _refresh() async {
    setState(() => _tasks = _read());
  }

  Future<void> _create() async {
    final prompt = TextEditingController();
    var repeat = TaskRepeat.none;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Programar tarea'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: prompt,
                maxLines: 3,
                decoration: const InputDecoration(
                    labelText: 'Instrucción para Chronox')),
            const SizedBox(height: 12),
            DropdownButtonFormField<TaskRepeat>(
              initialValue: repeat,
              decoration: const InputDecoration(labelText: 'Repetición'),
              items: TaskRepeat.values
                  .map((value) => DropdownMenuItem(
                      value: value,
                      child: Text(switch (value) {
                        TaskRepeat.none => 'Una vez',
                        TaskRepeat.daily => 'Diaria',
                        TaskRepeat.weekly => 'Semanal'
                      })))
                  .toList(),
              onChanged: (value) =>
                  setDialogState(() => repeat = value ?? TaskRepeat.none),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Siguiente')),
          ],
        ),
      ),
    );
    final text = prompt.text.trim();
    prompt.dispose();
    if (accepted != true || text.isEmpty || !mounted) return;
    final now = DateTime.now();
    final day = await showDatePicker(
        context: context,
        firstDate: now,
        lastDate: now.add(const Duration(days: 365)),
        initialDate: now);
    if (day == null || !mounted) return;
    final time = await showTimePicker(
        context: context,
        initialTime:
            TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))));
    if (time == null || !mounted) return;
    final date = DateTime(day.year, day.month, day.day, time.hour, time.minute);
    if (!date.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Elige una hora futura.')));
      return;
    }
    final task = ScheduledTask(
        id: '${date.millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}',
        prompt: text,
        scheduledAt: date,
        repeat: repeat);
    final store = await _store();
    final tasks = await store.readAll();
    await store.writeAll([...tasks, task]);
    try {
      await _bridge.schedule(task);
    } on PlatformException {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Guardada; la alarma Android no está disponible ahora.')));
    } on MissingPluginException {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Guardada localmente; las alarmas requieren Android.')));
    }
    await _refresh();
  }

  Future<void> _delete(ScheduledTask task) async {
    final store = await _store();
    final tasks = await store.readAll();
    await store.writeAll(tasks.where((item) => item.id != task.id).toList());
    try {
      await _bridge.cancel(task.id);
    } on PlatformException {
      // The saved task is removed; the alarm bridge may be unavailable.
    } on MissingPluginException {
      // Desktop has no native alarms.
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tareas programadas')),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: _create,
            icon: const Icon(Icons.add),
            label: const Text('Programar')),
        body: FutureBuilder<List<ScheduledTask>>(
          future: _tasks,
          builder: (context, snapshot) {
            if (!snapshot.hasData)
              return const Center(child: CircularProgressIndicator());
            final tasks = snapshot.data!;
            if (tasks.isEmpty)
              return const Center(child: Text('No hay tareas programadas.'));
            return ListView.builder(
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  return ListTile(
                    leading: const Icon(Icons.schedule),
                    title: Text(task.prompt,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${task.scheduledAt.toLocal()} · ${task.repeat.name}'),
                    trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(task)),
                  );
                });
          },
        ),
      );
}
