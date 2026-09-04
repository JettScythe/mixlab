import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'pages/calculator_page.dart';
import 'pages/history_page.dart';
import 'pages/inventory_page.dart';
import 'pages/recipes_page.dart';
import 'pages/settings_page.dart';
import 'state.dart';
import 'theme.dart';

bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

// Window geometry lives outside the app schema: it is machine state, not
// user data, and should not travel in a backup.
const _kWinW = 'window_w';
const _kWinH = 'window_h';
const _kWinX = 'window_x';
const _kWinY = 'window_y';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (isDesktop) {
    await windowManager.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final w = prefs.getDouble(_kWinW) ?? 1180;
    final h = prefs.getDouble(_kWinH) ?? 820;
    final x = prefs.getDouble(_kWinX);
    final y = prefs.getDouble(_kWinY);

    final options = WindowOptions(
      size: Size(w, h),
      minimumSize: const Size(420, 560),
      title: 'MixLab',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (x != null && y != null) {
        await windowManager.setPosition(Offset(x, y));
      } else {
        await windowManager.center();
      }
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
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: 'MixLab',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: switch (state.settings.themeMode) {
          1 => ThemeMode.light,
          2 => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        home: HomeShell(state: state),
      ),
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

class _HomeShellState extends State<HomeShell> with WindowListener {
  int _index = 0;
  int _seenSaveError = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    if (isDesktop) windowManager.addListener(this);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    if (isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  // Persist geometry as the window settles, so a crash still leaves a
  // usable last-known size.
  @override
  void onWindowResized() => _saveWindow();

  @override
  void onWindowMoved() => _saveWindow();

  Future<void> _saveWindow() async {
    if (!isDesktop) return;
    try {
      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kWinW, size.width);
      await prefs.setDouble(_kWinH, size.height);
      await prefs.setDouble(_kWinX, pos.dx);
      await prefs.setDouble(_kWinY, pos.dy);
    } catch (e) {
      debugPrint('Could not save window geometry: $e');
    }
  }

  void _onState() {
    final s = widget.state;
    if (!mounted || s.saveErrorToken == _seenSaveError) return;
    _seenSaveError = s.saveErrorToken;
    final msg = s.lastSaveError;
    if (msg == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..removeCurrentSnackBar()
        ..showSnackBar(
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
        if (s.loadError != null) return _RecoveryScreen(state: s);

        final pages = [
          CalculatorPage(state: s),
          RecipesPage(state: s, onMix: () => _go(0)),
          InventoryPage(state: s),
          HistoryPage(state: s, onMix: () => _go(0)),
          SettingsPage(state: s),
        ];

        return LayoutBuilder(
          builder: (context, c) {
            final body = IndexedStack(index: _index, children: pages);
            if (Breaks.isCompact(c.maxWidth)) {
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
                    labelType: c.maxWidth >= Breaks.wide
                        ? NavigationRailLabelType.all
                        : NavigationRailLabelType.selected,
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

/// Shown when load() throws, so a corrupt blob cannot lock you out.
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
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: theme.colorScheme.error,
                ),
                Gap.vMd,
                Text(
                  'Could not load your data',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                Gap.vMd,
                Container(
                  padding: const EdgeInsets.all(Gap.md),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    state.loadError ?? 'Unknown error',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                Gap.vLg,
                const Text(
                  'Copy the raw data first — it may still be salvageable by '
                  'hand. Resetting is permanent.',
                ),
                Gap.vLg,
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
                Gap.vSm,
                OutlinedButton.icon(
                  onPressed: state.load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try loading again'),
                ),
                Gap.vSm,
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
