import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/project.dart';
import '../mcp/mcp_server.dart';
import '../mcp/mcp_tools.dart';
import '../models/measurement.dart';
import '../services/measurement_service.dart';
import '../wizard/rta_controller.dart';
import 'mcp_screen.dart';
import 'rta_screen.dart';
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

  /// The analyser is not part of the tuning sequence — it is an instrument you
  /// pick up when something needs looking at — so it lives beside the tunes
  /// rather than inside one.
  Future<void> _openRta() async {
    final controller = RtaController(
      audio: widget.services.audio,
      core: widget.services.core,
    );
    // Reuse whatever mic calibration and SPL offset the last tune had, so the
    // analyser shows the car rather than the microphone, and reads in SPL if
    // that was calibrated.
    final tunes = await widget.services.store.list();
    if (tunes.isNotEmpty) {
      controller.splOffsetDb = tunes.first.splOffsetDb;
    }
    controller.calibration = widget.services.calibration;
    _rta = controller;
    if (!mounted) {
      controller.dispose();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RtaScreen(controller: controller)),
    );
    _rta = null;
    controller.dispose();
  }

  /// Held only while the analyser screen is open, so the MCP `get_rta` tool can
  /// report what it is showing.
  RtaController? _rta;

  McpServer? _mcp;

  Future<void> _openMcp() async {
    _mcp ??= McpServer(
      tools: buildTools(_AppMcpContext(widget.services, () => _rta)),
    );
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => McpScreen(server: _mcp!)),
    );
  }

  Future<void> _openWizard(TuneProject project) async {
    final controller = WizardController(
      service: MeasurementService(widget.services.core, widget.services.audio),
      store: widget.services.store,
      project: project,
    )..onCalibrationLoaded = (cal) => widget.services.calibration = cal;
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
      appBar: AppBar(
        title: const Text('Car Audio Tuner'),
        actions: [
          IconButton(
            tooltip: 'Real-time analyser',
            icon: const Icon(Icons.graphic_eq),
            onPressed: _openRta,
          ),
          IconButton(
            tooltip: 'Connect an assistant',
            icon: const Icon(Icons.hub_outlined),
            onPressed: _openMcp,
          ),
        ],
      ),
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

/// Bridges the MCP tools to the app's own services. Read-mostly by design:
/// the only thing here with a physical effect is [measure].
class _AppMcpContext implements McpContext {
  _AppMcpContext(this.services, this.rtaFor);

  final AppServices services;
  final RtaController? Function() rtaFor;

  @override
  Future<List<TuneProject>> listTunes() => services.store.list();

  @override
  Future<TuneProject?> getTune(String id) async {
    final all = await services.store.list();
    for (final t in all) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  Future<Measurement> measure({String? tuneId, int positions = 3}) async {
    final service = MeasurementService(services.core, services.audio);
    return service.measureAveraged(positions);
  }

  @override
  FreqResponse? rtaSpectrum() {
    final rta = rtaFor();
    if (rta == null || rta.spectrum.isEmpty) return null;
    return rta.spectrum;
  }

  @override
  double? rtaLevelDbfs() => rtaFor()?.levelDbfs;
}
