import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'pages/calculator_page.dart';
import 'pages/history_page.dart';
import 'pages/inventory_page.dart';
import 'pages/recipes_page.dart';
import 'pages/settings_page.dart';
import 'state.dart';

bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (isDesktop) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1100, 780),
      minimumSize: Size(560, 600),
      title: 'MixLab',
    );
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(MixLabApp(state: AppState()));
}

class MixLabApp extends StatelessWidget {
  const MixLabApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MixLab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: HomeShell(state: state),
    );
  }
}

class _Dest {
  const _Dest(this.label, this.icon, this.selected);
  final String label;
  final IconData icon;
  final IconData selected;
}

const _dests = [
  _Dest('Mix', Icons.science_outlined, Icons.science),
  _Dest('Recipes', Icons.menu_book_outlined, Icons.menu_book),
  _Dest('Inventory', Icons.inventory_2_outlined, Icons.inventory_2),
  _Dest('History', Icons.history_outlined, Icons.history),
  _Dest('Settings', Icons.settings_outlined, Icons.settings),
];

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});
  final AppState state;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  int _seenSaveError = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final s = widget.state;
    if (!mounted || s.saveErrorToken == _seenSaveError) return;
    _seenSaveError = s.saveErrorToken;
    final msg = s.lastSaveError;
    if (msg == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(seconds: 10),
          content: Text('Could not save changes: $msg'),
        ),
      );
    });
  }

  void _go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        if (!s.isReady) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (s.loadError != null) {
          return _RecoveryScreen(state: s);
        }
        final pages = [
          CalculatorPage(state: s),
          RecipesPage(state: s, onMix: () => _go(0)),
          InventoryPage(state: s),
          HistoryPage(state: s),
          SettingsPage(state: s),
        ];
        return LayoutBuilder(
          builder: (context, c) {
            final narrow = c.maxWidth < 700;
            final body = IndexedStack(index: _index, children: pages);
            if (narrow) {
              return Scaffold(
                body: SafeArea(child: body),
                bottomNavigationBar: NavigationBar(
                  selectedIndex: _index,
                  onDestinationSelected: _go,
                  destinations: [
                    for (final d in _dests)
                      NavigationDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selected),
                        label: d.label,
                      ),
                  ],
                ),
              );
            }
            return Scaffold(
              body: Row(
                children: [
                  NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: _go,
                    labelType: NavigationRailLabelType.all,
                    destinations: [
                      for (final d in _dests)
                        NavigationRailDestination(
                          icon: Icon(d.icon),
                          selectedIcon: Icon(d.selected),
                          label: Text(d.label),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// Shown when load() throws, so a corrupt blob can't lock you out forever.
class _RecoveryScreen extends StatelessWidget {
  const _RecoveryScreen({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 12),
                Text(
                  'Could not load your data',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    state.loadError ?? 'Unknown error',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Copy the raw data first — it may still be '
                  'salvageable by hand. Resetting is permanent.',
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    final dump = await state.rawDump();
                    await Clipboard.setData(ClipboardData(text: dump));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Raw data copied to clipboard.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy raw data to clipboard'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: state.load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try loading again'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Erase and start over?'),
                        content: const Text(
                          'All stored data is deleted permanently and '
                          'replaced with the defaults.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Erase'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) await state.hardReset();
                  },
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Erase all data and start fresh'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
