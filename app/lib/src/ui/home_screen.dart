import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/project.dart';
import '../services/measurement_service.dart';
import '../wizard/wizard_controller.dart';
import 'wizard_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<TuneProject>> _projects;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _projects = widget.services.store.list();
  }

  Future<void> _openWizard(TuneProject project) async {
    final controller = WizardController(
      service: MeasurementService(widget.services.core, widget.services.audio),
      store: widget.services.store,
      project: project,
    );
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WizardScreen(controller: controller)),
    );
    setState(_reload);
  }

  Future<void> _newTune() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final ctrl = TextEditingController(text: 'My car');
        return AlertDialog(
          title: const Text('New tune'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, ctrl.text),
                child: const Text('Create')),
          ],
        );
      },
    );
    if (name == null || name.trim().isEmpty) return;
    final project = TuneProject(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name.trim(),
      createdAt: DateTime.now(),
    );
    await widget.services.store.save(project);
    if (mounted) await _openWizard(project);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Car Audio Tuner')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newTune,
        icon: const Icon(Icons.add),
        label: const Text('New tune'),
      ),
      body: FutureBuilder<List<TuneProject>>(
        future: _projects,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final projects = snap.data!;
          if (projects.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No tunes yet.\nTap "New tune" to measure and tune your car.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: projects.length,
            itemBuilder: (context, i) {
              final p = projects[i];
              return ListTile(
                leading: const Icon(Icons.directions_car),
                title: Text(p.name),
                subtitle: Text(
                    '${p.createdAt.toLocal().toString().split('.').first} · '
                    '${p.eqBands['system']?.length ?? 0} EQ bands'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openWizard(p),
              );
            },
          );
        },
      ),
    );
  }
}
